#!/usr/bin/env bash
# Static contract for the concurrent BF16 Qwen + Muse Glimmer deployment.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOAD="$ROOT/scripts/inference/muse/download-muse-glimmer-30b.sh"
VARIANTS="$ROOT/scripts/inference/muse/muse-glimmer-variant.sh"
MUSE_RUN="$ROOT/scripts/inference/muse/run-muse-glimmer-30b-bf16-dflash.sh"
QWEN_RUN="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16.sh"
DUAL_RUN="$ROOT/scripts/inference/profiles/run-qwen38-muse-glimmer-dual.sh"
ENTRYPOINT="$ROOT/scripts/inference/shared/sglang-secure-entrypoint.py"
KEY_HELPER="$ROOT/scripts/inference/shared/inference-api-key.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_ROUTING="$ROOT/pi/model-routing.json"
PI_DOC="$ROOT/pi/README.md"
DESKTOP="$ROOT/machines/desktop/default.nix"
PROMETHEUS="$ROOT/k8s/argocd-homelab/monitoring/values.yaml"
DOC="$ROOT/docs/runbooks/new-desktop-install.md"
IMAGE="lmsysorg/sglang:nightly-dev-cu13-20260816-4a6dc267"
DIGEST="sha256:0d73f8dd82c8adbbe481d8520cb6d62d80828f1e62267ee41a3c67cf3dd77528"
TARGET_REV="a4e59da52a7bc87ae7251dd5545c0dd437c44b68"
DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for script in "$DOWNLOAD" "$MUSE_RUN" "$QWEN_RUN" "$DUAL_RUN"; do
  [[ -x "$script" ]] || fail "$script is not executable"
  bash -n "$script"
done
[[ -f "$VARIANTS" ]] || fail "$VARIANTS is missing"
bash -n "$VARIANTS"

contains "$VARIANTS" 'MUSE_TARGET_REPO="meta-models/Muse-Glimmer-30B"'
contains "$VARIANTS" "MUSE_TARGET_REV=\"$TARGET_REV\""
contains "$VARIANTS" 'MUSE_DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"'
contains "$VARIANTS" "MUSE_DRAFT_REV=\"$DRAFT_REV\""
contains "$VARIANTS" 'MUSE_TARGET_REPO="mlasli/Muse-Glimmer-30B-Abliterated-BF16"'
contains "$VARIANTS" 'MUSE_TARGET_REV="daf5fab76a0351a583714a92d88ebdb6eb48af35"'
contains "$VARIANTS" 'MUSE_CONTAINER_NAME="muse-glimmer-30b-abliterated-bf16-dflash"'
[[ "$(grep -Ec '^[0-9a-f]{64}  (model-.*\.safetensors|tokenizer\.json)$' "$VARIANTS")" -eq 3 ]] \
  || fail "$VARIANTS must pin all three large Abliterated-BF16 artifacts"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$VARIANTS"
muse_resolve_variant standard
[[ "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" == "meta-models/Muse-Glimmer-30B@$TARGET_REV" ]] \
  || fail "standard Muse variant resolves incorrectly"
muse_resolve_variant abliterated
[[ "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" == "mlasli/Muse-Glimmer-30B-Abliterated-BF16@daf5fab76a0351a583714a92d88ebdb6eb48af35" ]] \
  || fail "abliterated Muse variant resolves incorrectly"
MUSE_MODELS_ROOT=/tmp/muse-staging muse_resolve_variant abliterated
[[ "$MUSE_TARGET_HOST" == /tmp/muse-staging/Muse-Glimmer-30B-Abliterated-BF16 ]] \
  || fail "abliterated Muse staging root resolves incorrectly"
unset MUSE_MODELS_ROOT
unknown_status=0
muse_resolve_variant unknown >/dev/null 2>&1 || unknown_status=$?
[[ "$unknown_status" -eq 2 ]] || fail "variant resolver must reject unknown variants"

