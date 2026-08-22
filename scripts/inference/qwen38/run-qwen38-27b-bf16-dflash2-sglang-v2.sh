#!/usr/bin/env bash
# Launch the official SGLang Qwen3.8-27B BF16 + DFlash2 RTX PRO 6000 profile.
#
# This is intentionally separate from the locally validated TP2/native launcher.
# It follows the official 2026-08-22 cookbook cell: one RTX PRO 6000, BF16 target
# and draft weights, FP8 E4M3 KV, FP32 GDN state, FlashInfer, 2K prefill chunks,
# native DFlash2 block size 8, and SGLang's official DFlash2 image pinned by digest.
# The selected physical GPU defaults to GPU1 because this workstation's GPU0 is
# the hardware-diagnostic card. OpenAI-compatible endpoint: :8000.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

IMAGE="lmsysorg/sglang:dev-qwen38-27b-dflash2"
IMAGE_DIGEST="sha256:616a3e97f45191af975896cfa644279096cb31bd408a071c2e99ca7209c3cafe"
IMAGE_SOURCE_SHA="5f55db35e926d50676f75b812640ea2410b0fe0e"
IMAGE_REF="$IMAGE@$IMAGE_DIGEST"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$INFERENCE_OPERATOR_HOME/Desktop/Qwen3.8-27B-DFlash2}"
DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"
CACHE_HOST="/models/sglang-cache/qwen38-bf16-dflash2-official-v2"
ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"
ENTRYPOINT_CONTAINER="/opt/reclaw/sglang-secure-entrypoint.py"
NAME="qwen38-27b-bf16-dflash2-sglang-v2"

GPU_DEVICE="${GPU_DEVICE:-1}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"
CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8_e4m3}"
MAMBA_SSM_DTYPE="${MAMBA_SSM_DTYPE:-float32}"
MAMBA_STATE_SLOTS=5
DFLASH2_BLOCK_SIZE=8
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
CONTAINER_ARCHIVE_DIR="${CONTAINER_ARCHIVE_DIR:-$INFERENCE_OPERATOR_HOME/.local/state/qwen38/container-archives}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-14}"
ARCHIVE_MAX_COUNT="${ARCHIVE_MAX_COUNT:-20}"

case "$GPU_DEVICE" in
  0|1) ;;
  *) echo "error: GPU_DEVICE must be 0 or 1 (got: $GPU_DEVICE)" >&2; exit 2 ;;
esac
case "$KV_CACHE_DTYPE" in
  fp8_e4m3|bfloat16) ;;
  *) echo "error: KV_CACHE_DTYPE must be fp8_e4m3 or bfloat16 (got: $KV_CACHE_DTYPE)" >&2; exit 2 ;;
esac
case "$MAMBA_SSM_DTYPE" in
  float32|bfloat16) ;;
  *) echo "error: MAMBA_SSM_DTYPE must be float32 or bfloat16 (got: $MAMBA_SSM_DTYPE)" >&2; exit 2 ;;
esac
for numeric in MAX_RUNNING_REQUESTS CONTEXT_LENGTH CHUNKED_PREFILL_SIZE MAX_GPU_POWER_LIMIT \
  MAX_EXISTING_GPU_MEMORY_MIB ARCHIVE_RETENTION_DAYS ARCHIVE_MAX_COUNT; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done
if ! [[ "$MEM_FRACTION_STATIC" =~ ^0[.][0-9]+$ ]] \
  || ! awk -v value="$MEM_FRACTION_STATIC" 'BEGIN { exit !(value > 0 && value < 1) }'; then
  echo "error: MEM_FRACTION_STATIC must be a decimal between 0 and 1 (got: $MEM_FRACTION_STATIC)" >&2
  exit 2
fi
if [ "$CONTEXT_LENGTH" -gt 262144 ]; then
  echo "error: CONTEXT_LENGTH exceeds the checkpoint-native 262144-token contract" >&2
  exit 2
fi
MAX_MAMBA_CACHE_SIZE=$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DFlash2 checkpoint not found at $DRAFT_HOST — run scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh first" >&2
  exit 1
fi
command -v jq >/dev/null 2>&1 || { echo "error: jq is required" >&2; exit 1; }
if [ ! -f "$DRAFT_HOST/model.safetensors" ] \
  || [ "$(stat -c %s "$DRAFT_HOST/model.safetensors")" != 3848817896 ]; then
  echo "error: DFlash2 model.safetensors is missing or has the wrong size" >&2
  exit 1
fi
if ! jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' \
  "$DRAFT_HOST/config.json" >/dev/null 2>&1; then
  echo "error: $DRAFT_HOST is not the pinned native DFlash2 checkpoint" >&2
  exit 1
fi
if [ ! -f "$ENTRYPOINT_HOST" ]; then
  echo "error: secure SGLang entrypoint not found at $ENTRYPOINT_HOST" >&2
  exit 1
fi

if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "error: official image is not present: $IMAGE_REF" >&2
  echo "pull it with: docker pull '$IMAGE_REF'" >&2
  exit 1
fi
actual_source_sha="$(docker image inspect --format '{{index .Config.Labels "ai.sglang.build.commit"}}' "$IMAGE_REF")"
if [ "$actual_source_sha" != "$IMAGE_SOURCE_SHA" ]; then
  echo "error: $IMAGE_REF source label is $actual_source_sha, expected $IMAGE_SOURCE_SHA" >&2
  exit 1
