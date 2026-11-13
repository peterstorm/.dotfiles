#!/usr/bin/env python3
"""Bridge NVIDIA Hyperflare's counters into Prometheus and the token ledger.

Hyperflare (`flare run`, the GLM-5.3 v16 profile) serves Prometheus text on
:8000/metrics without auth, but its `flare_*` series carry no model label and
count prompt tokens differently from vLLM: `flare_prefill_tokens_total`
excludes prefix reuse, which Hyperflare reports separately for the GPU
checkpoint cache and the host prefix store. The durable recorder and the
`inference:*` dashboard contract both need model-labelled, like-for-like
counters, so this bridge translates once, at the edge:

  flare run (:8000/metrics, no auth; /v1/models, bearer key)  ->  :8011

The bridge is stateless. Every scrape of :8011/metrics fetches the engine's
own exposition and its served model id, translates, and answers; there is no
poll loop and no cached snapshot, so it can never serve stale numbers. It only
reads; prefill and decode are untouched. A 503 means "no Hyperflare engine
behind me right now" (another profile owns :8000, the container is stopped,
or the key is wrong); the recorder then skips the interval and Prometheus
records the target as down, so a runtime switch cannot splice counters.

Exposition contract (consumed by `tests/inference-monitoring-contract.sh`),
every series labelled model_name:
  hyperflare:prompt_tokens_total            prefilled + GPU-reused + host-reused
  hyperflare:prompt_tokens_prefilled_total  prompt tokens the GPUs computed
  hyperflare:prompt_tokens_cached_total     prompt tokens served from a prefix cache
  hyperflare:generation_tokens_total        committed generated tokens
  hyperflare:requests_total                 requests completed successfully
  hyperflare:requests_failed_total / hyperflare:requests_cancelled_total
  hyperflare:requests_running / hyperflare:requests_waiting
  hyperflare:kv_pages_used / hyperflare:kv_pages / hyperflare:kv_cache_usage_ratio
  hyperflare:spec_accepted_tokens_total     MTP drafts accepted (bonus token excluded)
  hyperflare:spec_draft_tokens_total        MTP draft positions verified
  hyperflare:spec_draft_rounds_total        request rounds that offered a draft
  hyperflare:spec_verify_rounds_total       progressing request rounds
  hyperflare:first_response_median_seconds  server-side TTFT median (rolling window; absent until sampled)
"""
import json
import math
import os
import sys
import urllib.request
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Union

DEFAULT_SOURCE = "http://127.0.0.1:8000"
DEFAULT_LISTEN = "0.0.0.0:8011"
DEFAULT_KEY_FILE = "~/.config/glm53/api-key"
HTTP_TIMEOUT_SECONDS = 5.0

# Unlabelled flare_* scalars the translation reads. Their presence is also
# what identifies the server on :8000 as Hyperflare rather than vLLM/SGLang/
# Maya reusing the port.
REQUIRED = (
    "flare_prefill_tokens_total",
    "flare_cache_reused_tokens_total",
    "flare_host_cache_reused_tokens_total",
    "flare_generated_tokens_total",
    "flare_requests_completed_total",
    "flare_requests_failed_total",
    "flare_requests_cancelled_total",
    "flare_active_requests",
    "flare_pending_requests",
    "flare_free_kv_pages",
    "flare_total_kv_pages",
    "flare_accepted_draft_tokens_total",
    "flare_verification_draft_tokens_total",
    "flare_draft_request_rounds_total",
    "flare_verification_request_rounds_total",
)
OPTIONAL = ("flare_first_response_median_seconds",)


# --- functional core -------------------------------------------------------

@dataclass(frozen=True)
class FlareCounters:
    """One parsed Hyperflare exposition; every required scalar is present."""
    prefilled: float
    gpu_reused: float
    host_reused: float
    generated: float
    completed: float
    failed: float
    cancelled: float
    active: float
    pending: float
    free_pages: float
    total_pages: float
    accepted_drafts: float
    draft_tokens: float
    draft_rounds: float
    verify_rounds: float
    first_response_median: Union[float, None]


