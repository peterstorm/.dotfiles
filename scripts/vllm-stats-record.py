#!/usr/bin/env python3
"""Record durable, model-aware inference token usage.

The active inference engine exposes process-local Prometheus counters that reset
on container restart. Every 15 minutes this recorder translates supported vLLM
or SGLang schemas into one durable row per endpoint/model. Historical five-column
rows are migrated atomically and retained as ``Historical aggregate`` because
model identity cannot be reconstructed after the fact.

The VLLM_* environment names remain for backwards compatibility.

Environment:
  VLLM_METRICS_URLS  whitespace-separated /metrics URLs
  VLLM_METRICS_URL   legacy single-URL override
  VLLM_STATS_DIR     default /var/lib/vllm-stats
  VLLM_STATS_LEGACY_ATTRIBUTIONS
                     JSON array of explicit timestamp ranges whose historical
                     rows have independently known model/engine identity
"""
import csv
import json
import os
import re
import sys
import time
import urllib.request

DIR = os.environ.get("VLLM_STATS_DIR", "/var/lib/vllm-stats")
DEFAULT_URL = "http://127.0.0.1:8000/metrics"
URL_OLD = os.environ.get("VLLM_METRICS_URL")
URLS = [URL_OLD] if URL_OLD else [
    url for url in os.environ.get("VLLM_METRICS_URLS", DEFAULT_URL).split() if url
]
STATE = os.path.join(DIR, "state")
CSVFILE = os.path.join(DIR, "stats.csv")
PENDING = os.path.join(DIR, "pending-interval.json")

COUNTER_KEYS = ("prompt", "gen", "req")
LEGACY_MODEL = "Historical aggregate"
UNKNOWN_MODEL = "Unknown model"
LEGACY_COLUMNS = ["ts", "when", "prompt_tokens", "generation_tokens", "requests"]
CSV_COLUMNS = [
    "ts",
    "when",
    "model",
    "engine",
    "endpoint",
    "prompt_tokens",
    "generation_tokens",
    "requests",
    "interval_seconds",
    "prompt_tokens_per_second",
    "generation_tokens_per_second",
]
LEGACY_ATTRIBUTIONS_RAW = os.environ.get("VLLM_STATS_LEGACY_ATTRIBUTIONS", "[]")

COUNTER_SCHEMAS = {
    "vllm": {
        "prompt": "vllm:prompt_tokens_total",
        "gen": "vllm:generation_tokens_total",
        "req": "vllm:request_success_total",
    },
    "sglang": {
        "prompt": "sglang:prompt_tokens_total",
        "gen": "sglang:generation_tokens_total",
        "req": "sglang:generation_tokens_histogram_count",
    },
}

LABEL_PATTERN = re.compile(r'([A-Za-z_][A-Za-z0-9_]*)="((?:\\.|[^"\\])*)"')


def unescape_label(value):
    """Decode the three escapes allowed by the Prometheus text format."""
    return re.sub(
        r"\\(.)",
        lambda match: {"n": "\n", "\\": "\\", '"': '"'}.get(match.group(1), match.group(1)),
        value,
    )


def split_sample(line):
    """Split one exposition line at the first whitespace outside label quotes."""
    quoted = escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
        elif char == "\\" and quoted:
            escaped = True
        elif char == '"':
            quoted = not quoted
        elif char.isspace() and not quoted:
            return line[:index], line[index:].split()[0]
    return None


def parse_sample(line):
    split = split_sample(line)
    if split is None:
        return None
    identity, raw_value = split
    try:
        value = float(raw_value)
    except ValueError:
        return None
    if "{" not in identity:
        return identity, {}, value
    if not identity.endswith("}"):
        return None
    name, raw_labels = identity.split("{", 1)
    labels = {
        match.group(1): unescape_label(match.group(2))
        for match in LABEL_PATTERN.finditer(raw_labels[:-1])
    }
    return name, labels, value


def parse_counters(text):
    """Return ``(engine, counters_by_model)`` for one supported metric schema."""
    samples = []
    names = set()
    for line in text.splitlines():
        if not line or line.startswith("#"):
            continue
        sample = parse_sample(line)
        if sample is not None:
            samples.append(sample)
            names.add(sample[0])

    matches = []
    for engine, schema in COUNTER_SCHEMAS.items():
        if not all(metric in names for metric in schema.values()):
            continue
        by_model = {}
        metric_to_key = {metric: key for key, metric in schema.items()}
        for name, labels, value in samples:
            key = metric_to_key.get(name)
            if key is None:
                continue
            raw_model = labels.get("model_name") or UNKNOWN_MODEL
            model = " ".join(raw_model.splitlines()).strip() or UNKNOWN_MODEL
            counters = by_model.setdefault(model, {counter_key: 0.0 for counter_key in COUNTER_KEYS})
            counters[key] += value
        matches.append((engine, by_model))

    if len(matches) > 1:
        engines = ", ".join(engine for engine, _ in matches)
        raise ValueError(f"ambiguous inference metric schemas: {engines}")
    return matches[0] if matches else None


