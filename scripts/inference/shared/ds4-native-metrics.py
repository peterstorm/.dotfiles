#!/usr/bin/env python3
"""Bridge the ds4-native engine's counters into Prometheus and the token ledger.

The native DeepSeek stack is `ds4n-serve` behind Project Maya's server. Maya
exposes `GET /metrics` (JSON) and `GET /metrics/prometheus` (text) behind the
shared inference API key. Prometheus scrapes unauthenticated targets on port
8000 today, and the durable recorder needs `model_name` labels and cumulative
token counters that Maya's exposition does not carry — so this bridge does the
translation once, at the edge:

  maya's server (:8000, bearer key)  ->  this bridge (:8010, no auth)

It polls the server's cached state every `DS4_NATIVE_POLL_SECONDS`; it never
writes to `ds4n-serve`'s stdin and never asks the engine to do work, so prefill
and decode are untouched. `/metrics?requests=all` is the same snapshot the
Monitor tab reads: last finished requests, totals, expert-tier gauges.

Why the extra request for the request history: Maya exposes cumulative token
totals but no latency histograms. Each new finished request carries prompt_ms,
decode_ms and output_tokens; accruing those into cumulative buckets gives the
Grafana dashboard the same TTFT / inter-token / end-to-end series it gets from
vLLM and SGLang. Requests are identified by their full history row, so a scrape
or a restart can never count one twice.

Exposition contract (consumed by `tests/inference-monitoring-contract.sh`):
  ds4:prompt_tokens_total          prompt tokens read + served from the cache
  ds4:generation_tokens_total      generated tokens
  ds4:requests_total               finished requests
  ds4:e2e_request_latency_seconds_bucket / _sum / _count
  ds4:time_to_first_token_seconds_bucket / _sum / _count
  ds4:inter_token_latency_seconds_bucket / _sum / _count
  ds4:spec_drafts_total            DSpark drafts offered
  ds4:spec_accepted_total          DSpark drafts kept
plus the expert-tier gauges and `model_name` on every series.

A 503 means "no native engine behind me right now" (vLLM profile active,
container stopped, or auth failed); the recorder then skips the interval, so a
runtime switch cannot splice counters into the wrong series.
"""
import json
import math
import os
import sys
import threading
import time
import urllib.request
from dataclasses import dataclass, replace
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

DEFAULT_SOURCE = "http://127.0.0.1:8000"
DEFAULT_LISTEN = "0.0.0.0:8010"
DEFAULT_KEY_FILE = "~/.config/ds4-flash/api-key"
POLL_SECONDS = float(os.environ.get("DS4_NATIVE_POLL_SECONDS", "15"))
STALE_AFTER_SECONDS = float(os.environ.get("DS4_NATIVE_STALE_SECONDS", "90"))
HTTP_TIMEOUT_SECONDS = 5.0

# Maya's exposition must contain these for the server to be ds4-native rather
# than a vLLM/SGLang container reusing port 8000.
REQUIRED_GAUGES = (
    "llamacpp:prompt_tokens_total",
    "llamacpp:tokens_predicted_total",
    "maya:requests_total",
)

BUCKETS = {
    "e2e": (0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 320.0),
    "ttft": (0.05, 0.1, 0.25, 0.5, 1.0, 2.5, 5.0, 10.0, 20.0, 40.0, 80.0, 160.0, 320.0),
    "itl": (0.001, 0.005, 0.01, 0.02, 0.03, 0.05, 0.1, 0.2, 0.5, 1.0),
}

HISTOGRAM_HELP = {
    "e2e": "Finished request wall time from prompt read to last token, seconds",
    "ttft": "Finished request prompt read time (first token), seconds",
    "itl": "Finished request generation time per output token, seconds",
}

HISTOGRAM_NAMES = {
    "e2e": "ds4:e2e_request_latency_seconds",
    "ttft": "ds4:time_to_first_token_seconds",
    "itl": "ds4:inter_token_latency_seconds",
}


# --- functional core -------------------------------------------------------

@dataclass(frozen=True)
class Histogram:
    kind: str
    counts: tuple[int, ...]        # cumulative: one count per upper bound
    total: int
    total_sum: float


