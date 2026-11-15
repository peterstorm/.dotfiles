#!/usr/bin/env python3
"""Unit tests for the Hyperflare throughput probe.

Run directly (`python3 tests/hyperflare-throughput-probe-unit.py`). The pure core
(SSE parsing, per-request and per-round statistics, MTP acceptance from the
bridge's counters) is tested on plain values; the shell is driven end to end
against a fake endpoint and a fake bridge on real sockets. No GPU, no engine.
"""
import contextlib
import http.server
import importlib.util
import io
import json
import pathlib
import sys
import tempfile
import threading

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts" / "inference" / "shared" / "probe-hyperflare-throughput.py"
spec = importlib.util.spec_from_file_location("hyperflare_probe", MODULE)
probe = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = probe  # dataclasses resolves string annotations through sys.modules
spec.loader.exec_module(probe)

failures = 0


def check(name, condition):
    global failures
    if condition:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}", file=sys.stderr)


def close(a, b, tolerance=1e-6):
    return a is not None and abs(a - b) <= tolerance


# --------------------------------------------------------------- SSE parsing

delta = 'data: {"id":"c","object":"chat.completion.chunk","choices":[{"index":0,"delta":{"content":"1"},"finish_reason":null}],"usage":null}'
reasoning = 'data: {"choices":[{"index":0,"delta":{"reasoning_content":"hmm"},"finish_reason":null}]}'
role_only = 'data: {"choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}'
finish = 'data: {"choices":[{"index":0,"delta":{},"finish_reason":"length"}],"usage":null}'
usage = 'data: {"choices":[],"usage":{"prompt_tokens":23,"completion_tokens":40,"total_tokens":63}}'

check("a content delta is a delta", isinstance(probe.parse_sse_line(delta), probe.Delta))
check("a reasoning delta is a delta", isinstance(probe.parse_sse_line(reasoning), probe.Delta))
check("a role-only delta carries no token", isinstance(probe.parse_sse_line(role_only), probe.Ignored))
check("the finish chunk names its reason", probe.parse_sse_line(finish) == probe.Finish("length"))
check("the usage chunk carries exact counts", probe.parse_sse_line(usage) == probe.Usage(23, 40))
check("[DONE] ends the stream", isinstance(probe.parse_sse_line("data: [DONE]"), probe.Done))
check("a comment line is ignored", isinstance(probe.parse_sse_line(": keep-alive"), probe.Ignored))
check("malformed JSON is ignored, not fatal", isinstance(probe.parse_sse_line("data: {oops"), probe.Ignored))
check("a non-object payload is ignored", isinstance(probe.parse_sse_line("data: [1,2]"), probe.Ignored))
check("a null usage field is not usage", not isinstance(probe.parse_sse_line(delta), probe.Usage))

# ------------------------------------------------------------- per request

obs = probe.Observation(sent_at=10.0, chunk_times=(10.5, 10.6, 10.8, 11.0, 11.5),
                        prompt_tokens=30, completion_tokens=41, finish="length")
check("ttft is first chunk minus send", close(probe.ttft_s(obs), 0.5))
check("decode tok/s excludes the first token over the first-to-last span",
      close(probe.decode_tps(obs), 40 / 1.0))
check("tokens per chunk exposes speculation bundling", close(probe.tokens_per_chunk(obs), 41 / 5))
check("chunk gaps in ms", [round(g) for g in probe.chunk_gaps_ms(obs)] == [100, 200, 200, 500])
empty = probe.Observation(1.0, (), 5, 0, "")
check("no chunks, no ttft", probe.ttft_s(empty) is None)
check("no chunks, no decode rate", probe.decode_tps(empty) is None)
check("no chunks, no tokens per chunk", probe.tokens_per_chunk(empty) is None)
single = probe.Observation(1.0, (2.0,), 5, 1, "stop")
check("a single token has no decode rate", probe.decode_tps(single) is None)
instant = probe.Observation(1.0, (2.0, 2.0), 5, 9, "stop")
check("a zero span has no decode rate", probe.decode_tps(instant) is None)

# --------------------------------------------------------------- percentile

check("p50 of one value", probe.percentile([5.0], 0.5) == 5.0)
check("p50 nearest rank", probe.percentile([4.0, 1.0, 3.0, 2.0], 0.5) == 2.0)
check("p95 nearest rank", probe.percentile([float(i) for i in range(1, 101)], 0.95) == 95.0)
check("p100 is the max", probe.percentile([1.0, 9.0, 4.0], 1.0) == 9.0)
check("no values, no percentile", probe.percentile([], 0.5) is None)

