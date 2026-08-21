#!/usr/bin/env bash
# Launch a Muse Glimmer 30B BF16 variant with lossless DFlash on one RTX PRO 6000.
#
# MUSE_VARIANT=standard selects upstream; abliterated selects the pinned mlasli
# BF16 derivative. DFlash remains output-exact, although draft acceptance and
# therefore speed must be qualified independently for the modified target. This
# is the text-only half of the creative profile. It disables perception and
# exposes an authenticated OpenAI-compatible endpoint on :8001 by default.
#
# Prerequisite: scripts/inference/muse/download-muse-glimmer-30b.sh
# Full rationale: docs/runbooks/new-desktop-install.md —
# "Muse Glimmer BF16 + DFlash beside Qwen".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/muse-glimmer-variant.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
inference_resolve_operator
muse_resolve_variant "${MUSE_VARIANT:-standard}"

IMAGE="lmsysorg/sglang:nightly-dev-cu13-20260816-4a6dc267"
DIGEST="sha256:0d73f8dd82c8adbbe481d8520cb6d62d80828f1e62267ee41a3c67cf3dd77528"
ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"
ENTRYPOINT_CONTAINER="/opt/reclaw/sglang-secure-entrypoint.py"
GPU_DEVICE="${GPU_DEVICE:-0}"
PORT="${PORT:-8001}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-131072}"
MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-4}"
CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
MAX_EXISTING_GPU_MEMORY_MIB="${MAX_EXISTING_GPU_MEMORY_MIB:-2048}"
STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-1800}"

case "$GPU_DEVICE" in
  0|1) ;;
  *) echo "error: GPU_DEVICE must be 0 or 1 (got: $GPU_DEVICE)" >&2; exit 2 ;;
esac
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || ((PORT < 1024 || PORT > 65535)); then
  echo "error: PORT must be an integer from 1024 through 65535 (got: $PORT)" >&2
  exit 2
fi
for numeric in CONTEXT_LENGTH MAX_RUNNING_REQUESTS CHUNKED_PREFILL_SIZE MAX_GPU_POWER_LIMIT MAX_EXISTING_GPU_MEMORY_MIB STARTUP_TIMEOUT_SECONDS; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done

download_hint="run MUSE_VARIANT=$MUSE_VARIANT scripts/inference/muse/download-muse-glimmer-30b.sh and wait for DOWNLOAD_COMPLETE"
inference_require_pinned_checkpoint "$MUSE_TARGET_HOST" "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" "$download_hint"
inference_require_pinned_checkpoint "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV" "$download_hint"
if [ ! -f "$ENTRYPOINT_HOST" ]; then
  echo "error: secure SGLang entrypoint not found at $ENTRYPOINT_HOST" >&2
  exit 1
fi

# Remove this profile's previous instance before checking whether another model
# still owns the selected card. This preserves idempotent relaunches while
# refusing an accidental launch beside a TP2 server.
inference_remove_container_if_present "$MUSE_CONTAINER_NAME"
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
  echo "apply the NixOS power-limit configuration before launching" >&2
  exit 3
fi
if ((memory_used > MAX_EXISTING_GPU_MEMORY_MIB)); then
  echo "error: GPU $GPU_DEVICE already uses ${memory_used} MiB (limit: ${MAX_EXISTING_GPU_MEMORY_MIB} MiB)" >&2
  echo "stop the TP2/exclusive inference server before launching Muse directly" >&2
  exit 3
fi
echo "Verified physical GPU $GPU_DEVICE is available and capped at <= ${MAX_GPU_POWER_LIMIT}W."

inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"
SGLANG_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/muse-glimmer"
KEYFILE="$INFERENCE_MUSE_KEYFILE"
ENVFILE="$CONFIG_DIR/container.env"
inference_install_private_dir "$CONFIG_DIR"
inference_write_private_file "$ENVFILE" <<EOF
SGLANG_API_KEY=$SGLANG_API_KEY
EOF

if [ ! -d "$MUSE_CACHE_HOST" ]; then
  sudo mkdir -p "$MUSE_CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$MUSE_CACHE_HOST"
fi
inference_require_cache_access "$MUSE_CACHE_HOST"

if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :$PORT" | grep -q .; then
  echo "error: TCP port $PORT is already in use" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$MUSE_CONTAINER_NAME" \
  --label io.peterstorm.inference.physical-gpu="$GPU_DEVICE" \
  --label io.peterstorm.inference.muse-variant="$MUSE_VARIANT" \
  --gpus "\"device=$GPU_DEVICE\"" \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MUSE_TARGET_HOST":"$MUSE_TARGET_CONTAINER":ro \
  -v "$MUSE_DRAFT_HOST":"$MUSE_DRAFT_CONTAINER":ro \
  -v "$MUSE_CACHE_HOST":/root/.cache \
  -v "$ENTRYPOINT_HOST":"$ENTRYPOINT_CONTAINER":ro \
  -e CUDA_VISIBLE_DEVICES=0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  "$IMAGE@$DIGEST" \
  python3 "$ENTRYPOINT_CONTAINER" \
  --model-path "$MUSE_TARGET_CONTAINER" \
  --served-model-name muse-glimmer-30b \
  --dtype bfloat16 \
  --tp-size 1 \
  --context-length "$CONTEXT_LENGTH" \
  --max-running-requests "$MAX_RUNNING_REQUESTS" \
  --chunked-prefill-size "$CHUNKED_PREFILL_SIZE" \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --language-model-only \
  --speculative-algorithm DFLASH \
  --speculative-draft-model-path "$MUSE_DRAFT_CONTAINER" \
  --reasoning-parser muse \
  --tool-call-parser muse \
  --sampling-defaults model \
  --enable-cache-report \
  --enable-metrics \
  --host 0.0.0.0 \
  --port "$PORT"

muse_healthy() {
  printf 'silent\nshow-error\nfail\noutput = "/dev/null"\nurl = "http://127.0.0.1:%s/health"\nheader = "Authorization: Bearer %s"\n' \
    "$PORT" "$SGLANG_API_KEY" | curl --config -
}

started_at="$(date +%s)"
while ! muse_healthy; do
  if [ "$(docker inspect --format '{{.State.Running}}' "$MUSE_CONTAINER_NAME" 2>/dev/null || true)" != true ]; then
    echo "error: $MUSE_CONTAINER_NAME exited during startup" >&2
    docker logs --tail 100 "$MUSE_CONTAINER_NAME" >&2 2>/dev/null || true
    docker update --restart=no "$MUSE_CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
  if (( $(date +%s) - started_at >= STARTUP_TIMEOUT_SECONDS )); then
    echo "error: Muse did not become healthy within ${STARTUP_TIMEOUT_SECONDS}s" >&2
    docker logs --tail 100 "$MUSE_CONTAINER_NAME" >&2 2>/dev/null || true
    docker update --restart=no "$MUSE_CONTAINER_NAME" >/dev/null 2>&1 || true
    docker stop -t 30 "$MUSE_CONTAINER_NAME" >/dev/null 2>&1 || true
    exit 1
  fi
  sleep 5
done

echo "MUSE_READY: '$MUSE_CONTAINER_NAME' on physical GPU $GPU_DEVICE at :$PORT."
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