contains "$DOWNLOAD" 'source "$SCRIPT_DIR/muse-glimmer-variant.sh"'
contains "$DOWNLOAD" 'muse_resolve_variant "${MUSE_VARIANT:-standard}"'
contains "$DOWNLOAD" 'export HF_HUB_DISABLE_XET=1'
contains "$DOWNLOAD" "printf '%s\\n' '\$MUSE_TARGET_REPO@\$MUSE_TARGET_REV' > '\$MUSE_TARGET_HOST/.download-complete'"
contains "$DOWNLOAD" "printf '%s\\n' '\$MUSE_DRAFT_REPO@\$MUSE_DRAFT_REV' > '\$MUSE_DRAFT_HOST/.download-complete'"
contains "$DOWNLOAD" "printf '%s\\n' '\$MUSE_TARGET_SHA256_MANIFEST' | sha256sum --check --strict"
contains "$DOWNLOAD" '-v "$MUSE_TARGET_HOST":"$MUSE_TARGET_HOST"'
contains "$DOWNLOAD" '-v "$MUSE_DRAFT_HOST":"$MUSE_DRAFT_HOST"'
if grep -Fq -- '-v /models:/models' "$DOWNLOAD"; then
  fail "$DOWNLOAD grants its throwaway container write access to unrelated checkpoints"
fi
if grep -Fq 'HF_XET_HIGH_PERFORMANCE' "$DOWNLOAD"; then
  fail "$DOWNLOAD re-enables the Xet backend that hangs on this workstation"
fi

contains "$MUSE_RUN" "IMAGE=\"$IMAGE\""
contains "$MUSE_RUN" "DIGEST=\"$DIGEST\""
contains "$MUSE_RUN" 'source "$SCRIPT_DIR/muse-glimmer-variant.sh"'
contains "$MUSE_RUN" 'muse_resolve_variant "${MUSE_VARIANT:-standard}"'
contains "$MUSE_RUN" '--name "$MUSE_CONTAINER_NAME"'
contains "$MUSE_RUN" '--gpus "\"device=$GPU_DEVICE\""'
contains "$MUSE_RUN" '-e CUDA_VISIBLE_DEVICES=0'
contains "$MUSE_RUN" '--dtype bfloat16'
contains "$MUSE_RUN" '--tp-size 1'
contains "$MUSE_RUN" 'CONTEXT_LENGTH="${CONTEXT_LENGTH:-131072}"'
contains "$MUSE_RUN" 'MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}"'
contains "$MUSE_RUN" 'MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"'
contains "$MUSE_RUN" 'MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"'
contains "$MUSE_RUN" '--query-gpu=power.limit,memory.used'
contains "$MUSE_RUN" 'if ((memory_used > MAX_EXISTING_GPU_MEMORY_MIB)); then'
contains "$MUSE_RUN" '--language-model-only'
contains "$MUSE_RUN" '--speculative-algorithm DFLASH'
contains "$MUSE_RUN" '--speculative-draft-model-path "$MUSE_DRAFT_CONTAINER"'
contains "$MUSE_RUN" '--reasoning-parser muse'
contains "$MUSE_RUN" '--tool-call-parser muse'
contains "$MUSE_RUN" '--sampling-defaults model'
contains "$MUSE_RUN" '--enable-metrics'
contains "$MUSE_RUN" '--env-file "$ENVFILE"'
contains "$MUSE_RUN" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$MUSE_RUN" 'inference_prepare_api_key'
contains "$ENTRYPOINT" 'os.environ.pop("SGLANG_API_KEY", "")'
if grep -Eq -- '^[[:space:]]*--api-key([=[:space:]]|$)' "$MUSE_RUN"; then
  fail "$MUSE_RUN exposes the API key through Docker command arguments"
fi

invalid_variant_status=0
MUSE_VARIANT=unknown bash "$MUSE_RUN" >/dev/null 2>&1 || invalid_variant_status=$?
[[ "$invalid_variant_status" -eq 2 ]] || fail "$MUSE_RUN must reject an unknown Muse variant"
invalid_gpu_status=0
GPU_DEVICE=2 bash "$MUSE_RUN" >/dev/null 2>&1 || invalid_gpu_status=$?
[[ "$invalid_gpu_status" -eq 2 ]] || fail "$MUSE_RUN must reject an invalid GPU before filesystem access"

contains "$QWEN_RUN" 'GPU_DEVICES="${GPU_DEVICES:-}"'
contains "$QWEN_RUN" 'PORT="${PORT:-8000}"'
contains "$QWEN_RUN" '--gpus "\"device=$GPU_DEVICES\""'
contains "$QWEN_RUN" '-e CUDA_VISIBLE_DEVICES="$CONTAINER_CUDA_VISIBLE_DEVICES"'
contains "$QWEN_RUN" '--port "$PORT"'
invalid_qwen_gpu_status=0
TP_SIZE=1 GPU_DEVICES=0,1 bash "$QWEN_RUN" >/dev/null 2>&1 || invalid_qwen_gpu_status=$?
[[ "$invalid_qwen_gpu_status" -eq 2 ]] || fail "$QWEN_RUN must enforce one selected physical GPU for TP1"