def scrape(url):
    with urllib.request.urlopen(url, timeout=10) as response:
        return parse_counters(response.read().decode("utf-8"))


def clean_counters(counters):
    return {key: float(counters.get(key, 0.0)) for key in COUNTER_KEYS}


def state_entry(engine, models, observed_at=None, model_observed_at=None):
    clean_models = {model: clean_counters(counters) for model, counters in models.items()}
    observed_by_model = model_observed_at or {model: observed_at for model in clean_models}
    return {
        "engine": engine,
        "observed_at": observed_at,
        "models": clean_models,
        "model_observed_at": {
            model: observed_by_model.get(model)
            for model in clean_models
        },
    }


def migrate_state_entry(entry):
    if not isinstance(entry, dict):
        return None
    # Earliest JSON state was a flat vLLM counter map under each URL.
    if all(key in entry for key in COUNTER_KEYS) and "engine" not in entry:
        return state_entry("vllm", {LEGACY_MODEL: entry})
    if not isinstance(entry.get("engine"), str):
        return None
    observed_at = entry.get("observed_at")
    if observed_at is not None:
        try:
            observed_at = int(observed_at)
        except (TypeError, ValueError):
            observed_at = None
    if isinstance(entry.get("models"), dict):
        models = {
            str(model): clean_counters(counters)
            for model, counters in entry["models"].items()
            if isinstance(counters, dict)
        }
        raw_model_times = entry.get("model_observed_at", {})
        model_times = {}
        for model in models:
            value = raw_model_times.get(model, observed_at) if isinstance(raw_model_times, dict) else observed_at
            try:
                model_times[model] = int(value) if value is not None else None
            except (TypeError, ValueError):
                model_times[model] = observed_at
        return state_entry(entry["engine"], models, observed_at, model_times) if models else None
    if isinstance(entry.get("counters"), dict):
        return state_entry(entry["engine"], {LEGACY_MODEL: entry["counters"]}, observed_at)
    return None


def load_state():
    """Load current state and migrate all previous state representations."""
    if not os.path.exists(STATE):
        return {}
    with open(STATE) as stream:
        text = stream.read()
    try:
        data = json.loads(text)
        if isinstance(data, dict):
            migrated = {
                url: migrated_entry
                for url, entry in data.items()
                if (migrated_entry := migrate_state_entry(entry)) is not None
            }
            if migrated:
                return migrated
    except (TypeError, ValueError):
        pass

    counters = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in COUNTER_KEYS:
            counters[parts[0]] = float(parts[1])
    return {
        DEFAULT_URL: state_entry("vllm", {LEGACY_MODEL: counters})
    } if counters else {}


def merge_endpoint_states(previous, current):
    """Merge successful scrapes while retaining temporarily absent model baselines."""
    merged = dict(previous)
    for url, current_entry in current.items():
        old_entry = previous.get(url)
        if old_entry is None or old_entry["engine"] != current_entry["engine"]:
            merged[url] = current_entry
            continue
        if set(old_entry["models"]) == {LEGACY_MODEL}:
            models = dict(current_entry["models"])
            model_times = dict(current_entry.get("model_observed_at", {}))
        else:
            models = {**old_entry["models"], **current_entry["models"]}
            model_times = {
                **old_entry.get("model_observed_at", {}),
                **current_entry.get("model_observed_at", {}),
            }
        merged[url] = state_entry(
            current_entry["engine"],
            models,
            current_entry.get("observed_at"),
            model_times,
        )
    return merged


def align_legacy_baseline(previous, current):
    """Assign one aggregate baseline to the sole current model when unambiguous."""
    if previous is None or previous["engine"] != current["engine"]:
        return previous
    if set(previous["models"]) == {LEGACY_MODEL} and len(current["models"]) == 1:
        model = next(iter(current["models"]))
        legacy_time = previous.get("model_observed_at", {}).get(
            LEGACY_MODEL, previous.get("observed_at")
        )
        return state_entry(
            previous["engine"],
            {model: previous["models"][LEGACY_MODEL]},
            previous.get("observed_at"),
            {model: legacy_time},
        )
    return previous