@dataclass(frozen=True)
class Snapshot:
    """Everything one exposition needs; values keyed by Maya's raw names."""
    model: str
    values: dict[str, float]
    histograms: dict[str, Histogram]
    spec_drafts: float
    spec_accepted: float


def parse_gauges(text: str) -> dict[str, float]:
    """Read unlabelled `name value` exposition lines (Maya's format)."""
    values = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name, _, rest = line.partition(" ")
        rest = rest.strip()
        if not name or not rest:
            continue
        try:
            values[name] = float(rest.split()[0])
        except ValueError:
            continue
    return values


def empty_histogram(kind: str) -> Histogram:
    return Histogram(kind, tuple(0 for _ in BUCKETS[kind]), 0, 0.0)


def observe(histogram: Histogram, value: float) -> Histogram:
    """Fold one observation into cumulative buckets; NaN/inf are ignored."""
    if not math.isfinite(value) or value < 0:
        return histogram
    counts = tuple(
        count + (1 if value <= bound else 0)
        for count, bound in zip(histogram.counts, BUCKETS[histogram.kind])
    )
    return replace(
        histogram,
        counts=counts,
        total=histogram.total + 1,
        total_sum=histogram.total_sum + value,
    )


def empty_snapshot(model: str) -> Snapshot:
    return Snapshot(
        model=model,
        values={},
        histograms={kind: empty_histogram(kind) for kind in BUCKETS},
        spec_drafts=0.0,
        spec_accepted=0.0,
    )


def row_key(row: dict) -> str:
    """A finished request's full row; immutable once Maya appends it."""
    return json.dumps(row, sort_keys=True, separators=(",", ":"))


def unseen(seen: set[str], rows: list[dict]) -> tuple[set[str], list[dict]]:
    """Return the current row identities and the rows not yet counted."""
    current = {row_key(row) for row in rows}
    return current, [row for row in rows if row_key(row) not in seen]


def observations(row: dict) -> list[tuple[str, float]]:
    """Turn one finished request into histogram observations."""
    try:
        prompt_ms = float(row.get("prompt_ms") or 0.0)
        decode_ms = float(row.get("decode_ms") or 0.0)
        output_tokens = float(row.get("output_tokens") or 0.0)
    except (TypeError, ValueError):
        return []
    found = []
    if prompt_ms > 0:
        found.append(("ttft", prompt_ms / 1000.0))
    if decode_ms > 0 and output_tokens > 0:
        found.append(("itl", decode_ms / 1000.0 / output_tokens))
    if prompt_ms > 0 and decode_ms > 0:
        found.append(("e2e", (prompt_ms + decode_ms) / 1000.0))
    return found


def spec_counts(row: dict) -> tuple[float, float]:
    """(offered, accepted) DSpark drafts; (0, 0) when the engine drafted none."""
    try:
        offered = float(row.get("drafts_offered") or 0.0)
        accepted = float(row.get("drafts_accepted") or 0.0)
    except (TypeError, ValueError):
        return 0.0, 0.0
    return max(offered, 0.0), max(accepted, 0.0)


def accrue(snapshot: Snapshot, rows: list[dict]) -> Snapshot:
    """Fold newly finished requests into the cumulative histograms."""
    histograms = dict(snapshot.histograms)
    drafts = snapshot.spec_drafts
    accepted = snapshot.spec_accepted
    for row in rows:
        for kind, value in observations(row):
            histograms[kind] = observe(histograms[kind], value)
        offered, kept = spec_counts(row)
        drafts += offered
        accepted += kept
    return replace(snapshot, histograms=histograms, spec_drafts=drafts, spec_accepted=accepted)


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def format_value(value: float) -> str:
    if not math.isfinite(value):
        return "NaN"
    if float(value).is_integer():
        return str(int(value))
    return repr(float(value))


def gauge(values: dict[str, float], name: str) -> float:
    return values.get(name, 0.0)