contains "$DUAL_RUN" 'TP_SIZE=1'
contains "$DUAL_RUN" 'GPU_DEVICES=1'
contains "$DUAL_RUN" 'PORT="$QWEN_PORT"'
contains "$DUAL_RUN" 'SPEC_MTP=0'
contains "$DUAL_RUN" 'GPU_DEVICE=0'
contains "$DUAL_RUN" 'PORT="$MUSE_PORT"'
contains "$DUAL_RUN" 'systemctl is-active --quiet display-manager'
contains "$DUAL_RUN" 'muse_resolve_variant "${MUSE_VARIANT:-standard}"'
contains "$DUAL_RUN" '"$MUSE_TARGET_HOST|$MUSE_TARGET_REPO@$MUSE_TARGET_REV"'
contains "$DUAL_RUN" '"$MUSE_DRAFT_HOST|$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV"'
contains "$DUAL_RUN" 'inference_require_pinned_checkpoint "$muse_path" "$expected_marker" "$download_hint"'
contains "$DUAL_RUN" 'MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"'
contains "$DUAL_RUN" 'MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"'
contains "$DUAL_RUN" '--query-gpu=index,memory.used'
contains "$DUAL_RUN" 'inference_stop_container_if_present "$container"'
contains "$DUAL_RUN" 'inference_remove_container_if_present "$container"'
contains "$MUSE_RUN" 'MUSE_READY:'
contains "$DUAL_RUN" 'if ((memory_used > MAX_EXISTING_GPU_MEMORY_MIB)); then'
contains "$DUAL_RUN" 'trap cleanup_failed_transition ERR INT TERM'
contains "$DUAL_RUN" 'endpoint_is_healthy'
contains "$DUAL_RUN" 'curl --silent --show-error --fail --output /dev/null --config -'

contains "$KEY_HELPER" 'INFERENCE_MUSE_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/muse-glimmer/api-key"'
jq -e '.modelClasses.local | index("desktop-muse/*") != null' "$PI_ROUTING" >/dev/null ||
  fail "Pi model routing does not classify desktop-muse as local"
contains "$DESKTOP" 'environment.VLLM_METRICS_URLS = "http://127.0.0.1:8000/metrics http://127.0.0.1:8001/metrics";'
contains "$DESKTOP" 'networking.firewall.allowedTCPPorts = [ 8000 8001 8090 ];'
contains "$PROMETHEUS" 'targets: ["192.168.0.80:8000"]'
contains "$PROMETHEUS" 'targets: ["192.168.0.80:8001"]'
contains "$PROMETHEUS" 'instance: desktop:8000'
contains "$PROMETHEUS" 'instance: desktop:8001'

jq -e '
  .providers."desktop-muse" as $provider |
  ($provider.baseUrl == "http://192.168.0.80:8001/v1") and
  ($provider.api == "openai-completions") and
  ($provider.apiKey | contains("~/.config/muse-glimmer/api-key")) and
  ($provider.models | any(
    .id == "muse-glimmer-30b" and
    .reasoning == true and
    .defaultThinkingLevel == "xhigh" and
    .thinkingLevelMap == {
      "off": null,
      "minimal": null,
      "low": "low",
      "medium": "medium",
      "high": "high",
      "xhigh": "xhigh",
      "max": null
    } and
    .input == ["text"] and
    .contextWindow == 131072 and
    .compat.supportsDeveloperRole == false and
    .compat.supportsReasoningEffort == false and
    .compat.supportsStrictMode == false and
    .compat.requiresReasoningContentOnAssistantMessages == true and
    .compat.thinkingFormat == "chat-template" and
    .compat.chatTemplateKwargs.reasoning_strength == {"$var": "thinking.effort"}
  ))
' "$PI_MODELS" >/dev/null || fail "Pi's desktop-muse catalog does not expose the Muse native-template contract"

contains "$DOC" 'Muse Glimmer BF16 + DFlash beside Qwen'
contains "$DOC" "$IMAGE"
contains "$DOC" "$DIGEST"
contains "$DOC" "$TARGET_REV"
contains "$DOC" "$DRAFT_REV"
contains "$DOC" 'bash tests/muse-glimmer-dual-contract.sh'
contains "$PI_DOC" 'desktop-muse/muse-glimmer-30b'
contains "$PI_DOC" 'Muse runs concurrently on port 8001'

printf 'PASS: concurrent BF16 Qwen + Muse Glimmer contract is internally consistent\n'
