#!/usr/bin/env python3
# Decode throughput, TTFT, prefill speed and MTP acceptance for a Hyperflare endpoint.
#
# Why not probe-inference-throughput.sh: that probe targets vLLM/SGLang. Under MTP one
# streamed chunk carries every accepted draft token at once, so counting chunks as
# tokens understates throughput; this reads the exact completion_tokens from the final
# usage chunk. Acceptance comes from the bridge's hyperflare:spec_* counters with the
# definition the monitoring rules use (inference:spec_accept_length = 1 + accepted /
# rounds), so the number is comparable with the Grafana panel and the runbook's 1.78.
#
# Design: SSE parsing, per-request and per-round statistics, counter deltas and the
# acceptance rule are pure and unit-tested on plain values
# (tests/hyperflare-throughput-probe-unit.py); HTTP, threads and the filesystem are the
# imperative shell. Every round waits for an idle server and is checked against the
# bridge's request counter, so another client (a Pi session, Cortex's ingest) cannot
# silently contaminate a measurement.
"""Throughput and MTP-acceptance probe for a Hyperflare endpoint."""

from __future__ import annotations

import argparse
import json
import math
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
import uuid
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

# ------------------------------------------------------------------ pure: SSE


@dataclass(frozen=True)
class Delta:
    """Content or reasoning text arrived."""


@dataclass(frozen=True)
class Usage:
    prompt_tokens: int
    completion_tokens: int


@dataclass(frozen=True)
class Finish:
    reason: str


@dataclass(frozen=True)
class Done:
    """The stream's terminator."""


@dataclass(frozen=True)
class Ignored:
    """A line that carries nothing this probe measures."""


SseEvent = Delta | Usage | Finish | Done | Ignored


def parse_sse_line(line: str) -> SseEvent:
    """One server-sent-events line as an event. Pure and total: junk is Ignored."""
    if not line.startswith("data:"):
        return Ignored()
    body = line[len("data:"):].strip()
    if body == "[DONE]":
        return Done()
    try:
        event = json.loads(body)
    except ValueError:
        return Ignored()
    if not isinstance(event, dict):
        return Ignored()
    usage = event.get("usage")
    if isinstance(usage, dict) and isinstance(usage.get("completion_tokens"), int):
        prompt = usage.get("prompt_tokens")
        return Usage(prompt if isinstance(prompt, int) else 0, usage["completion_tokens"])
    choices = event.get("choices")
    if not isinstance(choices, list):
        return Ignored()
    for choice in choices:
        if not isinstance(choice, dict):
            continue
        delta = choice.get("delta")
        if isinstance(delta, dict):
            for name in ("content", "reasoning_content", "reasoning"):
                text = delta.get(name)
                if isinstance(text, str) and text:
                    return Delta()
        reason = choice.get("finish_reason")
        if isinstance(reason, str) and reason:
            return Finish(reason)
    return Ignored()


# ------------------------------------------------------- pure: one request


@dataclass(frozen=True)
class Observation:
    """What one streamed request saw: when it was sent, when each token-bearing chunk
    arrived, and the server's own exact counts."""

    sent_at: float
    chunk_times: tuple[float, ...]
    prompt_tokens: int
    completion_tokens: int
    finish: str


def ttft_s(observation: Observation) -> float | None:
    """Seconds from sending to the first token-bearing chunk."""
    return observation.chunk_times[0] - observation.sent_at if observation.chunk_times else None


def decode_tps(observation: Observation) -> float | None:
    """Tokens after the first, per second between the first and last chunk.

    Same convention as vLLM's TPOT: the first token belongs to TTFT. Exact token count
    from usage, so speculative bundling does not understate it.
    """
    if observation.completion_tokens < 2 or len(observation.chunk_times) < 2:
        return None
    span = observation.chunk_times[-1] - observation.chunk_times[0]
    return (observation.completion_tokens - 1) / span if span > 0 else None


def chunk_gaps_ms(observation: Observation) -> list[float]:
    times = observation.chunk_times
    return [(later - earlier) * 1000.0 for earlier, later in zip(times, times[1:])]


def tokens_per_chunk(observation: Observation) -> float | None:
    """Above 1 when speculation delivers several tokens in one chunk."""
    return observation.completion_tokens / len(observation.chunk_times) if observation.chunk_times else None


def percentile(values: Sequence[float], fraction: float) -> float | None:
    """Nearest-rank percentile; None for no values."""
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(1, math.ceil(fraction * len(ordered))) - 1]


# -------------------------------------------------------- pure: one round


