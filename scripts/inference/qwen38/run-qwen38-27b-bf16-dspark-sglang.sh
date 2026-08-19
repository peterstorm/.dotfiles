#!/usr/bin/env bash
# Launch the experimental Qwen3.8-27B BF16 + DSpark profile with SGLang.
#
# Quality-first target: TP2 BF16 weights/KV, FP32 GDN state, native 262K
# context, eight running requests, checkpoint-native template, the pinned
# 1.36B BF16 DSpark draft, and the full multimodal checkpoint (vision enabled).
# Static verification is mandatory for this TP2 probe.
# OpenAI-compatible endpoint on :8000.
#
# Prerequisites:
#   scripts/inference/qwen38/download-qwen38-27b.sh
#   scripts/inference/qwen38/download-qwen38-27b-dspark.sh
# Full rationale: docs/runbooks/new-desktop-install.md —
# "Experimental Qwen3.8-27B DSpark on SGLang".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

IMAGE="lmsysorg/sglang:qwen38-27b"
DIGEST="sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
DRAFT_HOST="/models/Qwen3.8-27B-DSpark"
DRAFT_CONTAINER="/models/RadixArk/Qwen3.8-27B-DSpark"
CACHE_HOST="/models/sglang-cache/qwen38-bf16-dspark"
ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"
ENTRYPOINT_CONTAINER="/opt/reclaw/sglang-secure-entrypoint.py"
NAME="qwen38-27b-bf16-dspark-sglang"

MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"
CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"
# Diagnostic knob: CUDA logical device 0 becomes TP rank 0. Reversing this
# order distinguishes a rank-0 runtime failure from a physical GPU0 failure.
GPU_ORDER="${GPU_ORDER:-1,0}"
case "$GPU_ORDER" in
  0,1|1,0) ;;
  *) echo "error: GPU_ORDER must be 0,1 or 1,0 (got: $GPU_ORDER)" >&2; exit 2 ;;
esac
CONTAINER_ARCHIVE_DIR="${CONTAINER_ARCHIVE_DIR:-$INFERENCE_OPERATOR_HOME/.local/state/qwen38/container-archives}"
ARCHIVE_RETENTION_DAYS="${ARCHIVE_RETENTION_DAYS:-14}"
ARCHIVE_MAX_COUNT="${ARCHIVE_MAX_COUNT:-20}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
for numeric in ARCHIVE_RETENTION_DAYS ARCHIVE_MAX_COUNT MAX_GPU_POWER_LIMIT; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done
CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"
MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"
DSPARK_GAMMA="${DSPARK_GAMMA:-7}"
# extra_buffer keeps five radix state slots per request; static DSpark gamma=7
# needs an eight-state verify window. The explicit pin prevents SGLang's default
# Mamba/KV ratio from silently reducing the requested concurrency.
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * (5 + DSPARK_GAMMA + 1)))}"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DSpark checkpoint not found at $DRAFT_HOST — run scripts/inference/qwen38/download-qwen38-27b-dspark.sh first" >&2
  exit 1
fi
if [ ! -f "$ENTRYPOINT_HOST" ]; then
  echo "error: secure SGLang entrypoint not found at $ENTRYPOINT_HOST" >&2
  exit 1
fi

# Fail closed: never start this high-load profile above its declared power cap
# (matches gpuPowerLimitWatts in machines/desktop/default.nix). Override
# MAX_GPU_POWER_LIMIT to change the cap.
mapfile -t gpu_caps < <(nvidia-smi --query-gpu=index,power.limit --format=csv,noheader,nounits 2>/dev/null)
if [ "${#gpu_caps[@]}" -ne 2 ]; then
  echo "error: expected two queryable GPUs before launch; found ${#gpu_caps[@]}" >&2
  exit 3
