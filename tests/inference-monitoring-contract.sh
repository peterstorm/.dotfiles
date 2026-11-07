#!/usr/bin/env bash
# Static contract for runtime-neutral vLLM/SGLang/ds4-native monitoring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="$ROOT/k8s/argocd-homelab/monitoring/dashboard-vllm.json"
RULES="$ROOT/k8s/argocd-homelab/monitoring/templates/inference-recording-rules.yaml"
RECORDER="$ROOT/scripts/inference/shared/vllm-stats-record.py"
BRIDGE="$ROOT/scripts/inference/shared/ds4-native-metrics.py"
BRIDGE_TEST="$ROOT/tests/ds4-native-metrics-unit.py"
HEATMAP="$ROOT/scripts/inference/shared/vllm-stats-heatmap.py"
DESKTOP="$ROOT/machines/desktop/default.nix"
PROMETHEUS="$ROOT/k8s/argocd-homelab/monitoring/values.yaml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

jq empty "$DASHBOARD"

[ "$(jq -r '.title' "$DASHBOARD")" = "Local inference — desktop" ] ||
  fail "dashboard title is still runtime-specific"

jq -e '
  [.panels[].targets[]? | .expr] as $expressions |
  ($expressions | length) >= 28 and
  all($expressions[]; contains("inference:")) and
  ([.panels[].title] | index("DSpark acceptance length") != null) and
  ([.panels[].title] | index("DSpark draft acceptance") != null) and
  ([.panels[].title] | index("DSpark verification rate") != null) and
  ([.panels[].title] | index("Mamba / RAM-tier usage") != null) and
  ([.panels[].title] | index("KV cache / expert cache miss") != null) and
  ([.panels[].title] | index("Prefix cache hit rate (5m)") != null) and
  (.panels[] | select(.id == 15) | (.targets | length) == 1 and .gridPos.w == 8) and
  (.panels[] | select(.id == 20) |
    (.targets | length) == 1 and
    .gridPos.w == 8 and
    (.targets[0].expr |
      contains("inference:prefix_cache_hit_ratio") and
      contains("calculation=\"token_weighted_5m\"") and
      contains("or max(("))) and
  (.templating.list[] | select(.name == "model") | .query.query |
    contains("inference:generation_tokens_total") and
    contains("vllm:generation_tokens_total") and
    contains("sglang:generation_tokens_total"))
' "$DASHBOARD" >/dev/null || fail "dashboard does not satisfy the normalized metric contract"

[ "$(grep -Fc -- '"engine", "vllm"' "$RULES")" -ge 10 ] ||
  fail "normalized vLLM series do not preserve engine identity"
[ "$(grep -Fc -- '"engine", "sglang"' "$RULES")" -ge 15 ] ||
  fail "normalized SGLang series do not preserve engine identity"
[ "$(grep -Fc -- '"engine", "ds4-native"' "$RULES")" -ge 10 ] ||
  fail "normalized ds4-native series do not preserve engine identity"
[ "$(grep -Fc -- 'ds4:spec_drafts_total' "$RULES")" -ge 2 ] ||
  fail "ds4-native DSpark drafts counter is not normalized"
grep -Fq -- 'ds4:expert_cache_residency' "$RULES" ||
  fail "ds4-native expert-cache pressure is not derived from the residency gauge"
grep -Fq -- 'ds4:ram_slots_used / ds4:ram_slots' "$RULES" ||
  fail "ds4-native RAM-tier residency is not the hybrid-state proxy"
grep -Fq -- 'calculation: token_weighted_5m' "$RULES" ||
  fail "prefix-cache calculation identity is not versioned"
grep -Fq -- 'sglang:prefill_effective_tokens_total{mode=~".*_hit"}[5m]' "$RULES" ||
  fail "SGLang prefix-cache ratio is not derived from token counters"
if grep -Fq -- 'label_replace(sglang:cache_hit_rate' "$RULES"; then
  fail "SGLang prefix-cache ratio still uses the instantaneous gauge"
fi
if grep -Fq -- 'clamp_min' "$RULES"; then
  fail "idle prefix-cache windows are forced to a false zero"
fi
grep -Fq -- 'rate(sglang:prefill_effective_tokens_total[5m])' "$RULES" &&
  grep -Fq -- ') > 0)' "$RULES" ||
  fail "idle prefix-cache windows are not filtered"
grep -Fq -- 'or (0 * sum without (mode, moe_ep_rank, pp_rank, tp_rank)' "$RULES" ||
  fail "active miss-only prefix-cache windows do not produce 0%"