def counter_deltas(previous, current):
    """Return per-model deltas, reset labels, and whether the engine changed."""
    previous = align_legacy_baseline(previous, current)
    engine_changed = previous is not None and previous["engine"] != current["engine"]
    previous_models = {} if previous is None or engine_changed else previous["models"]
    # An aggregate baseline cannot be apportioned across multiple live models.
    # Preserve the knowable aggregate transition delta under the historical
    # bucket while the new state seeds exact per-model baselines.
    if set(previous_models) == {LEGACY_MODEL} and len(current["models"]) > 1:
        aggregate = {
            key: sum(counters[key] for counters in current["models"].values())
            for key in COUNTER_KEYS
        }
        old = previous_models[LEGACY_MODEL]
        transition = {}
        resets = []
        for key in COUNTER_KEYS:
            if aggregate[key] >= old[key]:
                transition[key] = aggregate[key] - old[key]
            else:
                transition[key] = aggregate[key]
                resets.append((LEGACY_MODEL, key))
        return {LEGACY_MODEL: transition}, resets, False
    deltas = {}
    resets = []
    for model, counters in current["models"].items():
        old = previous_models.get(model, {})
        model_deltas = {}
        for key in COUNTER_KEYS:
            value = counters[key]
            old_value = float(old.get(key, 0.0))
            if value >= old_value:
                model_deltas[key] = value - old_value
            else:
                model_deltas[key] = value
                resets.append((model, key))
        deltas[model] = model_deltas
    return deltas, resets, engine_changed


def fsync_parent(path):
    directory = os.path.dirname(path) or "."
    descriptor = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_json_write(path, value):
    tmp = path + ".tmp"
    with open(tmp, "w") as stream:
        json.dump(value, stream, indent=1)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
    fsync_parent(path)


def save_state(state):
    atomic_json_write(STATE, state)


def parse_legacy_attributions(raw):
    """Parse explicit, non-overlapping attribution ranges from deployment config."""
    try:
        values = json.loads(raw)
    except (TypeError, ValueError) as error:
        raise ValueError("VLLM_STATS_LEGACY_ATTRIBUTIONS must be valid JSON") from error
    if not isinstance(values, list):
        raise ValueError("VLLM_STATS_LEGACY_ATTRIBUTIONS must be a JSON array")

    parsed = []
    required = {"from_ts", "through_ts", "model", "engine", "endpoint"}
    for index, value in enumerate(values):
        if not isinstance(value, dict) or set(value) != required:
            raise ValueError(
                f"legacy attribution {index} must contain exactly {sorted(required)!r}"
            )
        if type(value["from_ts"]) is not int or type(value["through_ts"]) is not int:
            raise ValueError(f"legacy attribution {index} timestamps must be integers")
        from_ts = value["from_ts"]
        through_ts = value["through_ts"]
        if from_ts < 0 or through_ts < from_ts:
            raise ValueError(f"legacy attribution {index} has an invalid timestamp range")
        identity = {}
        for key in ("model", "engine", "endpoint"):
            field = value[key]
            if not isinstance(field, str) or not field.strip():
                raise ValueError(f"legacy attribution {index} {key} must be non-empty text")
            identity[key] = field.strip()
        if identity["model"] == LEGACY_MODEL:
            raise ValueError(f"legacy attribution {index} must name a concrete model")
        parsed.append({"from_ts": from_ts, "through_ts": through_ts, **identity})

    parsed.sort(key=lambda attribution: attribution["from_ts"])
    for previous, current in zip(parsed, parsed[1:]):
        if current["from_ts"] <= previous["through_ts"]:
            raise ValueError("legacy attribution timestamp ranges must not overlap")
    return tuple(parsed)


def attribution_for_timestamp(raw_timestamp, attributions):
    try:
        timestamp = int(raw_timestamp)
    except (TypeError, ValueError):
        return None
    return next(
        (
            attribution
            for attribution in attributions
            if attribution["from_ts"] <= timestamp <= attribution["through_ts"]
        ),
        None,
    )


def legacy_row_to_current(row):
    if len(row) != len(LEGACY_COLUMNS):
        raise ValueError(f"malformed legacy ledger row: {row!r}")
    return [
        row[0], row[1], LEGACY_MODEL, "legacy", "legacy",
        row[2], row[3], row[4], "", "", "",
    ]