@dataclass(frozen=True)
class RoundStats:
    requests: int
    completion_tokens: int
    prompt_tokens: int
    wall_s: float
    aggregate_tps: float
    per_request_decode_tps: tuple[float, ...]
    ttft_s: tuple[float, ...]
    chunk_gap_ms_p50: float | None
    chunk_gap_ms_p95: float | None
    tokens_per_chunk: float | None
    finishes: dict[str, int]


def summarise_round(observations: Sequence[Observation], wall_s: float) -> RoundStats:
    """Statistics for the requests of one round. Aggregate tok/s is every completion
    token over the round's wall time, ramp and prefill included."""
    if not observations:
        raise ValueError("a round needs at least one observation")
    gaps = [gap for observation in observations for gap in chunk_gaps_ms(observation)]
    per_chunk = [value for observation in observations if (value := tokens_per_chunk(observation)) is not None]
    total = sum(observation.completion_tokens for observation in observations)
    return RoundStats(
        requests=len(observations),
        completion_tokens=total,
        prompt_tokens=sum(observation.prompt_tokens for observation in observations),
        wall_s=wall_s,
        aggregate_tps=total / wall_s if wall_s > 0 else 0.0,
        per_request_decode_tps=tuple(rate for observation in observations if (rate := decode_tps(observation)) is not None),
        ttft_s=tuple(value for observation in observations if (value := ttft_s(observation)) is not None),
        chunk_gap_ms_p50=percentile(gaps, 0.5),
        chunk_gap_ms_p95=percentile(gaps, 0.95),
        tokens_per_chunk=statistics.fmean(per_chunk) if per_chunk else None,
        finishes=dict(Counter(observation.finish for observation in observations)),
    )


# ---------------------------------------------------- pure: bridge counters


@dataclass(frozen=True)
class SpecCounters:
    accepted: float
    draft_tokens: float
    rounds: float
    requests: float


_SERIES = {
    "hyperflare:spec_accepted_tokens_total": "accepted",
    "hyperflare:spec_draft_tokens_total": "draft_tokens",
    "hyperflare:spec_draft_rounds_total": "rounds",
    "hyperflare:requests_total": "requests",
}
_SAMPLE = re.compile(r"^(?P<name>[A-Za-z_:][A-Za-z0-9_:]*)(?:\{[^}]*\})?\s+(?P<value>\S+)\s*$")


def _sum_series(text: str) -> dict[str, float]:
    totals: dict[str, float] = {}
    for line in text.splitlines():
        match = _SAMPLE.match(line)
        if line.startswith("#") or not match:
            continue
        try:
            totals[match["name"]] = totals.get(match["name"], 0.0) + float(match["value"])
        except ValueError:
            continue
    return totals


def parse_counters(text: str) -> SpecCounters | None:
    """The MTP and request counters, summed over model labels; None when the bridge
    does not expose them (not a Hyperflare bridge)."""
    totals = _sum_series(text)
    if not all(name in totals for name in _SERIES):
        return None
    return SpecCounters(**{field: totals[name] for name, field in _SERIES.items()})


def in_flight(text: str) -> int | None:
    """Running plus waiting requests; None when the bridge does not say."""
    totals = _sum_series(text)
    if "hyperflare:requests_running" not in totals:
        return None
    return int(totals["hyperflare:requests_running"] + totals.get("hyperflare:requests_waiting", 0.0))


def counter_delta(before: SpecCounters, after: SpecCounters) -> SpecCounters | None:
    """What happened between two scrapes; None when a counter went backwards (a restart)."""
    delta = SpecCounters(after.accepted - before.accepted, after.draft_tokens - before.draft_tokens,
                         after.rounds - before.rounds, after.requests - before.requests)
    return None if min(delta.accepted, delta.draft_tokens, delta.rounds, delta.requests) < 0 else delta


@dataclass(frozen=True)
class Acceptance:
    length: float
    rate: float | None


def acceptance(delta: SpecCounters) -> Acceptance | None:
    """MTP acceptance the way the monitoring rules define it: length = 1 + accepted /
    rounds (the bonus token counts), rate = accepted / draft positions verified."""
    if delta.rounds <= 0:
        return None
    return Acceptance(1 + delta.accepted / delta.rounds,
                      delta.accepted / delta.draft_tokens if delta.draft_tokens > 0 else None)


def clean(delta: SpecCounters | None, expected_requests: int, in_flight_after: int | None = 0) -> bool:
    """A round is clean when the bridge counted exactly the requests this probe sent and
    nothing is still running once they finished; anything else means another client used
    the server meanwhile."""
    return delta is not None and delta.requests == expected_requests and in_flight_after == 0


# ---------------------------------------------------------- pure: the run