for metric in \
  inference:prompt_tokens_total \
  inference:generation_tokens_total \
  inference:request_success_total \
  inference:kv_cache_usage_ratio \
  inference:inter_token_latency_seconds_bucket \
  inference:spec_accept_length \
  inference:spec_accept_rate \
  inference:spec_verify_calls_total \
  inference:mamba_usage_ratio; do
  grep -Fq -- "$metric" "$RULES" || fail "recording rules missing $metric"
done

# vLLM spec-decode counters must feed the normalized spec series, or a
# DSpark/MTP-on-vLLM run leaves the dashboard acceptance panels empty.
[ "$(grep -Fc -- 'vllm:spec_decode_num_drafts_total' "$RULES")" -ge 2 ] ||
  fail "vLLM spec-decode drafts counter is not normalized"
[ "$(grep -Fc -- 'vllm:spec_decode_num_accepted_tokens_total' "$RULES")" -ge 2 ] ||
  fail "vLLM spec-decode accepted-tokens counter is not normalized"
[ "$(grep -Fc -- 'vllm:spec_decode_num_draft_tokens_total' "$RULES")" -ge 2 ] ||
  fail "vLLM spec-decode draft-tokens counter is not normalized"

for marker in \
  '"vllm": {' \
  '"sglang": {' \
  '"ds4-native": {' \
  'sglang:generation_tokens_histogram_count' \
  'ds4:generation_tokens_total' \
  'engine changed' \
  'merge_endpoint_states' \
  'recover_pending_interval' \
  'model_name' \
  'Historical aggregate' \
  'VLLM_STATS_LEGACY_ATTRIBUTIONS' \
  'migrate_legacy_attributions' \
  'prompt_tokens_per_second' \
  'generation_tokens_per_second'; do
  grep -Fq -- "$marker" "$RECORDER" || fail "recorder missing $marker"
done

grep -Fq -- 'from_ts = 1786837395;' "$DESKTOP" &&
grep -Fq -- 'through_ts = 1786846530;' "$DESKTOP" &&
grep -Fq -- 'model = "qwen3.8-27b";' "$DESKTOP" &&
grep -Fq -- 'engine = "sglang";' "$DESKTOP" ||
  fail "desktop does not preserve the evidence-backed SGLang/Qwen attribution range"
grep -Fq -- 'VLLM_METRICS_URLS = "http://127.0.0.1:8000/metrics http://127.0.0.1:8001/metrics http://127.0.0.1:8010/metrics"' "$DESKTOP" ||
  fail "durable recorder does not scrape both concurrent inference endpoints and the native bridge"

# The native bridge is a read-only anti-corruption layer; it must never be in a
# position to stall the engine (no stdin writes, no GPU work, no privileged user).
for marker in \
  'systemd.services.ds4-native-metrics' \
  'DS4_NATIVE_SOURCE = "http://127.0.0.1:8000"' \
  'DS4_NATIVE_LISTEN = "0.0.0.0:8010"' \
  'DS4_NATIVE_KEY_FILE = "/home/peterstorm/.config/ds4-flash/api-key"' \
  'User = "peterstorm";' \
  'networking.firewall.allowedTCPPorts = [ 8000 8001 8010 8090 ];'; do
  grep -Fq -- "$marker" "$DESKTOP" || fail "desktop configuration missing: $marker"
done
for endpoint in '192.168.0.80:8000' '192.168.0.80:8001' '192.168.0.80:8010'; do
  grep -Fq -- "$endpoint" "$PROMETHEUS" || fail "Prometheus does not scrape $endpoint"
done
for instance in 'desktop:8000' 'desktop:8001' 'desktop:8010'; do
  grep -Fq -- "instance: $instance" "$PROMETHEUS" || fail "Prometheus does not preserve instance $instance"
done

# The bridge's functional core must compile and pass its pure-function suite.
PYTHON="$(nix build --no-link --print-out-paths nixpkgs#python3)/bin/python3"
"$PYTHON" -m py_compile "$BRIDGE"
"$PYTHON" "$BRIDGE_TEST" >/dev/null

for marker in \
  'All models' \
  'Model comparison' \
  'Served throughput · 24 hours' \
  'Filter statistics by model' \
  'Cloud cost counterfactual' \
  'Active-hour rate' \
  'including idle time'; do
  grep -Fq -- "$marker" "$HEATMAP" || fail "stats page missing: $marker"
done

echo "PASS: inference monitoring supports normalized vLLM, SGLang and ds4-native metrics"