def render(snapshot: Snapshot) -> str:
    """Render one Prometheus exposition; every series carries model_name."""
    model = escape_label(snapshot.model)
    labels = f'model_name="{model}"'
    v = snapshot.values

    evaluated = gauge(v, "llamacpp:prompt_tokens_total")
    cached = gauge(v, "llamacpp:prompt_tokens_cached_total")

    rows = [
        ("ds4:prompt_tokens_total", "counter", "Prompt tokens read or served from the conversation cache", evaluated + cached),
        ("ds4:prompt_tokens_evaluated_total", "counter", "Prompt tokens the engine read from the checkpoint cache", evaluated),
        ("ds4:prompt_tokens_cached_total", "counter", "Prompt tokens the kept conversation already held", cached),
        ("ds4:generation_tokens_total", "counter", "Generated tokens", gauge(v, "llamacpp:tokens_predicted_total")),
        ("ds4:requests_total", "counter", "Finished requests", gauge(v, "maya:requests_total")),
        ("ds4:requests_running", "gauge", "Requests running", gauge(v, "llamacpp:requests_processing")),
        ("ds4:requests_waiting", "gauge", "Requests waiting their turn", gauge(v, "llamacpp:requests_deferred")),
        ("ds4:prefix_cache_hits_total", "counter", "Prompt tokens served from the conversation cache", cached),
        ("ds4:prefix_cache_queries_total", "counter", "Prompt tokens queried against the conversation cache", evaluated + cached),
        ("ds4:decode_tokens_per_second", "gauge", "Decode rate over the running request, tokens/s", gauge(v, "maya:engine_tok_s")),
        ("ds4:expert_cache_residency", "gauge", "Share of routed experts found in VRAM (0..1)", gauge(v, "maya:engine_vram_hit")),
        ("ds4:expert_slots_used", "gauge", "Expert slots in use in VRAM", gauge(v, "maya:engine_vram_used")),
        ("ds4:expert_slots", "gauge", "Expert slots in VRAM", gauge(v, "maya:engine_vram_slots")),
        ("ds4:ram_slots_used", "gauge", "Expert slots in use in the RAM tier", gauge(v, "maya:engine_ram_used")),
        ("ds4:ram_slots", "gauge", "Expert slots in the RAM tier", gauge(v, "maya:engine_ram_slots")),
        ("ds4:parked_conversations", "gauge", "Conversations parked in host RAM", gauge(v, "maya:engine_slot_ram")),
        ("ds4:parked_conversation_bytes", "gauge", "Parked conversation payload bytes in host RAM", gauge(v, "maya:engine_slot_ram_bytes")),
        ("ds4:engine_alive", "gauge", "1 while the engine process runs", gauge(v, "maya:engine_alive")),
        ("ds4:spec_drafts_total", "counter", "DSpark drafts offered at verification", snapshot.spec_drafts),
        ("ds4:spec_accepted_total", "counter", "DSpark drafts kept", snapshot.spec_accepted),
    ]

    lines = [
        "# HELP ds4:model_info The served model behind the bridge",
        "# TYPE ds4:model_info gauge",
        f"ds4:model_info{{{labels}}} 1",
    ]
    for name, kind, help_, number in rows:
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {kind}")
        lines.append(f"{name}{{{labels}}} {format_value(number)}")

    for kind in BUCKETS:
        histogram = snapshot.histograms[kind]
        base = HISTOGRAM_NAMES[kind]
        lines.append(f"# HELP {base} {HISTOGRAM_HELP[kind]}")
        lines.append(f"# TYPE {base} histogram")
        for bound, count in zip(BUCKETS[kind], histogram.counts):
            lines.append(f'{base}_bucket{{{labels},le="{format_value(bound)}"}} {count}')
        lines.append(f'{base}_bucket{{{labels},le="+Inf"}} {histogram.total}')
        lines.append(f"{base}_sum{{{labels}}} {format_value(histogram.total_sum)}")
        lines.append(f"{base}_count{{{labels}}} {histogram.total}")
    return "\n".join(lines) + "\n"


# --- imperative shell ------------------------------------------------------

