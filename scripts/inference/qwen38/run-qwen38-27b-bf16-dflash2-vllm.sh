#!/usr/bin/env bash
# 2026-08-19: Qwen3.8-27B BF16 + Inco DFlash 2 draft on vLLM (TP2).
#
# Experimental profile: the image is built from vLLM PR #52816 (head
# 19c93519, base main@9842d701) via build-qwen38-dflash2-vllm-image.sh —
# the PR is unmerged, so this is unreviewed engine code. The card's
# benchmark numbers are SGLang-only; treat first numbers as exploratory.
#
# Differences from the DSpark-on-vLLM v2 launcher
# (run-qwen38-27b-bf16-dspark-vllm-v2.sh), which this profile mirrors:
#   * Draft: z-lab/Qwen3.8-27B-DFlash2 (block diffusion + candidate
#     selector), block size 8 -> num_speculative_tokens 7 per the card.
#   * NO draft-config surgery: the PR image registers
#     DFlash2DraftModel natively ("DFlash2DraftModel": ("qwen3_dflash2",
#     "DFlash2Qwen3ForCausalLM") in models/registry.py) and
#     config/vllm.py::_is_dflash2_draft() selects the DFlash2Speculator
#     from the checkpoint's own architectures — the canonical Desktop
#     tree is mounted as-is.
#   * Separate cache root (/models/vllm-cache/qwen38-bf16-dflash2) so the
#     DSpark profile's tree is never touched.
#   * Power-cap guard cloned from the SGLang DFlash 2 launcher (fail
#     closed above the 450 W declared in machines/desktop/default.nix).
#
# Same target quality profile as the rest of the family: BF16
# weights/KV, FP32 GDN state, 262K context, eight scheduler slots,
# flashinfer, checkpoint-native template, card sampling (temp 1.0,
# top_p 0.95, top_k 20, xhigh). OpenAI-compatible endpoint on :8000.
#
# Prerequisites:
#   scripts/inference/qwen38/download-qwen38-27b.sh
#   scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
#   scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh
# Full rationale: docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md —
# "vLLM via the PR branch".
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_resolve_operator

# Image from the pinned PR head. Two ways to get it locally:
#   * build it here: build-qwen38-dflash2-vllm-image.sh, or
#   * build it in GitHub Actions (.github/workflows/build-dflash2-vllm-image.yml)
#     and pull it: pull-qwen38-dflash2-images.sh vllm (re-tags GHCR -> this tag).
# Override DFLASH2_VLLM_IMAGE to point straight at GHCR without re-tagging;
# pass DFLASH2_VLLM_IMAGE_DIGEST to pin by digest once the build verifies.
IMAGE="${DFLASH2_VLLM_IMAGE:-peterstorm/vllm:qwen38-dflash2-pr52816-19c9351}"
DIGEST="${DFLASH2_VLLM_IMAGE_DIGEST:-}"
IMAGE_REF="${IMAGE}${DIGEST:+@$DIGEST}"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
# Canonical draft tree: the download script's default (desktop user's Desktop
# folder). Resolved here so sudo invocations still point at the human's home.
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != root ]]; then
  DFLASH2_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  DFLASH2_HOME="$HOME"
fi
DRAFT_HOST="${DFLASH2_DRAFT_HOST:-$DFLASH2_HOME/Desktop/Qwen3.8-27B-DFlash2}"
DRAFT_CONTAINER="/models/z-lab/Qwen3.8-27B-DFlash2"
CACHE_HOST="/models/vllm-cache/qwen38-bf16-dflash2"
NAME="qwen38-27b-bf16-dflash2-vllm"
# DFlash 2: block size 8 (checkpoint dflash_config.block_size) = seven draft
# tokens per verification step plus the bonus position, per the card's vLLM
# quick start.
DFLASH2_NUM_SPEC_TOKENS="${DFLASH2_NUM_SPEC_TOKENS:-7}"

MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
MAX_GPU_POWER_LIMIT="${MAX_GPU_POWER_LIMIT:-450}"
for numeric in DFLASH2_NUM_SPEC_TOKENS MAX_GPU_POWER_LIMIT; do
  value="${!numeric}"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: $numeric must be a positive integer (got: $value)" >&2
    exit 2
  fi
done

if ! docker image inspect "$IMAGE_REF" >/dev/null 2>&1; then
  echo "error: image $IMAGE_REF not found locally" >&2
  echo "build it:  bash $SCRIPT_DIR/build-qwen38-dflash2-vllm-image.sh" >&2
  echo "or pull it (built in CI): bash $SCRIPT_DIR/pull-qwen38-dflash2-images.sh vllm" >&2
  exit 1
fi
if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/inference/qwen38/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DFlash 2 checkpoint not found at $DRAFT_HOST — run scripts/inference/qwen38/download-qwen38-27b-dflash2.sh first" >&2
  exit 1
fi
if ! jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' "$DRAFT_HOST/config.json" >/dev/null 2>&1; then
  echo "error: $DRAFT_HOST/config.json is not the pinned DFlash 2 checkpoint (architectures/dflash_config changed)" >&2
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
inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/vllm-dflash2.env"

# Keep the key out of Docker's command arguments and the host process list.
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

if [ ! -d "$CACHE_HOST" ]; then
  sudo mkdir -p "$CACHE_HOST"
  sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$CACHE_HOST"
fi
inference_require_cache_access "$CACHE_HOST"

# Make relaunch idempotent, then reject a different server already owning :8000
# (typically the SGLang DFlash 2 container — stop it first via the switcher).
docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --label io.peterstorm.inference.gpu-order="0,1" \
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
  -e CUDA_VISIBLE_DEVICES=1,0 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE_REF" \
  "$MODEL_CONTAINER" \
  --served-model-name qwen3.8-27b \
  --dtype bfloat16 \
  --tensor-parallel-size 2 \
  --max-model-len "$MAX_MODEL_LEN" \
  --max-num-seqs "$MAX_NUM_SEQS" \
  --max-num-batched-tokens "$MAX_NUM_BATCHED_TOKENS" \
  --gpu-memory-utilization "$GPU_MEMORY_UTILIZATION" \
  --kv-cache-dtype auto \
  --mamba-ssm-cache-dtype float32 \
  --enable-prefix-caching \
  --enable-chunked-prefill \
  --speculative-config "{\"method\":\"dflash\",\"model\":\"$DRAFT_CONTAINER\",\"num_speculative_tokens\":$DFLASH2_NUM_SPEC_TOKENS}" \
  --attention-backend flashinfer \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME' (vLLM PR #52816 + DFlash 2, TP2, num_speculative_tokens $DFLASH2_NUM_SPEC_TOKENS)."
echo "First start compiles kernels and CUDA graphs and may take several minutes."
echo "Follow:  docker logs -f $NAME"
echo "  - the draft's 'Resolved architecture:' line must resolve to the DFlash 2 implementation"
echo "    (qwen3_dflash2 / DFlash2Qwen3ForCausalLM), not a DFlash 1 fallback"
echo "  - watch vllm:spec_decode_* counters; the card claims 4.1-5.5 acceptance,"
echo "    DSpark measured ~3.4 on this box; near 1.0 means miswired draft."
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Switch in/out via: bash $SCRIPT_DIR/switch-qwen38-backend-v2.sh dflash2-vllm"