@dataclass(frozen=True)
class RoundRecord:
    name: str
    repetition: int
    stats: RoundStats
    delta: SpecCounters | None
    clean: bool


@dataclass(frozen=True)
class SummaryRow:
    name: str
    repetitions: int
    contaminated: int
    decode_tps_per_request: float | None
    aggregate_tps: float | None
    ttft_p50_s: float | None
    chunk_gap_ms_p50: float | None
    chunk_gap_ms_p95: float | None
    tokens_per_chunk: float | None
    prefill_tps: float | None
    acceptance: Acceptance | None


def _median(values: Sequence[float]) -> float | None:
    return statistics.median(values) if values else None


def summarise_run(records: Sequence[RoundRecord]) -> list[SummaryRow]:
    """One row per round name, over the clean repetitions only; acceptance pools their counters."""
    rows = []
    for name in dict.fromkeys(record.name for record in records):
        mine = [record for record in records if record.name == name]
        good = [record for record in mine if record.clean]
        pooled = [record.delta for record in good if record.delta is not None]
        pooled_delta = (SpecCounters(sum(d.accepted for d in pooled), sum(d.draft_tokens for d in pooled),
                                     sum(d.rounds for d in pooled), sum(d.requests for d in pooled))
                        if pooled else None)
        prefill = [record.stats.prompt_tokens / record.stats.ttft_s[0]
                   for record in good if name == "prefill" and record.stats.ttft_s and record.stats.ttft_s[0] > 0]
        rows.append(SummaryRow(
            name=name,
            repetitions=len(good),
            contaminated=len(mine) - len(good),
            decode_tps_per_request=_median([statistics.fmean(r.stats.per_request_decode_tps)
                                            for r in good if r.stats.per_request_decode_tps]),
            aggregate_tps=_median([r.stats.aggregate_tps for r in good]),
            ttft_p50_s=percentile([t for r in good for t in r.stats.ttft_s], 0.5),
            chunk_gap_ms_p50=_median([r.stats.chunk_gap_ms_p50 for r in good if r.stats.chunk_gap_ms_p50 is not None]),
            chunk_gap_ms_p95=_median([r.stats.chunk_gap_ms_p95 for r in good if r.stats.chunk_gap_ms_p95 is not None]),
            tokens_per_chunk=_median([r.stats.tokens_per_chunk for r in good if r.stats.tokens_per_chunk is not None]),
            prefill_tps=_median(prefill),
            acceptance=acceptance(pooled_delta) if pooled_delta is not None else None,
        ))
    return rows


# --------------------------------------------------------- pure: the requests

TOPICS = ("B-tree indexes", "TCP congestion control", "log-structured merge trees",
          "the Raft consensus algorithm", "multi-version concurrency control",
          "tracing garbage collectors", "regular expression engines", "elliptic-curve cryptography")
ROUND_CONCURRENCY = {"c1": 1, "c4": 4, "c8": 8, "prefill": 1}


def decode_prompt(index: int, nonce: str) -> str:
    """A long-form generation prompt, unique per request: a different topic and a nonce
    first, so no two requests share a prefix and the prefix cache cannot flatter TTFT."""
    topic = TOPICS[index % len(TOPICS)]
    return (f"[session {nonce}-{index}] Write an exhaustive, deeply technical guide to {topic}. "
            "Cover the history, the core algorithms, common pitfalls and worked examples. "
            "Aim for at least 4,000 words and do not stop early.")


def prefill_prompt(nonce: str, sentences: int) -> str:
    """Unique prose of roughly 30 tokens a sentence, then a trivial question."""
    body = "".join(f"Sentence {i}: the amber kettle whispered of {i % 97} cups of quiet, while the "
                   f"{i % 53}th window held the afternoon light against the paper map. "
                   for i in range(1, sentences + 1))
    return f"[session {nonce}] {body}Now answer in one word: what colour was the kettle?"


def request_payload(model: str, prompt: str, max_tokens: int, temperature: float, top_p: float,
                    reasoning_effort: str | None) -> dict:
    payload: dict = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": temperature,
        "top_p": top_p,
        "stream": True,
        "stream_options": {"include_usage": True},
    }
    if reasoning_effort:
        payload["reasoning_effort"] = reasoning_effort
    return payload


# ------------------------------------------------------- pure: presentation


def _fmt(value: float | None, spec: str = ".1f") -> str:
    return "n/a" if value is None else format(value, spec)