fi
for record in "${gpu_caps[@]}"; do
  IFS=',' read -r gpu_index gpu_cap <<< "$record"
  gpu_index="${gpu_index//[[:space:]]/}"
  gpu_cap="${gpu_cap//[[:space:]]/}"
  if ! [[ "$gpu_index" =~ ^[0-9]+$ && "$gpu_cap" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    echo "error: could not parse GPU power-cap record: $record" >&2
    exit 3
  fi
  if awk -v cap="$gpu_cap" -v maximum="$MAX_GPU_POWER_LIMIT" 'BEGIN { exit !(cap > maximum) }'; then
    echo "error: GPU $gpu_index cap is ${gpu_cap}W; declared maximum is ${MAX_GPU_POWER_LIMIT}W" >&2
    echo "apply the NixOS power-limit configuration before launching" >&2
    exit 3
  fi
done
echo "Verified both GPU power caps are <= ${MAX_GPU_POWER_LIMIT}W."

# Resolve the human operator even under `sudo`, then synchronize all model-specific
# key paths to one credential. This prevents a root-only key from
# silently replacing the credential Pi retrieves as the desktop user.
inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"
SGLANG_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/sglang-dspark.env"

# SGLang has no native API-key environment variable. A tiny Python entrypoint
# parses this value in-process so it never appears in Docker args or /proc cmdline.
inference_write_private_file "$ENVFILE" <<EOF
SGLANG_API_KEY=$SGLANG_API_KEY
EOF

# First launch may need privilege to create the ZFS-backed cache root. Once it
# exists, relaunches (including the download-completion user unit) stay unprivileged.
if [ ! -d "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

# Preserve crash evidence before docker rm destroys the old container log. The
# metadata deliberately excludes Config.Env because it contains the API key.
if docker container inspect "$NAME" >/dev/null 2>&1; then
  archive_stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  inference_install_private_dir "$CONTAINER_ARCHIVE_DIR"
  archive_base="$CONTAINER_ARCHIVE_DIR/$archive_stamp"
  {
    docker inspect --format='id={{.Id}} created={{.Created}} started={{.State.StartedAt}} finished={{.State.FinishedAt}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}} image={{.Config.Image}}' "$NAME"
    docker inspect --format='{{range .Config.Env}}{{println .}}{{end}}' "$NAME" | grep '^CUDA_VISIBLE_DEVICES=' || true
  } > "$archive_base.metadata"
  if ! docker logs --timestamps "$NAME" 2>&1 | gzip -1 > "$archive_base.log.gz"; then
    echo "warning: container log archive was incomplete: $archive_base.log.gz" >&2
  fi
  inference_secure_operator_file "$archive_base.metadata"
  inference_secure_operator_file "$archive_base.log.gz"
  echo "Archived previous container evidence to $archive_base.{metadata,log.gz}"
fi

if [ -d "$CONTAINER_ARCHIVE_DIR" ]; then
  find "$CONTAINER_ARCHIVE_DIR" -maxdepth 1 -type f \
    \( -name '*.metadata' -o -name '*.log.gz' \) \
    -mtime "+$ARCHIVE_RETENTION_DAYS" -delete
  shopt -s nullglob
  archives=("$CONTAINER_ARCHIVE_DIR"/*.log.gz)
  if [ "${#archives[@]}" -gt "$ARCHIVE_MAX_COUNT" ]; then
    mapfile -t archives < <(printf '%s\n' "${archives[@]}" | sort)
    remove_count=$((${#archives[@]} - ARCHIVE_MAX_COUNT))
    for ((archive_index = 0; archive_index < remove_count; archive_index++)); do
      archive_base="${archives[$archive_index]%.log.gz}"
      rm -f "$archive_base.log.gz" "$archive_base.metadata"
    done
  fi
  shopt -u nullglob
fi

docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.gpu-order="$GPU_ORDER" \
  --gpus all \
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
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e SGLANG_RAGGED_VERIFY_MODE=static \
  "$IMAGE@$DIGEST" \
  python3 "$ENTRYPOINT_CONTAINER" \
  --model-path "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --trust-remote-code \
  --enable-multimodal \
  --dtype bfloat16 \
  --tp-size 2 \
  --context-length "$CONTEXT_LENGTH" \
  --max-running-requests "$MAX_RUNNING_REQUESTS" \
  --chunked-prefill-size "$CHUNKED_PREFILL_SIZE" \
  --mem-fraction-static "$MEM_FRACTION_STATIC" \
  --kv-cache-dtype bfloat16 \
  --mamba-ssm-dtype float32 \
  --mamba-radix-cache-strategy extra_buffer \
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE" \
  --attention-backend flashinfer \
  --cuda-graph-max-bs-decode "$MAX_RUNNING_REQUESTS" \
  --speculative-algorithm DSPARK \
  --speculative-draft-model-path "$DRAFT_CONTAINER" \
  --speculative-draft-model-quantization unquant \
  --speculative-dspark-block-size "$DSPARK_GAMMA" \
  --reasoning-parser qwen3 \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --sampling-defaults model \
  --enable-cache-report \
  --enable-metrics \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME' with CUDA_VISIBLE_DEVICES=$GPU_ORDER (logical device 0 / TP rank 0 is listed first)."
echo "This is an experimental profile; first start compiles kernels and CUDA graphs."
echo "Follow:  docker logs -f $NAME"
echo "Health/auth:  bash $SCRIPT_DIR/switch-qwen38-backend.sh status"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Compare acceptance/throughput in logs before promoting it over the no-spec BF16 baseline."