def atomic_csv_write(path, rows, suffix):
    tmp = path + suffix
    with open(tmp, "w", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(CSV_COLUMNS)
        writer.writerows(rows)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(tmp, path)
    fsync_parent(path)


def migrate_csv_schema(path=None):
    """Atomically migrate the old aggregate ledger without changing totals."""
    path = path or CSVFILE
    if not os.path.exists(path) or os.path.getsize(path) == 0:
        return False
    with open(path, newline="") as stream:
        reader = csv.reader(stream)
        header = next(reader, None)
        if header == CSV_COLUMNS:
            return False
        if header != LEGACY_COLUMNS:
            raise ValueError(f"unsupported ledger header: {header!r}")
        legacy_rows = [row for row in reader if row]

    atomic_csv_write(
        path,
        (legacy_row_to_current(row) for row in legacy_rows),
        ".schema-v2.tmp",
    )
    return True


def migrate_legacy_attributions(path=None, attributions=None):
    """Reclassify only explicitly bounded legacy rows, preserving every total."""
    path = path or CSVFILE
    attributions = parse_legacy_attributions(LEGACY_ATTRIBUTIONS_RAW) if attributions is None else attributions
    if not attributions or not os.path.exists(path) or os.path.getsize(path) == 0:
        return 0
    with open(path, newline="") as stream:
        reader = csv.DictReader(stream)
        if reader.fieldnames != CSV_COLUMNS:
            raise ValueError(f"unsupported ledger header: {reader.fieldnames!r}")
        rows = list(reader)

    changed = 0
    for row in rows:
        if not (
            row.get("model") == LEGACY_MODEL
            and row.get("engine") == "legacy"
            and row.get("endpoint") == "legacy"
        ):
            continue
        attribution = attribution_for_timestamp(row.get("ts"), attributions)
        if attribution is None:
            continue
        row["model"] = attribution["model"]
        row["engine"] = attribution["engine"]
        row["endpoint"] = attribution["endpoint"]
        changed += 1

    if changed:
        atomic_csv_write(
            path,
            ([row.get(column, "") for column in CSV_COLUMNS] for row in rows),
            ".attribution-v1.tmp",
        )
    return changed


def normalize_rows(rows):
    if rows is None:
        return []
    if rows and not isinstance(rows[0], list):
        rows = [rows]
    return [legacy_row_to_current(row) if len(row) == 5 else row for row in rows]


def tail_csv_rows(path, count):
    """Read a bounded number of physical CSV rows from an append-only ledger."""
    if count <= 0 or not os.path.exists(path) or os.path.getsize(path) == 0:
        return []
    with open(path, "rb") as stream:
        end = stream.seek(0, os.SEEK_END)
        position = end
        data = b""
        while position > 0 and data.count(b"\n") <= count:
            size = min(4096, position)
            position -= size
            stream.seek(position)
            data = stream.read(size) + data
    lines = data.splitlines()
    if position > 0 and lines:
        lines = lines[1:]
    parsed = []
    for line in lines[-count:]:
        try:
            parsed.extend(csv.reader([line.decode("utf-8")]))
        except (UnicodeDecodeError, csv.Error):
            continue
    return parsed


def append_csv_rows_once(rows):
    """Append every logical row exactly once, inspecting only the recovery tail."""
    rows = normalize_rows(rows)
    if not rows:
        return
    encoded = [[str(value) for value in row] for row in rows]
    existing = {tuple(row) for row in tail_csv_rows(CSVFILE, len(encoded) + 1)}
    header = not os.path.exists(CSVFILE) or os.path.getsize(CSVFILE) == 0
    with open(CSVFILE, "a", newline="") as stream:
        writer = csv.writer(stream)
        if header:
            writer.writerow(CSV_COLUMNS)
        for row in encoded:
            if tuple(row) not in existing:
                writer.writerow(row)
        stream.flush()
        os.fsync(stream.fileno())


def finish_pending_interval(payload):
    rows = payload.get("rows", payload.get("row"))
    append_csv_rows_once(rows)
    save_state(payload["state"])
    os.unlink(PENDING)


def commit_interval(state, rows):
    """Durably commit all model rows before advancing counter baselines."""
    payload = {"state": state, "rows": normalize_rows(rows)}
    atomic_json_write(PENDING, payload)
    finish_pending_interval(payload)


def recover_pending_interval():
    if not os.path.exists(PENDING):
        return False
    with open(PENDING) as stream:
        payload = json.load(stream)
    if not isinstance(payload, dict) or not isinstance(payload.get("state"), dict):
        raise ValueError(f"malformed pending interval: {PENDING}")
    rows = payload.get("rows", payload.get("row"))
    if rows is not None and not isinstance(rows, list):
        raise ValueError(f"malformed pending interval rows: {PENDING}")
    finish_pending_interval(payload)
    print("recovered pending ledger interval")
    return True


def latest_ledger_timestamp():
    for row in reversed(tail_csv_rows(CSVFILE, 16)):
        try:
            return int(row[0])
        except (IndexError, TypeError, ValueError):
            continue
    return None


def format_count(value):
    return f"{value:.0f}"


def format_rate(value, elapsed):
    return "" if elapsed is None else f"{value / elapsed:.6f}"


def model_elapsed(previous, current, model, now, fallback_timestamp=None):
    if previous is None:
        observed_at = fallback_timestamp
    elif previous["engine"] != current["engine"]:
        observed_at = previous.get("observed_at") or fallback_timestamp
    else:
        aligned = align_legacy_baseline(previous, current)
        observed_at = aligned.get("model_observed_at", {}).get(model)
        if observed_at is None:
            observed_at = aligned.get("observed_at") or fallback_timestamp
    return max(1, now - observed_at) if observed_at is not None else None


def interval_rows(now, when, url, current, deltas, elapsed):
    rows = []
    for model, values in sorted(deltas.items()):
        model_interval = elapsed.get(model) if isinstance(elapsed, dict) else elapsed
        rows.append(
            [
                now,
                when,
                model,
                current["engine"],
                url,
                format_count(values["prompt"]),
                format_count(values["gen"]),
                format_count(values["req"]),
                "" if model_interval is None else model_interval,
                format_rate(values["prompt"], model_interval),
                format_rate(values["gen"], model_interval),
            ]
        )
    return rows


def main():
    os.makedirs(DIR, exist_ok=True)
    attributions = parse_legacy_attributions(LEGACY_ATTRIBUTIONS_RAW)
    if migrate_csv_schema():
        print(f"migrated ledger to model-aware schema; unknown rows labelled {LEGACY_MODEL!r}")
    # Recover before attribution repair so a crash-left pending row and its
    # already-appended CSV twin still have identical identities for de-duplication.
    recover_pending_interval()
    attributed = migrate_legacy_attributions(attributions=attributions)
    if attributed:
        print(f"attributed {attributed} historical ledger row(s) from explicit timestamp ranges")

    now = int(time.time())
    cur_per_url = {}
    for url in URLS:
        try:
            parsed = scrape(url)
        except Exception as error:
            print(f"{url} unreachable or invalid ({error}); skipping this interval")
            continue
        if parsed is None:
            print(f"{url}: no supported inference counters present; skipping")
            continue
        engine, models = parsed
        if not models or not any(any(counters.values()) for counters in models.values()):
            print(f"{url}: {engine} counters are all zero; skipping")
            continue
        cur_per_url[url] = state_entry(engine, models, now)

    if not cur_per_url:
        print("no reachable supported inference endpoints; skipping this interval")
        return 0

    previous_state = load_state()
    first_run = not previous_state
    new_state = merge_endpoint_states(previous_state, cur_per_url)
    when = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now))
    latest_timestamp = latest_ledger_timestamp()
    rows = []

    for url, current in cur_per_url.items():
        previous = previous_state.get(url)
        deltas, resets, engine_changed = counter_deltas(previous, current)
        if engine_changed:
            print(f"note: {url}: engine changed {previous['engine']} -> {current['engine']}; counting current counters")
        for model, key in resets:
            print(f"note: {url}: {model}: {key} counter reset; counting from zero")
        elapsed = {
            model: model_elapsed(previous, current, model, now, latest_timestamp)
            for model in deltas
        }
        rows.extend(interval_rows(now, when, url, current, deltas, elapsed))

    if first_run:
        if not os.path.exists(CSVFILE):
            rows = []
            for url, current in cur_per_url.items():
                rows.extend(interval_rows(
                    now,
                    when + " (pre-ledger history)",
                    url,
                    current,
                    current["models"],
                    None,
                ))
            commit_interval(new_state, rows)
            print(f"first run: seeded baseline and backfilled {len(rows)} model row(s)")
        else:
            commit_interval(new_state, [])
            print("first run: seeded model baselines; existing ledger left untouched")
        return 0

    commit_interval(new_state, rows)
    prompt = sum(float(row[5]) for row in rows)
    generation = sum(float(row[6]) for row in rows)
    requests = sum(float(row[7]) for row in rows)
    print(
        f"recorded: {when} prompt={prompt:.0f} gen={generation:.0f} req={requests:.0f} "
        f"models={len(rows)} endpoints={len(cur_per_url)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