fi
if ! docker run --rm --entrypoint python3 "$IMAGE_REF" -c '
import sglang.srt.models.dflash as d
required = ("DFlash2DraftModel", "CandidateSelector", "DFlashGroupedConv")
raise SystemExit(0 if all(hasattr(d, name) for name in required) else 1)
' >/dev/null 2>&1; then
  echo "error: $IMAGE_REF lacks the official native DFlash2 implementation" >&2
  exit 1
fi

gpu_state="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=power.limit,memory.used --format=csv,noheader,nounits 2>/dev/null)" || {
  echo "error: physical GPU $GPU_DEVICE is not queryable" >&2
  exit 3
}
IFS=',' read -r power_cap memory_used <<<"$gpu_state"
power_cap="${power_cap//[[:space:]]/}"
memory_used="${memory_used//[[:space:]]/}"
if ! [[ "$power_cap" =~ ^[0-9]+([.][0-9]+)?$ && "$memory_used" =~ ^[0-9]+$ ]]; then
  echo "error: could not parse GPU $GPU_DEVICE state: $gpu_state" >&2
  exit 3
fi
if awk -v cap="$power_cap" -v maximum="$MAX_GPU_POWER_LIMIT" 'BEGIN { exit !(cap > maximum) }'; then
  echo "error: GPU $GPU_DEVICE cap is ${power_cap}W; profile maximum is ${MAX_GPU_POWER_LIMIT}W" >&2
  exit 3
fi
if [ "$memory_used" -gt "$MAX_EXISTING_GPU_MEMORY_MIB" ]; then
  echo "error: GPU $GPU_DEVICE already uses ${memory_used} MiB (limit: ${MAX_EXISTING_GPU_MEMORY_MIB} MiB)" >&2
  exit 3
fi

inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"
SGLANG_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/sglang-dflash2-official-v2.env"
inference_write_private_file "$ENVFILE" <<EOF
SGLANG_API_KEY=$SGLANG_API_KEY
EOF

if [ ! -d "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

if docker container inspect "$NAME" >/dev/null 2>&1; then
  archive_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  inference_install_private_dir "$CONTAINER_ARCHIVE_DIR"
  archive_base="$CONTAINER_ARCHIVE_DIR/$archive_stamp-$NAME"
  docker inspect --format='id={{.Id}} created={{.Created}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} image={{.Config.Image}}' \
    "$NAME" >"$archive_base.metadata"
  docker logs --timestamps "$NAME" 2>&1 | gzip -1 >"$archive_base.log.gz" || \
    echo "warning: container log archive was incomplete: $archive_base.log.gz" >&2
  inference_secure_operator_file "$archive_base.metadata"
  inference_secure_operator_file "$archive_base.log.gz"
fi
if [ -d "$CONTAINER_ARCHIVE_DIR" ]; then
  find "$CONTAINER_ARCHIVE_DIR" -maxdepth 1 -type f \
    \( -name '*.metadata' -o -name '*.log.gz' \) \
    -mtime "+$ARCHIVE_RETENTION_DAYS" -delete
  mapfile -t old_archives < <(find "$CONTAINER_ARCHIVE_DIR" -maxdepth 1 -type f -name "*-$NAME.log.gz" -printf '%p\n' | sort)
  if [ "${#old_archives[@]}" -gt "$ARCHIVE_MAX_COUNT" ]; then
    remove_count=$((${#old_archives[@]} - ARCHIVE_MAX_COUNT))
    for ((index = 0; index < remove_count; index++)); do
      archive_base="${old_archives[$index]%.log.gz}"
      rm -f "$archive_base.log.gz" "$archive_base.metadata"
    done
  fi
fi

docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.physical-gpu="$GPU_DEVICE" \
  --label io.peterstorm.inference.release="official-dflash2-v2" \
  --gpus "\"device=$GPU_DEVICE\"" \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  -v "$DRAFT_HOST":"$DRAFT_CONTAINER":ro \
  -v "$CACHE_HOST":/root/.cache \
  -v "$ENTRYPOINT_HOST":"$ENTRYPOINT_CONTAINER":ro \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  "$IMAGE_REF" \
  python3 "$ENTRYPOINT_CONTAINER" \
  --model-path "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --trust-remote-code \
  --enable-multimodal \
  --dtype bfloat16 \
  --tp-size 1 \
  --context-length "$CONTEXT_LENGTH" \
  --max-running-requests "$MAX_RUNNING_REQUESTS" \
  --chunked-prefill-size "$CHUNKED_PREFILL_SIZE" \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --kv-cache-dtype "$KV_CACHE_DTYPE" \
  --mamba-ssm-dtype "$MAMBA_SSM_DTYPE" \
  --mamba-radix-cache-strategy extra_buffer \
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE" \
  --attention-backend flashinfer \
  --cuda-graph-max-bs-decode "$MAX_RUNNING_REQUESTS" \
  --speculative-algorithm DFLASH \
  --speculative-draft-model-path "$DRAFT_CONTAINER" \
  --speculative-num-draft-tokens "$DFLASH2_BLOCK_SIZE" \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --sampling-defaults model \
  --enable-cache-report \
  --enable-metrics \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME' on physical GPU $GPU_DEVICE with official DFlash2 image $IMAGE_DIGEST."
echo "Profile: BF16 weights, $KV_CACHE_DTYPE KV, $MAMBA_SSM_DTYPE GDN state, TP1, DFlash2 width 8."
echo "Follow:  docker logs -f $NAME"
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Metrics: curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head"
