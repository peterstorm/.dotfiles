#!/usr/bin/env python3
# Probes for the GLM-cyber thinking spiral (`their-ih-ih-ih-…`): is it the context, or the model?
#
#   replay   Rebuild the request a real Pi session sent (its compaction summary, the replayed
#            reasoning, the tool results) and sample the next turn under named conditions with
#            fixed seeds, scoring the reasoning for degeneration. Run the same replay against
#            another model (v16) to separate "the context is polluted" from "this model spirals".
#   passkey  Hide a random key at a depth in a long natural-text prompt and ask for it back. Long-
#            context attention fails here first, so it checks the weights' long-context behaviour
#            without any template or sampling involved.
#
# Design: the drift metric, the session-to-conversation conversion and the prompt/request builders
# are pure and unit-tested (tests/glm-drift-probe-unit.py); HTTP, threads and files are the shell.
"""GLM thinking-spiral probes: session replay and passkey retrieval."""

from __future__ import annotations

import argparse
import json
import random
import statistics
import sys
import time
import urllib.error
import urllib.request
import zlib
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Sequence

# ------------------------------------------------------------------ pure: the drift metric

WINDOW = 600
STEP = 300
#: A 600-char window of reasoning that zlib squeezes below this is a loop (healthy prose sits at 0.45-0.65).
LOOP_RATIO = 0.20
#: A window of an English conversation that is more than this share non-ASCII has drifted into another script.
DRIFT_SHARE = 0.25


@dataclass(frozen=True)
class Drift:
    chars: int
    worst_ratio: float | None
    worst_nonascii: float | None
    onset: int | None
    verdict: str  # "ok" | "loop" | "drift" | "short"


def drift_of(text: str) -> Drift:
    """Score reasoning text for degeneration, window by window; the verdict follows the earliest trigger.

    Meant for reasoning prose: a final answer holding a markdown table or an ASCII rule compresses well
    legitimately and would read as a loop.
    """
    if len(text) < WINDOW:
        return Drift(len(text), None, None, None, "short")
    starts = list(range(0, len(text) - WINDOW + 1, STEP))
    if starts[-1] != len(text) - WINDOW:
        starts.append(len(text) - WINDOW)
    worst_ratio, worst_nonascii, onset, verdict = 1.0, 0.0, None, "ok"
    for start in starts:
        window = text[start:start + WINDOW]
        raw = window.encode()
        ratio = len(zlib.compress(raw, 9)) / len(raw)
        nonascii = sum(1 for char in window if ord(char) > 127) / len(window)
        worst_ratio, worst_nonascii = min(worst_ratio, ratio), max(worst_nonascii, nonascii)
        if onset is None and (ratio < LOOP_RATIO or nonascii > DRIFT_SHARE):
            onset, verdict = start, ("loop" if ratio < LOOP_RATIO else "drift")
    return Drift(len(text), worst_ratio, worst_nonascii, onset, verdict)


# ------------------------------------------------- pure: a Pi session as an OpenAI conversation

SYSTEM_PROMPT = "You are a coding assistant working in a terminal. Use your tools when they help."
COMPACTION_PREFIX = "The conversation history before this point was compacted into the following summary:"


def _text(blocks: object) -> str:
    if isinstance(blocks, str):
        return blocks
    if not isinstance(blocks, list):
        return ""
    return "".join(block.get("text", "") for block in blocks if isinstance(block, dict) and block.get("type") == "text")


def _convert(entry: dict) -> dict | None:
    """One session entry as an OpenAI chat message, or None when Pi would not send it."""
    kind = entry.get("type")
    if kind == "custom_message":
        content = entry.get("content")
        return {"role": "user", "content": content} if isinstance(content, str) else None
    if kind != "message":
        return None
    message = entry.get("message") or {}
    role = message.get("role")
    if role == "user":
        return {"role": "user", "content": _text(message.get("content"))}
    if role == "toolResult":
        return {"role": "tool", "tool_call_id": message.get("toolCallId", ""), "content": _text(message.get("content"))}
    if role != "assistant" or message.get("stopReason") in ("aborted", "error"):
        return None
    blocks = [block for block in (message.get("content") or []) if isinstance(block, dict)]
    calls = [
        {"id": block.get("id", ""), "type": "function",
         "function": {"name": block.get("name", ""), "arguments": json.dumps(block.get("arguments") or {})}}
        for block in blocks if block.get("type") == "toolCall"
    ]
    converted = {
        "role": "assistant",
        "content": "".join(block.get("text", "") for block in blocks if block.get("type") == "text"),
        # Pi's compat flag requires an (empty) reasoning_content on every replayed assistant message.
        "reasoning_content": "".join(block.get("thinking", "") for block in blocks if block.get("type") == "thinking"),
    }
    if calls:
        converted["tool_calls"] = calls
    return converted


