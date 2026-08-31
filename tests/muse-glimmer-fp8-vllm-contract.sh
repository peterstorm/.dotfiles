#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016 # Runtime-relative source and literal source probes.
# Contract for Muse Glimmer FP8 and Blackfrost BF16 on pinned Muse-native vLLM.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROFILE="$ROOT/scripts/inference/muse/muse-glimmer-fp8-profile.sh"
VARIANTS="$ROOT/scripts/inference/muse/muse-glimmer-variant.sh"
DOWNLOAD="$ROOT/scripts/inference/muse/download-muse-glimmer-30b-fp8.sh"
RUNTIME="$ROOT/scripts/inference/muse/run-muse-glimmer-30b-vllm.sh"
FP8_RUN="$ROOT/scripts/inference/muse/run-muse-glimmer-30b-fp8-vllm.sh"
BLACKFROST_RUN="$ROOT/scripts/inference/muse/run-muse-glimmer-30b-blackfrost-bf16-dflash-vllm.sh"
TARGET_REV="8ed2e29141d4fef439b9a0e15e0a2678bc190a82"
DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"
BLACKFROST_REV="1b489c23b583d609b6c17b00e1a877d1faac1ee2"
IMAGE_DIGEST="sha256:413c8fbecb1204a218117c77a4ea4b3a211d5686ff99c31d82ba6dd0cec8c5a6"
IMAGE_ID="sha256:e90b8320f680a6a7b8daff87ad08cdf063a68d869880e662fd6d2cebfef689dc"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for file in "$PROFILE" "$VARIANTS"; do
  [ -r "$file" ] || fail "$file is not readable"
  bash -n "$file"
done
for file in "$DOWNLOAD" "$RUNTIME" "$FP8_RUN" "$BLACKFROST_RUN"; do
  [ -x "$file" ] || fail "$file is not executable"
  bash -n "$file"
done