# -------------------------------------------------------------------- round

observations = [
    probe.Observation(0.0, (0.4, 0.5, 1.4), 20, 91, "length"),
    probe.Observation(0.0, (0.6, 0.7, 2.6), 20, 101, "length"),
]
stats = probe.summarise_round(observations, wall_s=2.0)
check("round counts requests", stats.requests == 2)
check("round sums completion and prompt tokens", stats.completion_tokens == 192 and stats.prompt_tokens == 40)
check("aggregate tok/s is all tokens over the wall time", close(stats.aggregate_tps, 96.0))
check("per-request decode rates are kept", [round(r) for r in stats.per_request_decode_tps] == [90, 50])
check("ttft per request", [round(t, 1) for t in stats.ttft_s] == [0.4, 0.6])
check("finish reasons are counted", stats.finishes == {"length": 2})
check("tokens per chunk is the mean over requests", close(stats.tokens_per_chunk, (91 / 3 + 101 / 3) / 2))
try:
    probe.summarise_round([], wall_s=1.0)
    refused = False
except ValueError:
    refused = True
check("summarising nothing raises", refused)

# ------------------------------------------------------------------ counters

metrics = """# HELP hyperflare:spec_accepted_tokens_total MTP drafts accepted
# TYPE hyperflare:spec_accepted_tokens_total counter
hyperflare:spec_accepted_tokens_total{model_name="m"} 144390
hyperflare:spec_draft_tokens_total{model_name="m"} 214764
hyperflare:spec_draft_rounds_total{model_name="m"} 141266
hyperflare:spec_verify_rounds_total{model_name="m"} 226701
hyperflare:requests_total{model_name="m"} 74
hyperflare:requests_running{model_name="m"} 2
hyperflare:requests_waiting{model_name="m"} 1
hyperflare:model_info{model_name="m"} 1
"""
counters = probe.parse_counters(metrics)
check("counters parse", counters == probe.SpecCounters(144390.0, 214764.0, 141266.0, 74.0))
check("counters sum across label sets",
      probe.parse_counters(metrics + 'hyperflare:requests_total{model_name="n"} 6\n').requests == 80.0)
check("a bridge without the spec series is not parsed", probe.parse_counters("vllm:foo 1\n") is None)
check("in-flight is running plus waiting", probe.in_flight(metrics) == 3)
check("in-flight needs the series", probe.in_flight("nothing 1\n") is None)

before = probe.SpecCounters(1000.0, 1500.0, 800.0, 10.0)
after = probe.SpecCounters(1900.0, 2700.0, 1300.0, 14.0)
delta_counters = probe.counter_delta(before, after)
check("counter delta", delta_counters == probe.SpecCounters(900.0, 1200.0, 500.0, 4.0))
accept = probe.acceptance(delta_counters)
check("acceptance length is 1 + accepted/rounds, the monitoring rule's definition", close(accept.length, 1 + 900 / 500))
check("acceptance rate is accepted over draft positions", close(accept.rate, 900 / 1200))
check("a counter reset has no delta",
      probe.counter_delta(after, before) is None)
check("no rounds, no acceptance", probe.acceptance(probe.SpecCounters(0.0, 0.0, 0.0, 1.0)) is None)
check("no draft positions leaves the rate empty",
      probe.acceptance(probe.SpecCounters(5.0, 0.0, 5.0, 1.0)).rate is None)
check("an exact request count is a clean round", probe.clean(delta_counters, expected_requests=4))
check("an extra request is a contaminated round", not probe.clean(delta_counters, expected_requests=3))
check("no delta is never clean", not probe.clean(None, expected_requests=1))
check("a request still in flight afterwards is somebody else's",
      not probe.clean(delta_counters, expected_requests=4, in_flight_after=1))
check("an unreadable in-flight count is not clean", not probe.clean(delta_counters, expected_requests=4, in_flight_after=None))
check("nothing in flight afterwards is clean", probe.clean(delta_counters, expected_requests=4, in_flight_after=0))

# ------------------------------------------------------------------ summary

def record(name, repetition, tps, aggregate, ttft, delta, clean_round=True):
    stats = probe.RoundStats(
        requests=len(tps), completion_tokens=100 * len(tps), prompt_tokens=10, wall_s=2.0,
        aggregate_tps=aggregate, per_request_decode_tps=tuple(tps), ttft_s=tuple(ttft),
        chunk_gap_ms_p50=10.0, chunk_gap_ms_p95=30.0, tokens_per_chunk=2.0, finishes={"length": len(tps)})
    return probe.RoundRecord(name, repetition, stats, delta, clean_round)


