#!/usr/bin/env python3
"""Unit tests for the ds4-native metrics bridge's functional core.

Run directly (`python3 tests/ds4-native-metrics-unit.py`) or from
`tests/inference-monitoring-contract.sh`. No network, no Maya, no GPU.
"""
import importlib.util
import math
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts" / "inference" / "shared" / "ds4-native-metrics.py"
spec = importlib.util.spec_from_file_location("ds4_native_metrics", MODULE)
metrics = importlib.util.module_from_spec(spec)
spec.loader.exec_module(metrics)

failures = 0


def check(name, condition):
    global failures
    if condition:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}", file=sys.stderr)


EXPOSITION = """\
# HELP llamacpp:prompt_tokens_total Prompt tokens read
# TYPE llamacpp:prompt_tokens_total counter
llamacpp:prompt_tokens_total 300547
llamacpp:prompt_tokens_cached_total 13661656
llamacpp:tokens_predicted_total 91140
llamacpp:requests_processing 1
llamacpp:requests_deferred 2
maya:requests_total 209
maya:engine_tok_s 89.88
maya:engine_vram_hit 0.9505
maya:engine_vram_used 7998
maya:engine_vram_slots 8400
maya:engine_ram_used 1200
maya:engine_ram_slots 3000
"""

values = metrics.parse_gauges(EXPOSITION)
check("parses counters", values["llamacpp:prompt_tokens_total"] == 300547)
check("parses gauges", math.isclose(values["maya:engine_vram_hit"], 0.9505))
check("skips HELP/TYPE lines", len(values) == 12)

histogram = metrics.empty_histogram("e2e")
check("empty histogram is zero", histogram.total == 0 and set(histogram.counts) == {0})
histogram = metrics.observe(histogram, 2.0)
check("observation is counted", histogram.total == 1 and math.isclose(histogram.total_sum, 2.0))
check(
    "buckets are cumulative at the observation's bound",
    histogram.counts == (0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1),
)
histogram = metrics.observe(histogram, 0.2)
check(
    "a smaller observation lands in every later bucket",
    histogram.counts == (0, 1, 1, 1, 2, 2, 2, 2, 2, 2, 2, 2),
)
before = histogram
histogram = metrics.observe(histogram, float("nan"))
check("NaN changes nothing", histogram == before)
histogram = metrics.observe(histogram, -1.0)
check("negative time changes nothing", histogram == before)

rows = [
    {
        "time": 1792590335.25,
        "api": "/v1/chat/completions",
        "prompt_tokens": 1200,
        "output_tokens": 80,
        "prompt_ms": 2400.0,
        "decode_ms": 800.0,
        "drafts_offered": 40.0,
        "drafts_accepted": 26.0,
    },
    {
        "time": 1792590340.5,
        "api": "/v1/messages",
        "prompt_tokens": 300,
        "output_tokens": 0,
        "prompt_ms": 100.0,
        "decode_ms": None,
        "drafts_offered": None,
        "drafts_accepted": None,
    },
]
seen, fresh = metrics.unseen(set(), rows)
check("first pass counts every row", len(fresh) == 2)
seen, fresh = metrics.unseen(seen, rows)
check("second pass counts none", fresh == [])
seen, fresh = metrics.unseen(seen, rows + [rows[0] | {"time": 1792590399.0}])
check("a new row is still counted", len(fresh) == 1)

snapshot = metrics.accrue(metrics.empty_snapshot("warmind-1017-native"), rows)
check("end-to-end latency needs a decode phase", snapshot.histograms["e2e"].total == 1)
check("inter-token latency observed once", snapshot.histograms["itl"].total == 1)
check(
    "inter-token latency is per output token",
    math.isclose(snapshot.histograms["itl"].total_sum, 800.0 / 1000.0 / 80.0),
)
check("ttft observed for both requests", snapshot.histograms["ttft"].total == 2)
check("drafts offered accrue", math.isclose(snapshot.spec_drafts, 40.0))
check("drafts accepted accrue", math.isclose(snapshot.spec_accepted, 26.0))

values["model_name"] = 'a"b'
snapshot = metrics.accrue(metrics.replace(snapshot, values=values), [])
out = metrics.render(snapshot)
check("model label is on counters", 'ds4:generation_tokens_total{model_name="warmind-1017-native"} 91140' in out)
check(
    "prompt tokens include the cached conversation",
    'ds4:prompt_tokens_total{model_name="warmind-1017-native"} 13962203' in out,
)
check("prefix hits are the cached tokens", 'ds4:prefix_cache_hits_total{model_name="warmind-1017-native"} 13661656' in out)
check("expert residency is exported", 'ds4:expert_cache_residency{model_name="warmind-1017-native"} 0.9505' in out)
check("histogram has an +Inf bucket", 'le="+Inf"} 2' in out)
check("histogram has a count", 'ds4:e2e_request_latency_seconds_count{model_name="warmind-1017-native"} 1' in out)
check("label values escape quotes", 'model_name="a\\"b"' in metrics.render(metrics.replace(snapshot, model='a"b')))

if failures:
    print(f"{failures} failure(s)", file=sys.stderr)
    raise SystemExit(1)
print("PASS: ds4-native metrics functional core")
