#!/usr/bin/env bash
# Static contract for runtime-neutral vLLM/SGLang monitoring.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DASHBOARD="$ROOT/k8s/argocd-homelab/monitoring/dashboard-vllm.json"
RULES="$ROOT/k8s/argocd-homelab/monitoring/templates/inference-recording-rules.yaml"
RECORDER="$ROOT/scripts/vllm-stats-record.py"

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
  ([.panels[].title] | index("Mamba state usage") != null) and
  (.templating.list[] | select(.name == "model") | .query.query |
    contains("inference:generation_tokens_total") and
    contains("vllm:generation_tokens_total") and
    contains("sglang:generation_tokens_total"))
' "$DASHBOARD" >/dev/null || fail "dashboard does not satisfy the normalized metric contract"

[ "$(grep -Fc -- '"engine", "vllm"' "$RULES")" -ge 10 ] ||
  fail "normalized vLLM series do not preserve engine identity"
[ "$(grep -Fc -- '"engine", "sglang"' "$RULES")" -ge 15 ] ||
  fail "normalized SGLang series do not preserve engine identity"

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

for marker in \
  '"vllm": {' \
  '"sglang": {' \
  'sglang:generation_tokens_histogram_count' \
  'engine changed' \
  'merge_endpoint_states' \
  'recover_pending_interval'; do
  grep -Fq -- "$marker" "$RECORDER" || fail "recorder missing $marker"
done

echo "PASS: inference monitoring supports normalized vLLM and SGLang metrics"