contains "$PROFILE" 'MUSE_FP8_TARGET_REPO="RedHatAI/Muse-Glimmer-30B-FP8-block"'
contains "$PROFILE" "MUSE_FP8_TARGET_REV=\"$TARGET_REV\""
contains "$PROFILE" 'MUSE_FP8_DRAFT_REPO="meta-models/Muse-Glimmer-30B-assistant"'
contains "$PROFILE" "MUSE_FP8_DRAFT_REV=\"$DRAFT_REV\""
contains "$PROFILE" "MUSE_FP8_IMAGE_DIGEST=\"$IMAGE_DIGEST\""
contains "$PROFILE" "MUSE_FP8_IMAGE_ID=\"$IMAGE_ID\""
contains "$PROFILE" 'MUSE_FP8_SERVED_MODEL="muse-glimmer-30b-fp8"'
contains "$PROFILE" 'a7a144a0bfe2491c57e8f35e903a973777923879dfbe005642a4480a9dea94d8 28176516456 model-00001-of-00002.safetensors'
contains "$PROFILE" 'd532cf48fc25808b5f3fd5556cc2862705303d18362640796c43d2d51a3e44e0 6216318704 model-00002-of-00002.safetensors'
contains "$PROFILE" 'fd88d337eb84f8d0e6ba33a7684d7efa6722d4460ba4d6badca9699418392a84 5111976608 model.safetensors'
[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ [^ ]+$' "$PROFILE")" -eq 11 ] \
  || fail "profile must pin nine target and two draft runtime artifacts"

# shellcheck source=scripts/inference/muse/muse-glimmer-fp8-profile.sh
MUSE_FP8_MODELS_ROOT=/tmp/muse-fp8-contract source "$PROFILE"
[ "$MUSE_FP8_TARGET_HOST" = /tmp/muse-fp8-contract/checkpoints/target ] \
  || fail "target path does not honor the model-root boundary"
[ "$MUSE_FP8_DRAFT_HOST" = /tmp/muse-fp8-contract/checkpoints/dflash ] \
  || fail "draft path does not honor the model-root boundary"

contains "$VARIANTS" "MUSE_TARGET_REV=\"$BLACKFROST_REV\""
contains "$DOWNLOAD" 'export HF_HUB_DISABLE_XET=1'
contains "$DOWNLOAD" 'hf download "$repo" --revision "$revision" --local-dir "$directory"'
contains "$DOWNLOAD" 'inference_verify_checkpoint_manifest "$directory" "$manifest"'
contains "$DOWNLOAD" 'write_completion_marker "$directory" "$repo@$revision"'
contains "$DOWNLOAD" 'MUSE_FP8_DOWNLOAD_WORKER=yes'
contains "$DOWNLOAD" 'HF_TOKEN_PATH="$token_file"'
if grep -Eq 'pip install|docker run' "$DOWNLOAD"; then
  fail "download path must use only the Nix-managed Hugging Face client"
fi

contains "$RUNTIME" 'case "$TARGET_VARIANT" in'
contains "$RUNTIME" 'fp8)'
contains "$RUNTIME" 'blackfrost-bf16)'
contains "$RUNTIME" 'muse_resolve_variant blackfrost'
contains "$RUNTIME" 'MUSE_VLLM_TARGET must be fp8 or blackfrost-bf16'
contains "$RUNTIME" 'target-only|dflash'
contains "$RUNTIME" 'MUSE_VLLM_SPECULATION must be target-only or dflash'
contains "$RUNTIME" 'assert "MuseGlimmerForCausalLM" in supported'
contains "$RUNTIME" 'assert "MuseGlimmerAssistantModel" in supported'
contains "$RUNTIME" 'assert "DFlashMuseGlimmerAssistantModel" in supported'
contains "$RUNTIME" 'CUDA_VISIBLE_DEVICES=1'
contains "$RUNTIME" '--gpus "\"device=$GPU_DEVICE\""'
contains "$RUNTIME" '-e CUDA_VISIBLE_DEVICES=0'
contains "$RUNTIME" '--language-model-only'
contains "$RUNTIME" '--tensor-parallel-size 1'
contains "$RUNTIME" 'DEFAULT_GPU_MEMORY_UTILIZATION="0.62"'
contains "$RUNTIME" 'DEFAULT_GPU_MEMORY_UTILIZATION="0.82"'
contains "$RUNTIME" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"'
contains "$RUNTIME" '--speculative-config'
contains "$RUNTIME" '\"method\":\"dflash\"'
contains "$RUNTIME" '\"num_speculative_tokens\":15'
contains "$RUNTIME" '--tool-call-parser muse_glimmer'
contains "$RUNTIME" '--reasoning-parser muse_glimmer'
contains "$RUNTIME" '--host 127.0.0.1'
contains "$RUNTIME" '--env-file "$ENVFILE"'
contains "$RUNTIME" 'inference_prepare_api_key'
contains "$RUNTIME" 'MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"'
contains "$RUNTIME" 'MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"'
if grep -Eq -- '^[[:space:]]*--api-key([=[:space:]]|$)' "$RUNTIME"; then
  fail "runtime exposes the API key through process arguments"
fi

contains "$FP8_RUN" 'export MUSE_VLLM_TARGET=fp8'
contains "$FP8_RUN" 'export MUSE_VLLM_SPECULATION="${MUSE_FP8_SPECULATION:-target-only}"'
contains "$BLACKFROST_RUN" 'export MUSE_VLLM_TARGET=blackfrost-bf16'
contains "$BLACKFROST_RUN" 'export MUSE_VLLM_SPECULATION=dflash'
for wrapper in "$FP8_RUN" "$BLACKFROST_RUN"; do
  contains "$wrapper" 'exec "$SCRIPT_DIR/run-muse-glimmer-30b-vllm.sh" "$@"'
done

invalid_target=0
MUSE_VLLM_TARGET=unknown bash "$RUNTIME" >/dev/null 2>&1 || invalid_target=$?
[ "$invalid_target" -eq 2 ] || fail "runtime must reject an unsupported target before I/O"
invalid_speculation=0
MUSE_VLLM_SPECULATION=mtp bash "$RUNTIME" >/dev/null 2>&1 || invalid_speculation=$?
[ "$invalid_speculation" -eq 2 ] || fail "runtime must reject unsupported speculation"
invalid_gpu=0
GPU_DEVICE=2 bash "$RUNTIME" >/dev/null 2>&1 || invalid_gpu=$?
[ "$invalid_gpu" -eq 2 ] || fail "runtime must reject an invalid GPU before I/O"

printf 'PASS: Muse Glimmer vLLM target variants and DFlash are immutable, isolated, and credential-safe\n'