def format_table(rows: Sequence[SummaryRow]) -> str:
    header = (f"{'round':<9}{'reps':>5}{'tok/s/req':>11}{'agg tok/s':>11}{'ttft p50':>10}"
              f"{'gap p50/p95 ms':>16}{'tok/chunk':>11}{'MTP len':>9}{'accept':>8}")
    lines = [header, "-" * len(header)]
    for row in rows:
        gap = f"{_fmt(row.chunk_gap_ms_p50, '.0f')}/{_fmt(row.chunk_gap_ms_p95, '.0f')}"
        accepted = row.acceptance
        lines.append(f"{row.name:<9}{row.repetitions:>5}{_fmt(row.decode_tps_per_request):>11}"
                     f"{_fmt(row.aggregate_tps):>11}{_fmt(row.ttft_p50_s, '.2f') + ' s':>10}{gap:>16}"
                     f"{_fmt(row.tokens_per_chunk, '.2f'):>11}"
                     f"{_fmt(accepted.length if accepted else None, '.2f'):>9}"
                     f"{_fmt(accepted.rate if accepted else None, '.2f'):>8}")
    for row in rows:
        if row.prefill_tps is not None:
            lines.append(f"\nprefill: {row.prefill_tps:,.0f} tok/s (prompt tokens over time to first token)")
        if row.contaminated:
            lines.append(f"warning: {row.name}: {row.contaminated} repetition(s) contaminated by other "
                         "clients and excluded")
    return "\n".join(lines)


# ------------------------------------------------------------ imperative shell


class ProbeError(Exception):
    """A failure to measure, reported once at the top."""


def stream_request(url: str, key: str | None, payload: dict, timeout: float) -> Observation:
    """One streamed completion, timed per token-bearing chunk."""
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    request = urllib.request.Request(f"{url}/v1/chat/completions", json.dumps(payload).encode(), headers)
    sent_at = time.monotonic()
    chunk_times: list[float] = []
    prompt_tokens = completion_tokens = 0
    finish = ""
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw in response:
                arrived = time.monotonic()
                event = parse_sse_line(raw.decode(errors="replace").strip())
                if isinstance(event, Delta):
                    chunk_times.append(arrived)
                elif isinstance(event, Usage):
                    prompt_tokens, completion_tokens = event.prompt_tokens, event.completion_tokens
                elif isinstance(event, Finish):
                    finish = event.reason
    except urllib.error.HTTPError as error:
        raise ProbeError(f"HTTP {error.code} from {url}: {error.read().decode(errors='replace')[:200]}") from error
    if completion_tokens == 0:
        raise ProbeError("the stream ended without a usage chunk; does the endpoint honour stream_options.include_usage?")
    return Observation(sent_at, tuple(chunk_times), prompt_tokens, completion_tokens, finish)


def fetch_text(url: str, key: str | None = None, timeout: float = 10.0) -> str:
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=timeout) as response:
        return response.read().decode(errors="replace")


def scrape(bridge: str) -> tuple[SpecCounters, int | None]:
    try:
        text = fetch_text(f"{bridge}/metrics")
    except (urllib.error.URLError, OSError) as error:
        raise ProbeError(f"cannot read the metrics bridge at {bridge}: {error}") from error
    counters = parse_counters(text)
    if counters is None:
        raise ProbeError(f"the bridge at {bridge} does not expose the hyperflare:spec_* counters "
                         "(is this the Hyperflare bridge on :8011?)")
    return counters, in_flight(text)