records = [
    record("c4", 1, [100.0, 110.0], 200.0, [0.5, 0.7], probe.SpecCounters(100.0, 500.0, 50.0, 2.0)),
    record("c4", 2, [120.0, 130.0], 240.0, [0.4, 0.6], probe.SpecCounters(300.0, 500.0, 50.0, 2.0)),
    record("c4", 3, [1.0, 1.0], 2.0, [9.0, 9.0], probe.SpecCounters(0.0, 0.0, 0.0, 9.0), clean_round=False),
]
rows = probe.summarise_run(records)
check("one summary row per round name", [row.name for row in rows] == ["c4"])
row = rows[0]
check("contaminated repetitions are excluded", row.repetitions == 2 and row.contaminated == 1)
check("per-request decode is the median of the repetition means",
      close(row.decode_tps_per_request, probe.statistics.median([105.0, 125.0])))
check("aggregate is the median over repetitions", close(row.aggregate_tps, 220.0))
check("acceptance pools the counters of clean repetitions",
      close(row.acceptance.length, 1 + 400 / 100) and close(row.acceptance.rate, 400 / 1000))
check("ttft is the median over every request of clean repetitions",
      close(row.ttft_p50_s, probe.percentile([0.5, 0.7, 0.4, 0.6], 0.5)))
check("a round with only contaminated repetitions has no summary",
      probe.summarise_run([record("c1", 1, [1.0], 1.0, [1.0], None, clean_round=False)])[0].repetitions == 0)

# ------------------------------------------------------------------ prompts

check("decode prompts are unique per request",
      len({probe.decode_prompt(i, "abc") for i in range(8)}) == 8)
check("a nonce keeps repeated rounds from sharing a prefix",
      probe.decode_prompt(0, "aaa")[:20] != probe.decode_prompt(0, "bbb")[:20])
check("the prefill prompt scales with its sentence count",
      len(probe.prefill_prompt("n", 200)) > 2 * len(probe.prefill_prompt("n", 90)) * 0.9)
body = probe.request_payload("m", "hi", 50, 1.0, 0.95, "low")
check("the payload streams with usage", body["stream"] is True and body["stream_options"] == {"include_usage": True})
check("the payload carries sampling and effort",
      body["temperature"] == 1.0 and body["top_p"] == 0.95 and body["reasoning_effort"] == "low")
check("no effort, no field", "reasoning_effort" not in probe.request_payload("m", "hi", 50, 1.0, 0.95, None))

# ------------------------------------------------- end to end (fake endpoint)


class FakeServer(http.server.BaseHTTPRequestHandler):
    """The engine on one port and its bridge on another, sharing one set of counters."""

    state = {"requests": 0, "accepted": 0, "draft_tokens": 0, "rounds": 0, "running": 0,
             "extra_per_request": 0, "extra_next": 0}
    lock = threading.Lock()

    def log_message(self, *arguments):
        pass

    def do_GET(self):
        if self.path == "/v1/models":
            raw = json.dumps({"data": [{"id": "fake-model"}]}).encode()
        else:
            with FakeServer.lock:
                s = FakeServer.state
                raw = (f'hyperflare:spec_accepted_tokens_total{{model_name="fake"}} {s["accepted"]}\n'
                       f'hyperflare:spec_draft_tokens_total{{model_name="fake"}} {s["draft_tokens"]}\n'
                       f'hyperflare:spec_draft_rounds_total{{model_name="fake"}} {s["rounds"]}\n'
                       f'hyperflare:requests_total{{model_name="fake"}} {s["requests"]}\n'
                       f'hyperflare:requests_running{{model_name="fake"}} {s["running"]}\n'
                       f'hyperflare:requests_waiting{{model_name="fake"}} 0\n').encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        request = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        tokens = request["max_tokens"]
        with FakeServer.lock:
            s = FakeServer.state
            s["requests"] += 1 + s["extra_per_request"] + (1 if s["extra_next"] > 0 else 0)
            s["extra_next"] = max(0, s["extra_next"] - 1)
            s["rounds"] += tokens // 3
            s["accepted"] += tokens // 3 * 2
            s["draft_tokens"] += tokens // 3 * 4
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        sent = 0
        while sent < tokens:
            bundle = min(3, tokens - sent)
            sent += bundle
            chunk = {"choices": [{"index": 0, "delta": {"content": "x" * bundle}, "finish_reason": None}]}
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        self.wfile.write(('data: ' + json.dumps({"choices": [{"index": 0, "delta": {}, "finish_reason": "length"}]}) + "\n\n").encode())
        self.wfile.write(('data: ' + json.dumps({"choices": [], "usage": {"prompt_tokens": 12, "completion_tokens": tokens}}) + "\n\n").encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), FakeServer)
