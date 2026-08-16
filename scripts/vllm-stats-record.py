#!/usr/bin/env python3
"""Append-only ledger of local inference token usage on this box.

Why this exists:
  * Inference-engine /metrics counters reset to zero with every container restart.
  * The homelab's Prometheus only keeps 30d of history and dies on cluster
    wipes (k3s uninstall/reinstall).

So a "lifetime" stat can only live somewhere else: every 15 minutes this
recorder identifies the metrics schema (currently vLLM or SGLang), computes
the delta since the previous run, and appends one row to a plain CSV on this
machine's disk. Engine switches and counter resets count the new process from
zero. The file accumulates forever and survives everything short of the disk.

Rows are per-interval deltas, so summing a column gives total usage. If the
endpoint is only reachable briefly (box off), the interval is skipped and the
next run picks up the whole gap's delta.

Multiple models: point it at every /metrics endpoint (whitespace-separated).
Baselines are tracked per endpoint and include the detected engine, so a restart
or runtime switch never compares unrelated counter namespaces. On the very first
ledger run the existing counters are backfilled as one "(pre-ledger history)"
row.

The VLLM_* environment names remain for backwards compatibility; they now accept
any supported local inference endpoint.

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
PENDING = os.path.join(DIR, "pending-interval.json")

COUNTER_KEYS = ("prompt", "gen", "req")

# Engine name -> ledger column -> Prometheus counter. This is the compatibility
# boundary: adding another runtime requires one schema entry, not changes to the
# durable CSV or heatmap.
COUNTER_SCHEMAS = {
    "vllm": {
        "prompt": "vllm:prompt_tokens_total",
        "gen": "vllm:generation_tokens_total",
        "req": "vllm:request_success_total",
    },
    "sglang": {
        "prompt": "sglang:prompt_tokens_total",
        "gen": "sglang:generation_tokens_total",
        # One observation per completed generation, independent of HTTP probes.
        "req": "sglang:generation_tokens_histogram_count",
    },
}


def parse_counters(text):
    """Return (engine, logical counters), or None for an unknown metric schema."""
    samples = {}
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) < 2:
            continue
        name = fields[0].split("{", 1)[0]
        try:
            value = float(fields[-1])
        except ValueError:
            continue
        samples[name] = samples.get(name, 0.0) + value

    matches = []
    for engine, schema in COUNTER_SCHEMAS.items():
        if all(metric in samples for metric in schema.values()):
            matches.append((engine, {key: samples[metric] for key, metric in schema.items()}))
    if len(matches) > 1:
        engines = ", ".join(engine for engine, _ in matches)
        raise ValueError(f"ambiguous inference metric schemas: {engines}")
    return matches[0] if matches else None


def scrape(url):
    with urllib.request.urlopen(url, timeout=10) as resp:
        return parse_counters(resp.read().decode("utf-8"))


def state_entry(engine, counters):
    return {"engine": engine, "counters": {key: counters[key] for key in COUNTER_KEYS}}


def merge_endpoint_states(previous, current):
    """Replace successful endpoint snapshots without dropping absent baselines."""
    return {**previous, **current}


def counter_deltas(previous, current):
    """Return (deltas, reset keys, engine changed) for two parsed state entries."""
    zero = {key: 0.0 for key in COUNTER_KEYS}
    if previous is None:
        return zero, [], False
    if previous["engine"] != current["engine"]:
        return dict(current["counters"]), [], True

    deltas = {}
    resets = []
    for key in COUNTER_KEYS:
        value = current["counters"][key]
        old = previous["counters"].get(key, 0.0)
        if value >= old:
            deltas[key] = value - old
        else:
            deltas[key] = value
            resets.append(key)
    return deltas, resets, False


def load_state():
    """Load state and migrate legacy vLLM-only JSON or flat formats."""
    if not os.path.exists(STATE):
        return {}
    with open(STATE) as f:
        text = f.read()
    try:
        data = json.loads(text)
        if isinstance(data, dict) and data:
            migrated = {}
            for url, entry in data.items():
                if not isinstance(entry, dict):
                    continue
                if isinstance(entry.get("counters"), dict) and isinstance(entry.get("engine"), str):
                    migrated[url] = state_entry(entry["engine"], entry["counters"])
                elif all(key in entry for key in COUNTER_KEYS):
                    migrated[url] = state_entry("vllm", entry)
            if migrated:
                return migrated
    except (KeyError, TypeError, ValueError):
        pass

    # Pre-2026-08-12 format: "prompt 6.37538699e+08" lines, one vLLM endpoint.
    counters = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in COUNTER_KEYS:
            counters[parts[0]] = float(parts[1])
    return {DEFAULT_URL: state_entry("vllm", counters)} if counters else {}


def atomic_json_write(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(value, f, indent=1)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def save_state(state):
    atomic_json_write(STATE, state)


def append_csv_row_once(row):
    """Append a logical interval exactly once, including crash recovery retries."""
    encoded = [str(value) for value in row]
    if os.path.exists(CSVFILE):
        with open(CSVFILE, newline="") as f:
            if any(existing == encoded for existing in csv.reader(f)):
                return
    header = not os.path.exists(CSVFILE) or os.path.getsize(CSVFILE) == 0
    with open(CSVFILE, "a", newline="") as f:
        writer = csv.writer(f)
        if header:
            writer.writerow(["ts", "when", "prompt_tokens", "generation_tokens", "requests"])
        writer.writerow(encoded)
        f.flush()
        os.fsync(f.fileno())


def finish_pending_interval(payload):
    row = payload.get("row")
    state = payload.get("state")
    if row is not None:
        append_csv_row_once(row)
    save_state(state)
    os.unlink(PENDING)


def commit_interval(state, row):
    """Durably commit CSV-before-state through an idempotent pending record."""
    payload = {"state": state, "row": row}
    atomic_json_write(PENDING, payload)
    finish_pending_interval(payload)


def recover_pending_interval():
    if not os.path.exists(PENDING):
        return False
    with open(PENDING) as f:
        payload = json.load(f)
    if not isinstance(payload, dict) or not isinstance(payload.get("state"), dict):
        raise ValueError(f"malformed pending interval: {PENDING}")
    row = payload.get("row")
    if row is not None and not isinstance(row, list):
        raise ValueError(f"malformed pending interval row: {PENDING}")
    finish_pending_interval(payload)
    print("recovered pending ledger interval")
    return True


def main():
    os.makedirs(DIR, exist_ok=True)
    recover_pending_interval()
    deltas = {key: 0.0 for key in COUNTER_KEYS}
    cur_per_url = {}
    for url in URLS:
        try:
            parsed = scrape(url)
        except Exception as exc:  # connection refused, timeout, malformed metrics, ...
            print(f"{url} unreachable or invalid ({exc}); skipping this interval")
            continue
        if parsed is None:
            print(f"{url}: no supported inference counters present; skipping")
            continue
        engine, counters = parsed
        if not any(counters.values()):
            print(f"{url}: {engine} counters are all zero; skipping")
            continue
        cur_per_url[url] = state_entry(engine, counters)

    if not cur_per_url:
        print("no reachable supported inference endpoints; skipping this interval")
        return 0

    last = load_state()
    first_run = not last

    # Preserve baselines for endpoints that are temporarily unreachable. A
    # successful sibling scrape must never make the missing endpoint look new.
    new_state = merge_endpoint_states(last, cur_per_url)
    for url, current in cur_per_url.items():
        delta, resets, engine_changed = counter_deltas(last.get(url), current)
        if engine_changed:
            old_engine = last[url]["engine"]
            print(f"note: {url}: engine changed {old_engine} -> {current['engine']}; counting new counters from 0")
        for key in resets:
            print(f"note: {url}: {key} counter reset (restart), counting from 0")
        for key in COUNTER_KEYS:
            deltas[key] += delta[key]

    now = int(time.time())
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))

    if first_run:
        # The ledger is born mid-stream: the endpoints' counters already hold
        # the whole history of the current container processes. Record it as
        # one backfilled row so lifetime totals align with the active engine.
        total = {key: 0.0 for key in COUNTER_KEYS}
        for current in cur_per_url.values():
            for key in COUNTER_KEYS:
                total[key] += current["counters"][key]
        if not os.path.exists(CSVFILE):
            row = [now, when + " (pre-ledger history)",
                   f"{total['prompt']:.0f}", f"{total['gen']:.0f}", f"{total['req']:.0f}"]
            commit_interval(new_state, row)
            print(f"first run: seeded baseline + backfilled pre-ledger history "
                  f"(gen={total['gen']:.0f} prompt={total['prompt']:.0f} req={total['req']:.0f})")
        else:
            commit_interval(new_state, None)
            print("first run: seeded baselines, existing ledger left untouched")
        return 0

    row = [now, when,
           f"{deltas['prompt']:.0f}", f"{deltas['gen']:.0f}", f"{deltas['req']:.0f}"]
    commit_interval(new_state, row)
    print(f"recorded: {when} prompt={deltas['prompt']:.0f} gen={deltas['gen']:.0f} "
          f"req={deltas['req']:.0f} (endpoints: {len(cur_per_url)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
