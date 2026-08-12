#!/usr/bin/env python3
"""Append-only ledger of vLLM token usage on this box.

Why this exists:
  * vLLM's /metrics counters reset to zero with every container restart.
  * The homelab's Prometheus only keeps 30d of history and dies on cluster
    wipes (k3s uninstall/reinstall).

So a "lifetime" stat can only live somewhere else: every 15 minutes this
recorder scrapes the counters, computes the delta since the previous run
(handling counter resets from container restarts), and appends one row to a
plain CSV on this machine's disk. The file accumulates forever and survives
everything short of the disk itself.

Rows are per-interval deltas, so summing a column gives total usage.
If vLLM is only reachable briefly (box off), the interval is skipped — no
row is written, and the next run picks up the whole gap's delta.

Multiple models: point it at every vLLM /metrics endpoint (whitespace-
separated). Baselines are tracked per endpoint, so a restart of one model's
container never disturbs another's accounting. On the very first ledger run
the existing counters are backfilled as one "(pre-ledger history)" row, so
lifetime totals align with what vLLM itself reports.

Environment:
  VLLM_METRICS_URLS  whitespace-separated list of /metrics URLs
                     (default: http://127.0.0.1:8000/metrics)
  VLLM_METRICS_URL   single-URL override, kept for backwards compatibility
  VLLM_STATS_DIR     default /var/lib/vllm-stats
"""
import csv
import json
import os
import sys
import time
import urllib.request

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_URL = "http://127.0.0.1:8000/metrics"
URL_OLD = os.environ.get("VLLM_METRICS_URL")
if URL_OLD:
    URLS = [URL_OLD]
else:
    URLS = [u for u in os.environ.get("VLLM_METRICS_URLS", DEFAULT_URL).split() if u]
STATE = os.path.join(DIR, "state")
CSVFILE = os.path.join(DIR, "stats.csv")

# metric name -> ledger column
COUNTERS = {
    "prompt": "vllm:prompt_tokens_total",
    "gen": "vllm:generation_tokens_total",
    "req": "vllm:request_success_total",
}


def scrape(url):
    with urllib.request.urlopen(url, timeout=10) as resp:
        text = resp.read().decode("utf-8")
    out = {}
    found = False
    for line in text.splitlines():
        for key, name in COUNTERS.items():
            if line.startswith(name + "{"):
                # "vllm:prompt_tokens_total{...} 6.37538699e+08"
                out[key] = out.get(key, 0.0) + float(line.rsplit(" ", 1)[1])
                found = True
    if not found:
        for key in COUNTERS:
            out[key] = 0.0
    return out


def load_state():
    """{url: {metric: value}}. Migrates the pre-2026-08-12 flat format."""
    if not os.path.exists(STATE):
        return {}
    with open(STATE) as f:
        text = f.read()
    try:
        data = json.loads(text)
        if isinstance(data, dict) and data:
            return data
    except ValueError:
        pass
    # old format: "prompt 6.37538699e+08" lines (single endpoint)
    last = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            last.setdefault(DEFAULT_URL, {})[parts[0]] = float(parts[1])
    return last


def save_state(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(state, f, indent=1)
    os.replace(tmp, STATE)


def main():
    deltas = {k: 0.0 for k in COUNTERS}
    cur_per_url = {}
    for url in URLS:
        try:
            cur = scrape(url)
        except Exception as exc:  # connection refused, timeout, ...
            print(f"{url} unreachable ({exc}); skipping this interval")
            continue
        if not any(cur.values()):
            print(f"{url}: no vLLM counters present; skipping")
            continue
        cur_per_url[url] = cur

    if not cur_per_url:
        print("no reachable vLLM endpoints; skipping this interval")
        return 0

    os.makedirs(DIR, exist_ok=True)
    last = load_state()
    first_run = not last

    new_state = {}
    for url, cur in cur_per_url.items():
        new_state[url] = dict(cur)
        prev = last.get(url)
        if prev is None:
            continue  # new endpoint: seed its baseline, count from next run
        for key in COUNTERS:
            c = cur[key]
            l = prev[key] if key in prev else 0.0
            if c >= l:
                deltas[key] += c - l
            else:
                # Counter went backwards: that container restarted mid-interval.
                # The tail of the old process is lost; count only what the new
                # one has produced so far.
                print(f"note: {url}: {key} counter reset (restart), counting from 0")
                deltas[key] += c

    save_state(new_state)

    now = int(time.time())
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))

    if first_run:
        # The ledger is born mid-stream: the endpoints' counters already hold
        # the whole history of the current container processes. Record it as
        # one backfilled row so lifetime totals align with what vLLM reports
        # (and thus with Grafana) from day one.
        total = {k: 0.0 for k in COUNTERS}
        for cur in cur_per_url.values():
            for k in COUNTERS:
                total[k] += cur[k]
        if not os.path.exists(CSVFILE):
            with open(CSVFILE, "a", newline="") as f:
                writer = csv.writer(f)
                writer.writerow(["ts", "when", "prompt_tokens", "generation_tokens", "requests"])
                writer.writerow([now, when + " (pre-ledger history)",
                                 f"{total['prompt']:.0f}", f"{total['gen']:.0f}",
                                 f"{total['req']:.0f}"])
            print(f"first run: seeded baseline + backfilled pre-ledger history "
                  f"(gen={total['gen']:.0f} prompt={total['prompt']:.0f} req={total['req']:.0f})")
        else:
            print("first run: seeded baselines, existing ledger left untouched")
        return 0

    header = not os.path.exists(CSVFILE)
    with open(CSVFILE, "a", newline="") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(["ts", "when", "prompt_tokens", "generation_tokens", "requests"])
        writer.writerow([now, when,
                         f"{deltas['prompt']:.0f}", f"{deltas['gen']:.0f}", f"{deltas['req']:.0f}"])
    print(f"recorded: {when} prompt={deltas['prompt']:.0f} gen={deltas['gen']:.0f} "
          f"req={deltas['req']:.0f} (endpoints: {len(cur_per_url)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
