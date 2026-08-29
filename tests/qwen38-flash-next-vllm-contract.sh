#!/usr/bin/env bash
# Literal shell fragments below are contract strings, not expressions to expand.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT/scripts/inference/qwen38/qwen38-flash-next-fp8-v1.manifest"
DOWNLOAD="$ROOT/scripts/inference/qwen38/download-qwen38-flash-next-fp8-v1.sh"
VERIFY="$ROOT/scripts/inference/qwen38/verify-qwen38-flash-next-fp8-v1.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-flash-next-vllm-v1-image.sh"
OVERLAY="$ROOT/scripts/inference/qwen38/flash-next-topk3/Dockerfile"
PATCH="$ROOT/scripts/inference/qwen38/flash-next-topk3/qsa-exact-topk.patch"
PROBE="$ROOT/scripts/inference/qwen38/probe-qwen38-flash-next-determinism.sh"
FIXTURE="$ROOT/tests/fixtures/qwen38-flash-next/D2.md"
RUN="$ROOT/scripts/inference/qwen38/run-qwen38-flash-next-fp8-vllm-v1.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-flash-next-profile-v1.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

[ "$(sha256sum "$MANIFEST" | cut -d' ' -f1)" = 7d02680af7388f69f23d78a5db2e2c9f5bc536ba7a6b264068a9b2bb6b85157e ]
[ "$(wc -l <"$MANIFEST")" -eq 144 ]
[ "$(awk -F '\t' '{sum+=$2} END {printf "%.0f",sum}' "$MANIFEST")" = 185563783486 ]
[ "$(grep -Ec $'^[0-9a-f]{64}\t[0-9]+\tmodel-[0-9]{5}-of-00131\\.safetensors$' "$MANIFEST")" -eq 131 ]
awk -F '\t' 'length($1) != 64 || $2 !~ /^[0-9]+$/ || $3 == "" {exit 1}' "$MANIFEST"

for file in "$DOWNLOAD" "$VERIFY" "$PULL" "$PROBE" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done

contains "$DOWNLOAD" 'Qwen/Qwen3.8-Flash-Next-FP8'
contains "$DOWNLOAD" '970c569adaca6b35532111fd6b27351b2baefe50'
contains "$DOWNLOAD" 'allow_patterns=[relative for _, _, relative in records]'
contains "$DOWNLOAD" 'max_workers=4'
contains "$DOWNLOAD" 'for attempt in range(1, 9)'
contains "$DOWNLOAD" 'ngram_shards != set(range(128))'
contains "$DOWNLOAD" 'os.replace(temporary, marker)'
contains "$VERIFY" 'inference_require_pinned_checkpoint'
contains "$VERIFY" '.metadata.total_size == 185502232570'
contains "$VERIFY" '(.weight_map | length) == 152089'
contains "$VERIFY" 'license_identity%$'"'"'\r'"'"''

contains "$PULL" 'sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8'
contains "$PULL" 'sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3'
contains "$PULL" 'sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9'
contains "$PULL" 'ai.vllm.build.commit"] == "unknown"'
contains "$PULL" 'Qwen3_8FlashNextNGramEmbedding'
contains "$PULL" '0.1.dev20073+g8e685d198'
contains "$PULL" 'PleOffloadLayer'
contains "$PULL" 'envs.VLLM_PLE_CPU_OFFLOAD is True'
contains "$PULL" 'ai.vllm.build.pipeline'
contains "$PULL" 'ai.vllm.image.tag'
contains "$PULL" 'sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32'
contains "$PULL" 'b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4'
contains "$PULL" '79d13ab4a3805bd568e3b930cd0cc193fbf5997403f9d4e809838193c14204dc'
contains "$PULL" 'derived image does not retain the exact base rootfs prefix'
contains "$PULL" 'Qwen3.8 Flash-Next deterministic QSA top-k3 + PLE capability probe: PASS'
contains "$OVERLAY" 'ENV VLLM_QSA_EXACT_TOPK=3'
contains "$OVERLAY" 'patch --batch --fuzz=0'
[ "$(sha256sum "$PATCH" | cut -d' ' -f1)" = b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4 ]
[ "$(sha256sum "$FIXTURE" | cut -d' ' -f1)" = 8449957bd502008cfc42ed500c490a5d2777267e50c58416859a6c717e579a92 ]

contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.94}"'
contains "$RUN" 'MIN_AVAILABLE_RAM_KIB=62914560'
contains "$RUN" 'systemctl is-active --quiet comfyui.service'
contains "$RUN" 'IMAGE="sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32"'
contains "$RUN" '-e VLLM_PLE_CPU_OFFLOAD=1'
contains "$RUN" '-e VLLM_QSA_EXACT_TOPK=3'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--no-enable-prefix-caching'
contains "$RUN" '--no-enable-flashinfer-autotune'
contains "$RUN" '--tool-call-parser qwen3_coder'
contains "$RUN" '--reasoning-parser qwen3'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3}'\'''
contains "$RUN" '--limit-mm-per-prompt '\''{"image":1,"video":0}'\'''
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi
contains "$SWITCH" 'TARGET="qwen38-flash-next-fp8-vllm-v1"'
contains "$SWITCH" '"$RUN" --preflight'
contains "$SWITCH" 'inference_quiesce_failed_container "$TARGET"'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$SWITCH" 'PROBE="$SCRIPT_DIR/probe-qwen38-flash-next-determinism.sh"'
contains "$SWITCH" 'if ! wait_for_target || ! "$PROBE"; then'
contains "$PROBE" 'temperature: 0.0'
contains "$PROBE" 'max_tokens: 1'
contains "$PROBE" 'top_logprobs: 20'
contains "$PROBE" 'determinism probe requires an idle engine'
contains "$PROBE" 'greedy prefill is byte-identical across $ITERATIONS runs'
contains "$CATALOG" 'qwen38-flash-next-fp8-vllm-v1'
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "qwen3.8-flash-next-fp8") |
  .input == ["text", "image"] and
  .contextWindow == 262144 and
  .defaultThinkingLevel == "xhigh" and
  .thinkingLevelMap.low == "low" and
  .thinkingLevelMap.medium == "medium" and
  .thinkingLevelMap.xhigh == "xhigh"
' "$PI_MODELS" >/dev/null

set +e
output="$(MAX_NUM_SEQS=5 bash "$RUN" --preflight 2>&1)"
status=$?
set -e
[ "$status" -eq 2 ] || { echo "FAIL: MAX_NUM_SEQS=5 status=$status" >&2; exit 1; }
grep -Fq 'MAX_NUM_SEQS must be an integer in [1, 4]' <<<"$output"

bash -n "$PULL"
bash -n "$PROBE"
bash -n "$RUN"
bash -n "$SWITCH"

echo 'PASS: Qwen3.8 Flash-Next FP8 is immutable, deterministic-top-k gated, TP2-bounded, PLE-offloaded, and experimental'