@dataclass(frozen=True)
class NotHyperflare:
    """The exposition is not (or not yet) a Hyperflare server's."""
    reason: str


def unlabelled_scalars(text: str) -> dict[str, float]:
    """Read `name value` lines whose name has no label set."""
    values = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        name, _, rest = line.partition(" ")
        if not name or "{" in name:
            continue
        try:
            value = float(rest.split()[0])
        except (IndexError, ValueError):
            continue
        if math.isfinite(value):
            values[name] = value
    return values


def parse_flare(text: str) -> Union[FlareCounters, NotHyperflare]:
    """Parse once at the edge: either every counter the bridge needs, or why not."""
    values = unlabelled_scalars(text)
    missing = [name for name in REQUIRED if name not in values]
    if missing:
        return NotHyperflare(f"not a Hyperflare server (missing {', '.join(missing[:3])}"
                             f"{', ...' if len(missing) > 3 else ''})")
    return FlareCounters(
        prefilled=values["flare_prefill_tokens_total"],
        gpu_reused=values["flare_cache_reused_tokens_total"],
        host_reused=values["flare_host_cache_reused_tokens_total"],
        generated=values["flare_generated_tokens_total"],
        completed=values["flare_requests_completed_total"],
        failed=values["flare_requests_failed_total"],
        cancelled=values["flare_requests_cancelled_total"],
        active=values["flare_active_requests"],
        pending=values["flare_pending_requests"],
        free_pages=values["flare_free_kv_pages"],
        total_pages=values["flare_total_kv_pages"],
        accepted_drafts=values["flare_accepted_draft_tokens_total"],
        draft_tokens=values["flare_verification_draft_tokens_total"],
        draft_rounds=values["flare_draft_request_rounds_total"],
        verify_rounds=values["flare_verification_request_rounds_total"],
        first_response_median=values.get("flare_first_response_median_seconds"),
    )


def served_model(payload: dict) -> Union[str, NotHyperflare]:
    """The first served model id from an OpenAI /v1/models body."""
    models = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(models, list) or not models or not isinstance(models[0], dict):
        return NotHyperflare("no served model in /v1/models")
    model = models[0].get("id")
    if not isinstance(model, str) or not model.strip():
        return NotHyperflare("no served model in /v1/models")
    return " ".join(model.split())


def escape_label(value: str) -> str:
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def format_value(value: float) -> str:
    if float(value).is_integer():
        return str(int(value))
    return repr(float(value))


def render(model: str, counters: FlareCounters) -> str:
    """Render one Prometheus exposition; every series carries model_name."""
    labels = f'model_name="{escape_label(model)}"'
    c = counters
    cached = c.gpu_reused + c.host_reused
    used_pages = max(c.total_pages - c.free_pages, 0.0)
    usage = used_pages / c.total_pages if c.total_pages > 0 else 0.0

    rows = [
        ("hyperflare:prompt_tokens_total", "counter",
         "Prompt tokens prefilled or served from a prefix cache", c.prefilled + cached),
        ("hyperflare:prompt_tokens_prefilled_total", "counter",
         "Prompt tokens the GPUs computed (excludes prefix reuse)", c.prefilled),
        ("hyperflare:prompt_tokens_cached_total", "counter",
         "Prompt tokens served from the GPU checkpoint cache or the host prefix store", cached),
        ("hyperflare:generation_tokens_total", "counter", "Committed generated tokens", c.generated),
        ("hyperflare:requests_total", "counter", "Requests completed successfully", c.completed),
        ("hyperflare:requests_failed_total", "counter", "Requests failed", c.failed),
        ("hyperflare:requests_cancelled_total", "counter", "Requests cancelled before completion", c.cancelled),
        ("hyperflare:requests_running", "gauge", "Model slots with a live request", c.active),
        ("hyperflare:requests_waiting", "gauge", "Requests waiting in the model scheduler", c.pending),
        ("hyperflare:kv_pages_used", "gauge", "KV pages not reusable (per-rank pool)", used_pages),
        ("hyperflare:kv_pages", "gauge", "KV pages in the per-rank pool", c.total_pages),
        ("hyperflare:kv_cache_usage_ratio", "gauge", "Share of KV pages in use (0..1)", usage),
        ("hyperflare:spec_accepted_tokens_total", "counter",
         "MTP draft tokens accepted, excluding the bonus token", c.accepted_drafts),
        ("hyperflare:spec_draft_tokens_total", "counter",
         "MTP draft positions allocated for verification, including rejected drafts", c.draft_tokens),
        ("hyperflare:spec_draft_rounds_total", "counter",
         "Request rounds that offered at least one draft", c.draft_rounds),
        ("hyperflare:spec_verify_rounds_total", "counter",
         "Progressing decode or verification request rounds", c.verify_rounds),
    ]
    if c.first_response_median is not None:
        rows.append(("hyperflare:first_response_median_seconds", "gauge",
                     "Server-side admission to first answer or reasoning text, rolling-window median",
                     c.first_response_median))

    lines = [
        "# HELP hyperflare:model_info The served model behind the bridge",
        "# TYPE hyperflare:model_info gauge",
        f"hyperflare:model_info{{{labels}}} 1",
    ]
    for name, kind, help_, number in rows:
        lines.append(f"# HELP {name} {help_}")
        lines.append(f"# TYPE {name} {kind}")
        lines.append(f"{name}{{{labels}}} {format_value(number)}")
    return "\n".join(lines) + "\n"