class SourceCache:
    """Poll Maya once per interval; serve the last good snapshot to scrapes."""

    def __init__(self, source: str, key_file: Path):
        self.source = source.rstrip("/")
        self.key_file = key_file
        self._lock = threading.Lock()
        self._snapshot = None
        self._seen: set[str] = set()
        self._newest = 0.0
        self._last_ok = 0.0
        self._last_error = "no poll yet"

    def _get(self, path: str) -> str:
        key = self.key_file.read_text().strip()
        request = urllib.request.Request(
            self.source + path,
            headers={"Authorization": f"Bearer {key}"},
        )
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.read().decode("utf-8")

    def _model(self) -> str:
        payload = json.loads(self._get("/v1/models"))
        models = payload.get("data") or []
        if not models or not models[0].get("id"):
            raise ValueError("no served model")
        return str(models[0]["id"])

    def poll(self) -> None:
        try:
            values = parse_gauges(self._get("/metrics/prometheus"))
            missing = [name for name in REQUIRED_GAUGES if name not in values]
            if missing:
                raise ValueError(f"not a ds4-native server (missing {', '.join(missing)})")
            model = self._model()
            history = json.loads(self._get("/metrics?requests=all"))
            rows = history.get("requests") or []
            newest = max((float(row.get("time") or 0.0) for row in rows), default=0.0)
            with self._lock:
                previous = self._snapshot
                restarted = (
                    previous is None
                    or previous.model != model
                    or gauge(values, "maya:requests_total") < gauge(previous.values, "maya:requests_total")
                    or newest < self._newest
                )
                snapshot = empty_snapshot(model) if restarted else previous
                seen = set() if restarted else self._seen
                self._seen, fresh = unseen(seen, rows)
                self._snapshot = accrue(replace(snapshot, values=values), fresh)
                self._newest = newest
                recovered = self._last_error is not None
                self._last_ok = time.monotonic()
                self._last_error = None
            if recovered:
                sys.stderr.write("ds4-native-metrics: poll recovered\n")
        except (OSError, ValueError, KeyError, json.JSONDecodeError) as error:
            message = f"{type(error).__name__}: {error}"
            with self._lock:
                changed = message != self._last_error
                self._last_error = message
            if changed:
                sys.stderr.write(f"ds4-native-metrics: poll failed: {message}\n")

    def exposition(self) -> tuple[int, str]:
        with self._lock:
            snapshot, last_ok, error = self._snapshot, self._last_ok, self._last_error
        if snapshot is None or time.monotonic() - last_ok > STALE_AFTER_SECONDS:
            return 503, f"# ds4-native bridge has no fresh snapshot: {error}\n"
        return 200, render(snapshot)


class Handler(BaseHTTPRequestHandler):
    cache: SourceCache

    def do_GET(self):  # noqa: N802 (http.server's spelling)
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        status, body = self.cache.exposition()
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        # Every scrape is 200; log only the requests that are not.
        if self.command == "GET" and self.path.split("?", 1)[0] == "/metrics":
            return
        sys.stderr.write("ds4-native-metrics: " + fmt % args + "\n")


def parse_listen(raw: str) -> tuple[str, int]:
    host, _, port = raw.rpartition(":")
    return (host or "0.0.0.0"), int(port)


def poll_forever(cache: SourceCache) -> None:
    while True:
        cache.poll()
        time.sleep(POLL_SECONDS)


def main() -> int:
    source = os.environ.get("DS4_NATIVE_SOURCE", DEFAULT_SOURCE)
    listen = os.environ.get("DS4_NATIVE_LISTEN", DEFAULT_LISTEN)
    key_file = Path(os.environ.get("DS4_NATIVE_KEY_FILE", DEFAULT_KEY_FILE)).expanduser()
    if not key_file.is_file():
        sys.stderr.write(f"ds4-native-metrics: API key file missing: {key_file}\n")
        return 2

    cache = SourceCache(source, key_file)
    cache.poll()
    threading.Thread(target=poll_forever, args=(cache,), daemon=True).start()
    Handler.cache = cache
    host, port = parse_listen(listen)
    server = HTTPServer((host, port), Handler)
    sys.stderr.write(f"ds4-native-metrics: {source} -> {host}:{port} every {POLL_SECONDS:g}s\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