threading.Thread(target=server.serve_forever, daemon=True).start()
url = f"http://127.0.0.1:{server.server_address[1]}"


def run_main(arguments):
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        code = probe.main(arguments)
    return code, out.getvalue(), err.getvalue()


with tempfile.TemporaryDirectory() as scratch:
    scratch = pathlib.Path(scratch)
    common = ["--url", url, "--bridge", url, "--key-file", str(scratch / "no-key"),
              "--max-tokens", "30", "--repeat", "2", "--warmup", "0", "--idle-timeout", "2"]
    receipt_path = scratch / "receipt.json"
    code, out, err = run_main([*common, "--rounds", "c1,c4", "--out", str(receipt_path)])
    receipt = json.loads(receipt_path.read_text()) if receipt_path.exists() else {}
    check("a run exits 0", code == 0)
    check("the served model is discovered", receipt.get("model") == "fake-model")
    check("every repetition of every round is recorded", len(receipt.get("rounds", [])) == 4)
    check("every round is clean on an otherwise idle server", all(r["clean"] for r in receipt.get("rounds", [])))
    c4 = [r for r in receipt.get("rounds", []) if r["name"] == "c4"][0]
    check("c4 ran four requests and counted exact tokens", c4["stats"]["requests"] == 4 and c4["stats"]["completion_tokens"] == 120)
    check("the acceptance comes from the bridge deltas",
          close(c4["acceptance"]["length"], 1 + 2.0) and close(c4["acceptance"]["rate"], 0.5))
    check("the table names the rounds and the acceptance length", "c4" in out and "3.00" in out)
    check("the summary rows are in the receipt", [row["name"] for row in receipt.get("summary", [])] == ["c1", "c4"])

    # An engine that counts two requests per one sent is a server somebody else is also using.
    FakeServer.state["extra_per_request"] = 1
    code, out, err = run_main([*common, "--rounds", "c1", "--retries", "0", "--out", str(scratch / "dirty.json")])
    dirty = json.loads((scratch / "dirty.json").read_text())
    FakeServer.state["extra_per_request"] = 0
    check("a contaminated round is flagged, not silently averaged",
          code == 0 and not any(r["clean"] for r in dirty["rounds"]) and "contaminated" in (out + err))

    # Another client's request landing in a round costs that repetition, not the run: it is retried.
    FakeServer.state["extra_next"] = 1
    code, out, err = run_main([*common, "--repeat", "1", "--retries", "2", "--rounds", "c1",
                               "--out", str(scratch / "retry.json")])
    retried = json.loads((scratch / "retry.json").read_text())
    check("a contaminated repetition is retried until clean",
          code == 0 and [r["clean"] for r in retried["rounds"]] == [False, True])
    check("the summary counts the clean repetition and the discarded one",
          retried["summary"][0]["repetitions"] == 1 and retried["summary"][0]["contaminated"] == 1)
    FakeServer.state["extra_per_request"] = 1
    code, out, err = run_main([*common, "--repeat", "1", "--retries", "1", "--rounds", "c1",
                               "--out", str(scratch / "giveup.json")])
    FakeServer.state["extra_per_request"] = 0
    gave_up = json.loads((scratch / "giveup.json").read_text())
    check("retries are bounded: it gives up and says so", code == 0 and len(gave_up["rounds"]) == 2
          and gave_up["summary"][0]["repetitions"] == 0)

    # A server that never goes idle is refused rather than measured.
    FakeServer.state["running"] = 2
    code, out, err = run_main([*common, "--rounds", "c1", "--out", str(scratch / "busy.json")])
    FakeServer.state["running"] = 0
    check("a busy server is refused", code == 1 and "idle" in err and not (scratch / "busy.json").exists())

    code, out, err = run_main([*common, "--rounds", "c9", "--out", str(scratch / "bad.json")])
    check("an unknown round is refused", code == 2 and "c9" in err)
    code, out, err = run_main(["--url", url, "--bridge", "http://127.0.0.1:1", "--key-file", str(scratch / "no-key"),
                               "--rounds", "c1", "--out", str(scratch / "nobridge.json"), "--warmup", "0"])
    check("an unreachable bridge is refused with its reason", code == 1 and "bridge" in err)
server.shutdown()

if failures:
    print(f"\n{failures} failure(s)", file=sys.stderr)
    sys.exit(1)
print("\nall hyperflare-throughput-probe tests passed")
