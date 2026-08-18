#!/usr/bin/env bash
# Experimental: Qwen3.8-27B BF16 + RadixArk DSpark draft on vLLM (TP2).
#
# Same target quality profile as scripts/run-qwen38-27b-bf16.sh (BF16 weights/KV,
# FP32 GDN state, 262K context, eight scheduler slots, prefix caching) plus the
# 1.36B BF16 DSpark draft (block size 7) as a separate draft model — the vLLM
# equivalent of the SGLang DSpark profile, for engine A/B at identical draft/target.
# OpenAI-compatible endpoint on :8000.
#
# Verified 2026-08-16 against the vLLM source (see docs/new-desktop-install.md,
# "Experimental Qwen3.8-27B DSpark on vLLM"):
#   * The draft ships `"architectures": ["DSparkDraftModel"]`, which vLLM's
#     registry maps to the DeepSeek-V4 DSpark implementation that reads
#     DeepSeek-only fields (`config.hc_mult`) and crashes on this Qwen3Config.
#     The Qwen path is selected by the `Qwen3DSparkModel` architecture string,
#     so this script prepares a vLLM-only copy of the draft with that one field
#     rewritten. The SGLang copy at /models/Qwen3.8-27B-DSpark is never touched.
#   * The pinned image is an UPSTREAM commit (ac7509e2, 2026-08-14), so
#     containment is verifiable: DSpark (#46995/#47093), the hybrid-GDN
#     prefix-cache fix stack for #43559 (merged 2026-07-12..18; the issue was
#     closed completed 2026-08-06), and the GDN gate fix #51812 all landed
#     before it. Prefix caching is therefore kept ON — probe tool calls in the
#     validation gate anyway, because the degradation mode was silent.
#   * vLLM#52480 (MTP drafter weight-load crash at TP>=2) does NOT affect this
#     DSpark path; TP2 is the default and point of this profile.
#
# Prerequisites:
#   scripts/download-qwen38-27b.sh
#   scripts/download-qwen38-27b-dspark.sh
#   jq (already in the core-apps package set)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference-api-key.sh
source "$SCRIPT_DIR/inference-api-key.sh"

IMAGE="vllm/vllm-openai:nightly-ac7509e2b1db40fec2f03dde1ed4e9dfdc2338c9"
DIGEST="sha256:ecc6a14f77a9c788d78d5eee2eec371246567ab40989b58ec1d73a691c7cd54e"
MODEL_HOST="/models/Qwen3.8-27B"
MODEL_CONTAINER="/models/Qwen/Qwen3.8-27B"
DRAFT_HOST="/models/Qwen3.8-27B-DSpark"
DRAFT_VLLM_HOST="/models/Qwen3.8-27B-DSpark-vllm"
DRAFT_CONTAINER="/models/RadixArk/Qwen3.8-27B-DSpark-vllm"
CACHE_HOST="/models/vllm-cache/qwen38-bf16-dspark"
NAME="qwen38-27b-bf16-dspark-vllm"
DSARK_BLOCK_SIZE=7

MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"

command -v jq >/dev/null 2>&1 || { echo "error: jq is required (draft config surgery)" >&2; exit 2; }

if [ ! -e "$MODEL_HOST/config.json" ]; then
  echo "error: target checkpoint not found at $MODEL_HOST — run scripts/download-qwen38-27b.sh first" >&2
  exit 1
fi
if [ ! -e "$DRAFT_HOST/config.json" ]; then
  echo "error: DSpark draft not found at $DRAFT_HOST — run scripts/download-qwen38-27b-dspark.sh first" >&2
  exit 1
fi