# --- imperative shell ------------------------------------------------------

class Source:
    """The engine on :8000. Read-only: two GETs per scrape."""

    def __init__(self, base: str, key_file: Path):
        self.base = base.rstrip("/")
        self.key_file = key_file

    def _get(self, path: str, authenticated: bool) -> str:
        headers = {}
        if authenticated:
            headers["Authorization"] = f"Bearer {self.key_file.read_text().strip()}"
        request = urllib.request.Request(self.base + path, headers=headers)
        with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return response.read().decode("utf-8")

    def scrape(self) -> tuple[int, str]:
        try:
            counters = parse_flare(self._get("/metrics", authenticated=False))
            if isinstance(counters, NotHyperflare):
                return 503, f"# hyperflare bridge: {counters.reason}\n"
            model = served_model(json.loads(self._get("/v1/models", authenticated=True)))
            if isinstance(model, NotHyperflare):
                return 503, f"# hyperflare bridge: {model.reason}\n"
            return 200, render(model, counters)
        except (OSError, ValueError) as error:
            return 503, f"# hyperflare bridge: {type(error).__name__}: {error}\n"


class Handler(BaseHTTPRequestHandler):
    source: Source
    last_status = None

    def do_GET(self):  # noqa: N802 (http.server's spelling)
        if self.path.split("?", 1)[0] != "/metrics":
            self.send_response(404)
            self.end_headers()
            return
        status, body = self.source.scrape()
        if status != Handler.last_status:
            # Log transitions only (engine appeared / went away), not every scrape.
            sys.stderr.write(f"hyperflare-metrics: {status} {body.strip()[:200] if status != 200 else 'ok'}\n")
            Handler.last_status = status
        payload = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; version=0.0.4; charset=utf-8")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, fmt, *args):
        if self.command == "GET" and self.path.split("?", 1)[0] == "/metrics":
            return
        sys.stderr.write("hyperflare-metrics: " + fmt % args + "\n")


def parse_listen(raw: str) -> tuple[str, int]:
    host, _, port = raw.rpartition(":")
    return (host or "0.0.0.0"), int(port)


def main() -> int:
    source = os.environ.get("HYPERFLARE_SOURCE", DEFAULT_SOURCE)
    listen = os.environ.get("HYPERFLARE_LISTEN", DEFAULT_LISTEN)
    key_file = Path(os.environ.get("HYPERFLARE_KEY_FILE", DEFAULT_KEY_FILE)).expanduser()
    if not key_file.is_file():
        sys.stderr.write(f"hyperflare-metrics: API key file missing: {key_file}\n")
        return 2
    Handler.source = Source(source, key_file)
    host, port = parse_listen(listen)
    server = ThreadingHTTPServer((host, port), Handler)
    sys.stderr.write(f"hyperflare-metrics: {source} -> {host}:{port} (on demand)\n")
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
