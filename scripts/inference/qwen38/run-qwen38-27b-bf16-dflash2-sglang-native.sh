#!/usr/bin/env bash
# 2026-08-19: Qwen3.8-27B BF16 + REAL DFlash 2 draft on SGLang (TP2).
#
# This is the "make DFlash 2 actually work" profile: full BF16 (target body,
# lm_head, KV cache, and draft are all BF16 — NO FP8 anywhere), two GPUs
# (TP2), running the genuine DFlash 2 engine — DFlash2DraftModel +
# CandidateSelector + DFlashGroupedConv — from the merged upstream PR, not the
# degraded v1-class draft.
#
# Difference from run-qwen38-27b-bf16-dflash2-sglang.sh (the surgery sibling):
#   * That launcher DEFAULTS to the pre-merge fork image
#     (lmsysorg/sglang:qwen38-27b), whose registry only knows the DFlash *v1*
#     class. Serving the DFlash 2 checkpoint through it silently DROPS the 23
#     selector/conv tensors (lossless but crippled: ~2.0-2.7 acceptance vs the
#     card's 4.1-5.5). It reaches real DFlash 2 only if you override
#     DFLASH2_IMAGE *and* provide a matching registry DIGEST.
#   * A locally built, never-pushed image has NO registry digest, so the
#     sibling's mandatory IMAGE@DIGEST reference cannot address it at all.
#   * This launcher therefore defaults to the merge-commit build BY TAG
#     (peterstorm/sglang:qwen38-dflash2-c14312a, from PR sgl-project/sglang
#     #35371, merged 2026-08-19 as c14312a6), pins by digest only when one is
#     supplied, REQUIRES native DFlash2DraftModel registration (fails closed
#     otherwise — there is no surgery fallback here), and serves the canonical
#     downloaded tree as-is.
#
# Everything else matches the validated BF16 TP2 quality profile: FP32 GDN
# state, 262K context, eight running requests, the 08-17 mamba cookbook pin,
# flashinfer, checkpoint-native template, multimodal, secure entrypoint, key
# handling, GPU power-cap gate, crash-evidence archival.
#
# OpenAI-compatible endpoint on :8000, served model name qwen3.8-27b.
#
# Prerequisites:
#   scripts/inference/qwen38/download-qwen38-27b.sh         (target)
#   scripts/inference/qwen38/download-qwen38-27b-dflash2.sh (draft)
#   scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh (engine)
# Full rationale: docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

# Default to the PR #35371 merge-commit build (native DFlash 2), referenced by
# TAG so a locally built, never-pushed image resolves. Supply
# DFLASH2_NATIVE_IMAGE_DIGEST=sha256:... to pin once the image is pushed.
IMAGE="${DFLASH2_NATIVE_IMAGE:-peterstorm/sglang:qwen38-dflash2-c14312a}"
DIGEST="${DFLASH2_NATIVE_IMAGE_DIGEST:-}"
if [[ -n "$DIGEST" ]]; then
  IMAGE_REF="$IMAGE@$DIGEST"
else
  IMAGE_REF="$IMAGE"
fi
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
# Canonical draft tree: the download script's default (desktop user's Desktop
# folder). Resolved here so sudo invocations still point at the human's home.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  DFLASH2_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  DFLASH2_HOME="$HOME"
fi
# Native DFlash 2 serves the CANONICAL tree as-is (no surgery copy).
DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$DFLASH2_HOME/Desktop/Qwen3.8-27B-DFlash2}"
DRAFT_CONTAINER="/models/incoai/Qwen3.8-27B-DFlash2"
CACHE_HOST="/models/sglang-cache/qwen38-bf16-dflash2-native"
ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"
ENTRYPOINT_CONTAINER="/opt/reclaw/sglang-secure-entrypoint.py"
NAME="qwen38-27b-bf16-dflash2-sglang-native"

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
# DFlash 2 verify window: the checkpoint's dflash_config.block_size = 8
# (seven draft tokens per verification step plus the bonus position), per
# the model card's SGLang quick start (--speculative-num-draft-tokens 8).
DFLASH2_BLOCK_SIZE="${DFLASH2_BLOCK_SIZE:-8}"
# extra_buffer keeps five radix state slots per request. The 08-17 SGLang
# cookbook (PR #35064) documents the explicit pin as target_concurrency x S:
# the engine divides the state pool by S ALONE and sizes the speculative
# verify buffer separately, so folding the draft window into this pin
# over-provisions the GDN state pool and shrinks the KV pool.
MAMBA_STATE_SLOTS="${MAMBA_STATE_SLOTS:-5}"
MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))}"

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DFlash 2 checkpoint not found at $DRAFT_HOST — run scripts/inference/qwen38/download-qwen38-27b-dflash2.sh first" >&2
  exit 1
fi
if [ ! -f "$ENTRYPOINT_HOST" ]; then
  echo "error: secure SGLang entrypoint not found at $ENTRYPOINT_HOST" >&2
  exit 1
fi

# Fail closed: this profile REQUIRES native DFlash 2 (selector + convs). The
# pre-merge fork image's v1 DFlashDraftModel silently drops the 23 selector/
# conv tensors, defeating the entire point of this launcher. No surgery
# fallback — the sibling launcher owns that degraded path.
if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "error: image $IMAGE_REF is not present locally" >&2
  echo "build it: bash scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh" >&2
  exit 1
fi
if ! docker run --rm --entrypoint python3 "$IMAGE_REF" \
     -c "import sglang.srt.models.dflash as m; raise SystemExit(0 if hasattr(m, 'DFlash2DraftModel') else 1)" >/dev/null 2>&1; then
  echo "error: $IMAGE_REF does not register DFlash2DraftModel natively" >&2
  echo "this profile has no surgery fallback (the v1 class drops the selector/convs)." >&2
  echo "build the PR #35371 merge-commit image: bash scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh" >&2
  echo "or use the surgery sibling for the degraded v1 path: run-qwen38-27b-bf16-dflash2-sglang.sh" >&2
  exit 1
fi
echo "Image registers DFlash2DraftModel natively — serving the canonical DFlash 2 tree (no surgery)."

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
ENVFILE="$CONFIG_DIR/sglang-dflash2-native.env"

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
  "$IMAGE_REF" \
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

echo "Started '$NAME' with CUDA_VISIBLE_DEVICES=$GPU_ORDER (logical device 0 / TP rank 0 is listed first)."
echo "Full BF16 (no FP8), TP2, native DFlash 2 (real selector + convs)."
echo "This is an experimental profile; first start compiles kernels and CUDA graphs."
echo "Follow:  docker logs -f $NAME"
echo "Health/auth:  curl -fsS http://127.0.0.1:8000/health  (key: $KEYFILE)"
echo "Verify spec decode is actually drafting (real DFlash 2 acceptance near 4.1-5.5;"
echo "the crippled v1 sibling caps ~2.0-2.7; near 1.0 means miswired):"
echo "  curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head -4"
echo "Switch in/out of this profile without editing anything:"
echo "  bash $SCRIPT_DIR/switch-qwen38-backend-v2.sh dflash2-native"