def session_messages(entries: Sequence[dict], target: int) -> list[dict]:
    """The conversation Pi would send for the assistant turn at entries[target]: the latest earlier
    compaction's summary, then every message from its firstKeptEntryId up to (excluding) the target."""
    if not 0 <= target < len(entries):
        raise ValueError(f"target {target} is outside the session ({len(entries)} entries)")
    compaction = next((i for i in range(target - 1, -1, -1) if entries[i].get("type") == "compaction"), None)
    messages: list[dict] = [{"role": "system", "content": SYSTEM_PROMPT}]
    start = 0
    if compaction is not None:
        summary = entries[compaction].get("summary", "")
        messages.append({"role": "user", "content": f"{COMPACTION_PREFIX}\n\n<summary>\n{summary}\n</summary>"})
        kept = entries[compaction].get("firstKeptEntryId")
        start = next((i for i, entry in enumerate(entries[:compaction]) if entry.get("id") == kept), compaction + 1)
    for entry in entries[start:target]:
        converted = _convert(entry)
        if converted is not None:
            messages.append(converted)
    return messages


# --------------------------------------------------------------- pure: requests and prompts

#: A deliberately tight cap, to see enforcement: the model must close its reasoning and answer.
CAP_TOKENS = 3072
CONDITIONS: dict[str, dict] = {
    "baseline": {},
    "clear": {"chat_template_kwargs": {"clear_thinking": True}},
    "clear+cap": {"chat_template_kwargs": {"clear_thinking": True}, "thinking_token_budget": CAP_TOKENS},
    # The length-matched control for `clear`: same cleared reasoning, but the prompt is padded back out with
    # irrelevant prose, so a difference from `clear` is sheer context length and not the replayed reasoning.
    "clear+pad": {"chat_template_kwargs": {"clear_thinking": True}},
    # The chain-aware family. `clear_thinking` drops only earlier USER turns' reasoning, so inside one long tool
    # chain every turn's reasoning stays, and in a chain-heavy session that is most of what is replayed. These blank
    # the reasoning of older assistant turns whatever turn they belong to: `strip` of all of them, `keepN` of all
    # but the N most recent.
    "strip": {"chat_template_kwargs": {"clear_thinking": True}},
    "keep1": {"chat_template_kwargs": {"clear_thinking": True}},
    "keep3": {"chat_template_kwargs": {"clear_thinking": True}},
}
PADDED = frozenset({"clear+pad"})
#: How many of the most recent assistant turns keep their reasoning, per chain-aware condition.
KEEP_LAST = {"strip": 0, "keep1": 1, "keep3": 3}


def seeds(count: int, start: int = 1) -> list[int]:
    return list(range(start, start + count))


def replay_payload(model: str, messages: Sequence[dict], condition: str, seed: int, max_tokens: int, pad: str = "") -> dict:
    """The request for one replay sample. `baseline` is what Pi sends at max thinking, nothing more."""
    if condition not in CONDITIONS:
        raise ValueError(f"unknown condition {condition!r}; known: {', '.join(CONDITIONS)}")
    if condition in PADDED and not pad:
        raise ValueError(f"condition {condition!r} needs padding text")
    conversation = [dict(message) for message in messages]
    if condition in KEEP_LAST:
        assistant = [i for i, message in enumerate(conversation) if message.get("role") == "assistant"]
        for i in assistant[: max(0, len(assistant) - KEEP_LAST[condition])]:
            conversation[i]["reasoning_content"] = ""
    if condition in PADDED:
        lead = 1 if conversation and conversation[0].get("role") == "system" else 0
        conversation.insert(lead, {"role": "user", "content": "Reference material for later (not relevant to the task below; ignore it):\n\n" + pad})
    payload: dict = {
        "model": model,
        "messages": conversation,
        "max_tokens": max_tokens,
        "stream": False,
        "seed": seed,
        "thinking": {"type": "enabled"},
        "reasoning_effort": "max",
    }
    payload.update(json.loads(json.dumps(CONDITIONS[condition])))
    return payload


