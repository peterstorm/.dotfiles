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

Environment:
  VLLM_METRICS_URL   default http://127.0.0.1:8000/metrics
  VLLM_STATS_DIR     default /var/lib/vllm-stats
"""
import csv
import os
import sys
import time
import urllib.request

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
URL = os.environ.get("VLLM_METRICS_URL", "http://127.0.0.1:8000/metrics")
STATE = os.path.join(DIR, "state")
CSVFILE = os.path.join(DIR, "stats.csv")

# metric name -> ledger column
COUNTERS = {
    "prompt": "vllm:prompt_tokens_total",
    "gen": "vllm:generation_tokens_total",
    "req": "vllm:request_success_total",
}


def scrape():
    with urllib.request.urlopen(URL, timeout=10) as resp:
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
    last = {}
    if os.path.exists(STATE):
        with open(STATE) as f:
            for line in f:
                parts = line.split()
                if len(parts) == 2:
                    last[parts[0]] = float(parts[1])
    return last


def save_state(cur):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as f:
        for key in COUNTERS:
            f.write(f"{key} {cur[key]:.6e}\n")
    os.replace(tmp, STATE)


def main():
    try:
        cur = scrape()
    except Exception as exc:  # connection refused, timeout, ...
        print(f"metrics unreachable ({exc}); skipping this interval")
        return 0
    if not any(cur.values()):
        print("no vLLM counters present; skipping this interval")
        return 0

    os.makedirs(DIR, exist_ok=True)
    last = load_state()
    first_run = not last

    now = int(time.time())
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    row = {"ts": now, "when": when}
    for key in COUNTERS:
        c = cur[key]
        if key in last:
            if c >= last[key]:
                delta = c - last[key]
            else:
                # Counter went backwards: the container restarted mid-interval.
                # The tail of the old process is lost; count only what the new
                # process has produced so far.
                print(f"note: {key} counter reset (restart), counting from 0")
                delta = c
        else:
            delta = 0.0
        row[key] = delta

    save_state(cur)

    if first_run:
        print("first run: seeded baseline, no row appended")
        return 0

    header = not os.path.exists(CSVFILE)
    with open(CSVFILE, "a", newline="") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(["ts", "when", "prompt_tokens", "generation_tokens", "requests"])
        writer.writerow([row["ts"], row["when"],
                         f"{row['prompt']:.0f}", f"{row['gen']:.0f}", f"{row['req']:.0f}"])
    print(f"recorded: {when} prompt={row['prompt']:.0f} gen={row['gen']:.0f} req={row['req']:.0f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