def wait_idle(bridge: str, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    while True:
        _, busy = scrape(bridge)
        if busy == 0:
            return
        if time.monotonic() >= deadline:
            raise ProbeError(f"the server is not idle ({busy} request(s) in flight after {timeout_s:g} s); "
                             "refusing to measure alongside other clients")
        time.sleep(0.5)


def run_round(options: argparse.Namespace, key: str | None, model: str, name: str,
              repetition: int) -> RoundRecord:
    wait_idle(options.bridge, options.idle_timeout)
    before, _ = scrape(options.bridge)
    nonce = uuid.uuid4().hex[:8]
    concurrency = ROUND_CONCURRENCY[name]
    if name == "prefill":
        prompts = [prefill_prompt(nonce, options.prefill_sentences)]
        max_tokens = options.prefill_max_tokens
    else:
        prompts = [decode_prompt(index, nonce) for index in range(concurrency)]
        max_tokens = options.max_tokens
    payloads = [request_payload(model, prompt, max_tokens, options.temperature, options.top_p,
                                options.reasoning_effort) for prompt in prompts]
    started = time.monotonic()
    with ThreadPoolExecutor(max_workers=concurrency) as pool:
        futures = [pool.submit(stream_request, options.url, key, payload, options.timeout) for payload in payloads]
        observations = [future.result() for future in futures]
    wall = time.monotonic() - started
    time.sleep(options.settle)  # let the server retire this round's requests before reading it
    after, busy_after = scrape(options.bridge)
    delta = counter_delta(before, after)
    record = RoundRecord(name, repetition, summarise_round(observations, wall), delta,
                         clean(delta, expected_requests=len(payloads), in_flight_after=busy_after))
    if not record.clean:
        counted = "an unreadable delta" if delta is None else f"{delta.requests:g} requests"
        print(f"warning: round {name}#{repetition} contaminated: the bridge counted {counted} "
              f"(this probe sent {len(payloads)}) and {busy_after} still in flight", file=sys.stderr)
    return record


def record_json(record: RoundRecord) -> dict:
    accepted = acceptance(record.delta) if record.delta is not None else None
    return {"name": record.name, "repetition": record.repetition, "stats": asdict(record.stats),
            "delta": asdict(record.delta) if record.delta is not None else None,
            "acceptance": asdict(accepted) if accepted is not None else None, "clean": record.clean}


def parse_options(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--bridge", default="http://127.0.0.1:8011",
                        help="the model-labelled metrics bridge (hyperflare:* counters)")
    parser.add_argument("--model", default="", help="default: the endpoint's first served id")
    parser.add_argument("--key-file", default=str(Path.home() / ".config/glm53/api-key"))
    parser.add_argument("--rounds", default="c1,c4,c8,prefill",
                        help=f"comma list of {', '.join(ROUND_CONCURRENCY)}")
    parser.add_argument("--repeat", type=int, default=3, help="clean repetitions wanted per round")
    parser.add_argument("--retries", type=int, default=4,
                        help="extra attempts per round when another client contaminates one")
    parser.add_argument("--settle", type=float, default=0.3,
                        help="seconds between a round's last token and reading the bridge")
    parser.add_argument("--warmup", type=int, default=1, help="discarded warm-up requests")
    parser.add_argument("--max-tokens", type=int, default=1500)
    parser.add_argument("--temperature", type=float, default=1.0, help="default: the model's generation_config")
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--reasoning-effort", default="low", choices=("low", "high", "max"))
    parser.add_argument("--prefill-sentences", type=int, default=750, help="about 22K tokens")
    parser.add_argument("--prefill-max-tokens", type=int, default=8)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--idle-timeout", type=float, default=300.0)
    parser.add_argument("--out", type=Path, default=None)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    options = parse_options(argv)
    rounds = [name.strip() for name in options.rounds.split(",") if name.strip()]
    unknown = [name for name in rounds if name not in ROUND_CONCURRENCY]
    if unknown:
        print(f"error: unknown round(s) {', '.join(unknown)}; known: {', '.join(ROUND_CONCURRENCY)}", file=sys.stderr)
        return 2
    key_path = Path(options.key_file)
    key = key_path.read_text().strip() or None if key_path.is_file() else None
    try:
        model = options.model or json.loads(fetch_text(f"{options.url}/v1/models", key))["data"][0]["id"]
        scrape(options.bridge)
        for index in range(options.warmup):
            wait_idle(options.bridge, options.idle_timeout)
            stream_request(options.url, key, request_payload(model, decode_prompt(index, uuid.uuid4().hex[:8]), 64,
                                                             options.temperature, options.top_p,
                                                             options.reasoning_effort), options.timeout)
        records: list[RoundRecord] = []
        for name in rounds:
            wanted, attempts = 0, 0
            while wanted < options.repeat and attempts < options.repeat + options.retries:
                attempts += 1
                record = run_round(options, key, model, name, attempts)
                records.append(record)
                wanted += record.clean
    except (ProbeError, urllib.error.URLError, OSError, KeyError, IndexError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    rows = summarise_run(records)
    print(f"model {model} · {options.url} · temperature {options.temperature} top_p {options.top_p} · "
          f"effort {options.reasoning_effort} · max_tokens {options.max_tokens} · {options.repeat} repetition(s)")
    print(format_table(rows))
    if options.out:
        options.out.parent.mkdir(parents=True, exist_ok=True)
        options.out.write_text(json.dumps({
            "kind": "hyperflare-throughput-probe", "model": model, "url": options.url,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "parameters": {"max_tokens": options.max_tokens, "temperature": options.temperature,
                           "top_p": options.top_p, "reasoning_effort": options.reasoning_effort,
                           "repeat": options.repeat, "prefill_sentences": options.prefill_sentences},
            "rounds": [record_json(record) for record in records],
            "summary": [asdict(row) for row in rows],
        }, indent=1) + "\n")
        print(f"\nreceipt: {options.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