KEY_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # nothing a model could misread: no 0 O 1 I L


def make_key(rng: random.Random) -> str:
    return "".join(rng.choice(KEY_ALPHABET) for _ in range(8))


def passkey_prompt(filler: str, key: str, depth: float) -> str:
    """The filler with the key hidden at `depth` (snapped to the next paragraph break), then the question."""
    cut = filler.find("\n\n", int(len(filler) * depth))
    cut = len(filler) if cut == -1 else cut
    needle = f"\n\nThe secret passkey for the vault is {key}. Remember it.\n\n"
    question = "\n\nQuestion: what is the secret passkey for the vault? Reply with only the passkey."
    return filler[:cut] + needle + filler[cut:] + question


def passkey_found(answer: str, key: str) -> bool:
    return key in answer


# ------------------------------------------------------------------------ imperative shell


class ProbeError(Exception):
    """A request that could not be made or answered."""


def post(url: str, key: str | None, payload: dict, timeout: float) -> dict:
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    request = urllib.request.Request(f"{url}/v1/chat/completions", json.dumps(payload).encode(), headers)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        raise ProbeError(f"HTTP {error.code}: {error.read().decode(errors='replace')[:200]}") from error
    except (urllib.error.URLError, OSError, ValueError) as error:
        raise ProbeError(str(error)) from error


def served_model(url: str, key: str | None) -> str:
    headers = {"Authorization": f"Bearer {key}"} if key else {}
    with urllib.request.urlopen(urllib.request.Request(f"{url}/v1/models", headers=headers), timeout=15) as response:
        return str(json.loads(response.read())["data"][0]["id"])