# vLLM selects the Qwen DSpark implementation by the draft's architectures
# string. Prepare an isolated copy with that one field rewritten; the SGLang
# copy is left byte-identical. Idempotent: skip when the copy is already
# prepared, rebuild it when the source changed or the copy is half-written.
if [ ! -f "$DRAFT_VLLM_HOST/config.json" ] \
  || ! jq -e '.architectures == ["Qwen3DSparkModel"]' "$DRAFT_VLLM_HOST/config.json" >/dev/null 2>&1; then
  echo "Preparing vLLM draft copy at $DRAFT_VLLM_HOST (architectures -> Qwen3DSparkModel)..."
  rm -rf "${DRAFT_VLLM_HOST}.tmp"
  cp -a "$DRAFT_HOST" "${DRAFT_VLLM_HOST}.tmp"
  jq '(.architectures = ["Qwen3DSparkModel"])' "${DRAFT_VLLM_HOST}.tmp/config.json" > "${DRAFT_VLLM_HOST}.tmp/config.json.new"
  mv "${DRAFT_VLLM_HOST}.tmp/config.json.new" "${DRAFT_VLLM_HOST}.tmp/config.json"
  rm -rf "$DRAFT_VLLM_HOST"
  mv "${DRAFT_VLLM_HOST}.tmp" "$DRAFT_VLLM_HOST"
  jq -r '.architectures | join(",")' "$DRAFT_VLLM_HOST/config.json"
fi

# Resolve the human operator even under `sudo`, then synchronize the historical
# DeepSeek/Qwen paths to one endpoint key. This prevents a root-only key from
# silently replacing the credential Pi retrieves as the desktop user.
inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
CONFIG_DIR="$INFERENCE_OPERATOR_HOME/.config/qwen38"
KEYFILE="$INFERENCE_QWEN_KEYFILE"
ENVFILE="$CONFIG_DIR/vllm-dspark.env"

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
# (typically the SGLang DSpark container — stop it first:
#  docker stop qwen38-27b-bf16-dspark-sglang).
docker rm -f "$NAME" 2>/dev/null || true
if command -v ss >/dev/null 2>&1 && ss -H -ltn 'sport = :8000' | grep -q .; then
  echo "error: TCP port 8000 is already in use; stop the current model server first" >&2
  exit 1
fi

docker run -d --init \
  --restart unless-stopped \
  --name "$NAME" \
  --gpus all \
  --ipc=host \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  -v "$MODEL_HOST":"$MODEL_CONTAINER":ro \
  -v "$DRAFT_VLLM_HOST":"$DRAFT_CONTAINER":ro \
  -v "$CACHE_HOST":/root/.cache \
  -e CUDA_VISIBLE_DEVICES=0,1 \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e VLLM_NO_USAGE_STATS=1 \
  "$IMAGE@$DIGEST" \
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
  --speculative-config "{\"method\":\"dspark\",\"model\":\"$DRAFT_CONTAINER\",\"num_speculative_tokens\":$DSARK_BLOCK_SIZE,\"attention_backend\":\"FLASH_ATTN\",\"draft_sample_method\":\"probabilistic\"}" \
  --attention-backend flashinfer \
  --reasoning-parser qwen3 \
  --enable-auto-tool-choice \
  --tool-call-parser qwen3_coder \
  --default-chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true,"reasoning_effort":"xhigh"}' \
  --override-generation-config '{"temperature":1.0,"top_p":0.95,"top_k":20,"min_p":0.0,"presence_penalty":0.0,"repetition_penalty":1.0}' \
  --host 0.0.0.0 \
  --port 8000

echo "Started '$NAME' (vLLM + DSpark, TP2, block size $DSARK_BLOCK_SIZE)."
echo "First start downloads/compiles runtime kernels and may take several minutes."
echo "Follow:  docker logs -f $NAME"
echo "  - the second 'Resolved architecture:' log line must read Qwen3DSparkModel"
echo "  - watch vllm:spec_decode_* counters; expect acceptance length near 3.4"
echo "    (the SGLang DSpark baseline on this box); near 1.0 means miswired RoPE."
echo "Health:  curl -fsS http://127.0.0.1:8000/health"
echo "API key: $KEYFILE  (send as 'Authorization: Bearer <key>')"
echo "Validate against the SGLang DSpark baseline before promoting over it."