def _message(reply: dict) -> tuple[str, str, str]:
    choice = (reply.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    thinking = message.get("reasoning_content") or message.get("reasoning") or ""
    return str(thinking), str(message.get("content") or ""), str(choice.get("finish_reason") or "")


def _median(values: Sequence[float]) -> float | None:
    return statistics.median(values) if values else None


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--url", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default="", help="default: the endpoint's served model")
    parser.add_argument("--key-file", default=str(Path.home() / ".config/glm53/api-key"))
    parser.add_argument("--concurrency", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--out", type=Path, default=None)


def parse_options(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    replay = commands.add_parser("replay", help="replay a Pi session turn under named conditions")
    _common(replay)
    replay.add_argument("--session", type=Path, required=True, help="a Pi session .jsonl")
    replay.add_argument("--target", type=int, required=True, help="entry index of the assistant turn to reproduce")
    replay.add_argument("--conditions", default="baseline,clear", help=f"comma list of {', '.join(CONDITIONS)}")
    replay.add_argument("--samples", type=int, default=8, help="seeds per condition (the same seeds in every condition)")
    replay.add_argument("--seed-start", type=int, default=1, help="first seed, to add samples to an earlier run")
    replay.add_argument("--haystack", type=Path, default=None, help="a directory of .md files, the filler for clear+pad")
    replay.add_argument("--pad-chars", type=int, default=0, help="filler size for clear+pad (about 3.6 chars per token)")
    replay.add_argument("--max-tokens", type=int, default=8192)
    passkey = commands.add_parser("passkey", help="hide a key in a long natural-text prompt and ask for it")
    _common(passkey)
    passkey.add_argument("--contexts", default="8000,32000,96000,192000", help="prompt sizes in tokens")
    passkey.add_argument("--depths", default="0.1,0.5,0.9")
    passkey.add_argument("--trials", type=int, default=2)
    passkey.add_argument("--haystack", type=Path, required=True, help="a directory of .md files to draw filler from")
    passkey.add_argument("--chars-per-token", type=float, default=3.6)
    passkey.add_argument("--max-tokens", type=int, default=400)
    return parser.parse_args(argv)


def _setup(options: argparse.Namespace, default_out: str) -> tuple[str | None, str, Path]:
    key_path = Path(options.key_file)
    key = key_path.read_text().strip() or None if key_path.is_file() else None
    model = options.model or served_model(options.url, key)
    out = options.out or Path(default_out)
    out.mkdir(parents=True, exist_ok=True)
    return key, model, out


# -------------------------------------------------------------------------------- replay


def run_replay(options: argparse.Namespace) -> int:
    try:
        entries = [json.loads(line) for line in options.session.read_text().splitlines() if line.strip()]
        messages = session_messages(entries, options.target)
    except (OSError, ValueError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
    conditions = [name.strip() for name in options.conditions.split(",") if name.strip()]
    unknown = [name for name in conditions if name not in CONDITIONS]
    if unknown:
        print(f"error: unknown condition(s) {', '.join(unknown)}; known: {', '.join(CONDITIONS)}", file=sys.stderr)
        return 2
    pad = ""
    if any(name in PADDED for name in conditions):
        files = sorted(options.haystack.rglob("*.md")) if options.haystack and options.haystack.is_dir() else []
        if not files or options.pad_chars <= 0:
            print("error: a padded condition needs --haystack DIR (with .md files) and --pad-chars N", file=sys.stderr)
            return 2
        pad = _filler(files, options.pad_chars, random.Random(0))
    try:
        key, model, out = _setup(options, "/tmp/glm-drift-replay")
    except (urllib.error.URLError, OSError, KeyError, IndexError, ValueError) as error:
        print(f"error: cannot reach {options.url}: {error}", file=sys.stderr)
        return 1
    (out / "runs").mkdir(exist_ok=True)
    jobs = [(condition, seed) for condition in conditions for seed in seeds(options.samples, options.seed_start)]

    def one(job: tuple[str, int]) -> dict:
        condition, seed = job
        started = time.monotonic()
        payload = replay_payload(model, messages, condition, seed, options.max_tokens, pad)
        try:
            reply = post(options.url, key, payload, options.timeout)
        except ProbeError as error:
            return {"condition": condition, "seed": seed, "error": str(error)}
        thinking, content, finish = _message(reply)
        usage = reply.get("usage") or {}
        drift = drift_of(thinking)
        run = {"condition": condition, "seed": seed, "finish": finish, "latency_s": round(time.monotonic() - started, 1),
               "prompt_tokens": usage.get("prompt_tokens"), "completion_tokens": usage.get("completion_tokens"),
               "thinking_chars": len(thinking), "content_chars": len(content), "drift": asdict(drift)}
        (out / "runs" / f"{condition}-{seed}.json").write_text(json.dumps({**run, "thinking": thinking, "content": content}, indent=1))
        return run

    with ThreadPoolExecutor(max_workers=options.concurrency) as pool:
        runs = list(pool.map(one, jobs))
    summary = []
    for condition in conditions:
        mine = [run for run in runs if run["condition"] == condition]
        good = [run for run in mine if "error" not in run]
        bad = [run for run in good if run["drift"]["verdict"] in ("loop", "drift")]
        summary.append({
            "condition": condition, "samples": len(mine), "answered": len(good), "degenerate": len(bad),
            "loops": sum(1 for run in bad if run["drift"]["verdict"] == "loop"),
            "drifts": sum(1 for run in bad if run["drift"]["verdict"] == "drift"),
            "median_thinking_chars": _median([run["thinking_chars"] for run in good]),
            "median_onset_chars": _median([run["drift"]["onset"] for run in bad]),
            "prompt_tokens": _median([run["prompt_tokens"] for run in good if run["prompt_tokens"]]),
            "finishes": {finish: sum(1 for run in good if run["finish"] == finish) for finish in sorted({run["finish"] for run in good})},
        })
    (out / "receipt.json").write_text(json.dumps({
        "kind": "glm-drift-replay", "model": model, "url": options.url, "session": str(options.session),
        "target": options.target, "max_tokens": options.max_tokens, "messages": len(messages),
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "summary": summary, "runs": runs}, indent=1) + "\n")
    print(f"model {model} · session turn {options.target} · {len(messages)} messages · max_tokens {options.max_tokens}")
    header = f"{'condition':<11}{'spiral':>8}{'loop':>6}{'drift':>7}{'thinking chars (median)':>26}{'onset':>8}{'prompt tok':>12}  finishes"
    print(header)
    print("-" * len(header))
    for row in summary:
        print(f"{row['condition']:<11}{str(row['degenerate']) + '/' + str(row['samples']):>8}{row['loops']:>6}{row['drifts']:>7}"
              f"{(row['median_thinking_chars'] or 0):>26,.0f}{(row['median_onset_chars'] if row['median_onset_chars'] is not None else 0):>8,.0f}"
              f"{(row['prompt_tokens'] or 0):>12,.0f}  {row['finishes']}")
    failed = sum(1 for run in runs if "error" in run)
    if failed:
        print(f"warning: {failed} of {len(runs)} requests failed (first: {next(run['error'] for run in runs if 'error' in run)})", file=sys.stderr)
    print(f"\nreceipt: {out / 'receipt.json'}")
    return 0 if failed < len(runs) else 1


# ------------------------------------------------------------------------------- passkey


def _filler(files: Sequence[Path], chars: int, rng: random.Random) -> str:
    order = list(files)
    rng.shuffle(order)
    parts: list[str] = []
    total = 0
    for path in order:
        text = path.read_text(errors="replace").strip()
        parts.append(text)
        total += len(text) + 2
        if total >= chars:
            break
    joined = "\n\n".join(parts)
    cut = joined.rfind("\n\n", 0, chars)
    return joined[:chars] if cut < chars // 2 else joined[:cut]


def run_passkey(options: argparse.Namespace) -> int:
    files = sorted(options.haystack.rglob("*.md")) if options.haystack.is_dir() else []
    if not files:
        print(f"error: no .md files under {options.haystack}", file=sys.stderr)
        return 2
    contexts = [int(value) for value in options.contexts.split(",") if value.strip()]
    depths = [float(value) for value in options.depths.split(",") if value.strip()]
    try:
        key, model, out = _setup(options, "/tmp/glm-drift-passkey")
    except (urllib.error.URLError, OSError, KeyError, IndexError, ValueError) as error:
        print(f"error: cannot reach {options.url}: {error}", file=sys.stderr)
        return 1
    jobs = [(context, depth, trial) for context in contexts for depth in depths for trial in range(1, options.trials + 1)]

    def one(job: tuple[int, float, int]) -> dict:
        context, depth, trial = job
        rng = random.Random(f"{context}-{depth}-{trial}")
        secret = make_key(rng)
        prompt = passkey_prompt(_filler(files, int(context * options.chars_per_token), rng), secret, depth)
        payload = {"model": model, "messages": [{"role": "user", "content": prompt}], "max_tokens": options.max_tokens,
                   "stream": False, "seed": trial, "reasoning_effort": "low"}
        started = time.monotonic()
        try:
            reply = post(options.url, key, payload, options.timeout)
        except ProbeError as error:
            return {"context": context, "depth": depth, "trial": trial, "error": str(error)}
        thinking, content, finish = _message(reply)
        usage = reply.get("usage") or {}
        return {"context": context, "depth": depth, "trial": trial, "found": passkey_found(content, secret),
                "prompt_tokens": usage.get("prompt_tokens"), "latency_s": round(time.monotonic() - started, 1),
                "finish": finish, "answer": content[:120]}

    with ThreadPoolExecutor(max_workers=options.concurrency) as pool:
        runs = list(pool.map(one, jobs))
    cells = []
    for context in contexts:
        for depth in depths:
            mine = [run for run in runs if run["context"] == context and run["depth"] == depth and "error" not in run]
            cells.append({"context": context, "depth": depth, "trials": len(mine), "found": sum(1 for run in mine if run["found"]),
                          "prompt_tokens": _median([run["prompt_tokens"] for run in mine if run.get("prompt_tokens")])})
    (out / "receipt.json").write_text(json.dumps({
        "kind": "glm-passkey", "model": model, "url": options.url, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "cells": cells, "runs": runs}, indent=1) + "\n")
    print(f"model {model} · passkey retrieval, found/trials at each depth")
    header = f"{'context (tokens)':<18}{'measured':>10}" + "".join(f"{'depth ' + format(depth, 'g'):>12}" for depth in depths)
    print(header)
    print("-" * len(header))
    for context in contexts:
        row = [cell for cell in cells if cell["context"] == context]
        measured = row[0]["prompt_tokens"] if row and row[0]["prompt_tokens"] else 0
        print(f"{context:<18}{measured:>10,.0f}" + "".join(f"{str(cell['found']) + '/' + str(cell['trials']):>12}" for cell in row))
    failed = sum(1 for run in runs if "error" in run)
    if failed:
        print(f"warning: {failed} of {len(runs)} requests failed (first: {next(run['error'] for run in runs if 'error' in run)})", file=sys.stderr)
    print(f"\nreceipt: {out / 'receipt.json'}")
    return 0 if failed < len(runs) else 1


def main(argv: list[str]) -> int:
    options = parse_options(argv)
    return run_replay(options) if options.command == "replay" else run_passkey(options)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
