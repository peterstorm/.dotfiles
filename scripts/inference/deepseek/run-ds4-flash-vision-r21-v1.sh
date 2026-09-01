#!/usr/bin/env bash
# Launch the immutable DeepSeek-V4-Flash-Vision-Exp Infernal Invocation r21 overlay.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183"
BASE_DIGEST="sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291"
PATCH_SHA="800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469"
MODEL_REV="86f746b36186f0e567729a5c06a8c918caba82a9"
MODEL_HOST="${MODEL_HOST:-$HOME/models/DeepSeek-V4-Flash-Vision-Exp}"
MODEL_CONTAINER="/model"
CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/ds4-vision-infernal-invocation-cu133-r21-v1}"
TMP_HOST="$CACHE_HOST/tmp"
NAME="ds4-flash-vision-infernal-invocation-cu133-r21-v1"
SERVED_MODEL="deepseek-v4-flash-vision"

GPU_ORDER="${GPU_ORDER:-0,1}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-312000}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-4096}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-8}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.975}"
SERVING_MODE="${SERVING_MODE:-dspark}"
DSPARK_DEPTH_MODE="${DSPARK_DEPTH_MODE:-fixed}"
DSPARK_TOKENS="${DSPARK_TOKENS:-6}"
MODE="${1:---launch}"

positive_integer() {
  local name="$1" value="$2" maximum="$3"
  if ! [[ "$value" =~ ^[1-9][0-9]*$ ]] || (( value > maximum )); then
    echo "error: $name must be an integer in [1, $maximum]" >&2
    exit 2
  fi
}

case "$MODE" in
  --launch|--preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$GPU_ORDER" in
  0,1|1,0) ;;
  *) echo "error: GPU_ORDER must be 0,1 or 1,0" >&2; exit 2 ;;
esac
case "$SERVING_MODE" in
  dspark-mtp0|dspark) ;;
  *) echo "error: SERVING_MODE must be dspark-mtp0 or dspark" >&2; exit 2 ;;
esac
case "$DSPARK_DEPTH_MODE" in
  fixed|dynamic) ;;
  *) echo "error: DSPARK_DEPTH_MODE must be fixed or dynamic" >&2; exit 2 ;;
esac
positive_integer MAX_MODEL_LEN "$MAX_MODEL_LEN" 312000
positive_integer MAX_NUM_BATCHED_TOKENS "$MAX_NUM_BATCHED_TOKENS" 4096
positive_integer MAX_NUM_SEQS "$MAX_NUM_SEQS" 8
positive_integer DSPARK_TOKENS "$DSPARK_TOKENS" 6
if [[ "$SERVING_MODE" == dspark && "$DSPARK_TOKENS" != 6 ]]; then
  echo "error: this checkpoint requires DSpark depth 6 (block size 5, n_predict 3)" >&2
  exit 2
fi
if ! [[ "$GPU_MEMORY_UTILIZATION" =~ ^0\.[0-9]+$ ]] \
  || ! awk -v value="$GPU_MEMORY_UTILIZATION" \
    'BEGIN { exit !(value >= 0.90 && value <= 0.98) }'; then
  echo "error: GPU_MEMORY_UTILIZATION must be in [0.90, 0.98]" >&2
  exit 2
fi

actual_image="$(docker image inspect "$IMAGE" --format '{{.Id}}' 2>/dev/null)" || {
  echo "error: DS4 Vision image is absent; run build-ds4-flash-vision-r21-image.sh" >&2
  exit 1
}
[[ "$actual_image" == "$IMAGE" ]] || {
  echo "error: DS4 Vision image identity mismatch: $actual_image" >&2
  exit 1
}
docker image inspect "$IMAGE" --format '{{json .Config.Labels}}' | jq -e \
  --arg base "$BASE_DIGEST" --arg patch "$PATCH_SHA" --arg revision "$MODEL_REV" '
    .["local-inference.base.digest"] == $base and
    .["org.opencontainers.image.revision"] == $patch and
    .["local-inference.ds4.vision.model-revision"] == $revision and
    .["local-inference.ds4.vision.image-swa"] == "disjoint-natural-lse-merge" and
    .["local-inference.ds4.vision.dspark-markov-oov"] == "sanitized"
  ' >/dev/null || {
    echo "error: DS4 Vision image provenance labels differ" >&2
    exit 1
  }
[[ -f "$MODEL_HOST/config.json" ]] || {
  echo "error: checkpoint missing at $MODEL_HOST" >&2
  exit 1
}
[[ "$(<"$MODEL_HOST/.deepseek-v4-flash-vision-exp.revision")" == "$MODEL_REV" ]] || {
  echo "error: checkpoint revision marker differs" >&2
  exit 1
}
docker run --rm -v "$MODEL_HOST:$MODEL_CONTAINER:ro" --entrypoint python3 \
  "$IMAGE" /opt/ds4-vision-r21/verify.py --static --checkpoint "$MODEL_CONTAINER"
if [[ "$MODE" == --preflight ]]; then
  echo "DeepSeek V4 Flash Vision r21 image and checkpoint preflight: PASS"
  exit 0
fi

if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  echo "error: comfyui.service is active; stop it before reserving both GPUs" >&2
  exit 1
fi
mapfile -t gpu_rows < <(nvidia-smi \
  --query-gpu=index,name,memory.total,memory.used,power.limit \
  --format=csv,noheader,nounits)
[[ "${#gpu_rows[@]}" -eq 2 ]] || {
  echo "error: DS4 Vision requires exactly two GPUs" >&2
  exit 1
}
for row in "${gpu_rows[@]}"; do
  IFS=, read -r index name memory_total memory_used power_limit <<<"$row"
  index="${index//[[:space:]]/}"
  name="${name# }"
  memory_total="${memory_total//[[:space:]]/}"
  memory_used="${memory_used//[[:space:]]/}"
  power_limit="${power_limit//[[:space:]]/}"
  [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || {
    echo "error: GPU $index is not an RTX PRO 6000 Blackwell: $name" >&2
    exit 1
  }
  (( memory_total >= 97000 && memory_used <= 1024 )) || {
    echo "error: GPU $index memory is ${memory_used}/${memory_total} MiB" >&2
    exit 1
  }
  awk -v value="$power_limit" 'BEGIN { exit !(value >= 449.9 && value <= 450.1) }' \
    || { echo "error: GPU $index power limit is $power_limit W" >&2; exit 1; }
done

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  echo "error: port 8000 is occupied; use the transactional switcher" >&2
  exit 1
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
VLLM_API_KEY="$INFERENCE_API_KEY"
KEYFILE="$INFERENCE_DS4_KEYFILE"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/ds4-vision-r21/v1.env"
inference_write_private_file "$ENVFILE" <<EOF
VLLM_API_KEY=$VLLM_API_KEY
EOF

for directory in "$CACHE_HOST" "$TMP_HOST"; do
  sudo mkdir -p "$directory"
  sudo chown "$USER:users" "$directory"
  inference_require_cache_access "$directory"
done

docker run -d --init \
  --restart no \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=ds4-flash-vision-r21-v1 \
  --label ai.peterstorm.inference.checkpoint="deepseek-ai/DeepSeek-V4-Flash-Vision-Exp@$MODEL_REV" \
  --label ai.peterstorm.inference.image-config="$IMAGE" \
  --label ai.peterstorm.inference.prefix-cache=enabled-mm-atomic \
  --gpus all \
  --ipc=host \
  --shm-size 32g \
  --network host \
  --ulimit memlock=-1 \
  --ulimit nofile=1048576 \
  --ulimit stack=67108864 \
  --env-file "$ENVFILE" \
  --entrypoint /usr/local/bin/lmcache-mp-wrapper.sh \
  -v "$MODEL_HOST:$MODEL_CONTAINER:ro" \
  -v "$CACHE_HOST:/cache" \
  -v "$TMP_HOST:/container-tmp" \
  -e CUDA_VISIBLE_DEVICES="$GPU_ORDER" \
  -e CUDA_DEVICE_ORDER=PCI_BUS_ID \
  -e GLOO_SOCKET_IFNAME=lo \
  -e NCCL_SOCKET_IFNAME=lo \
  -e OMP_NUM_THREADS=2 \
  -e HF_HUB_OFFLINE=1 \
  -e SERVED_MODEL_NAME="$SERVED_MODEL" \
  -e MODEL_PATH="$MODEL_CONTAINER" \
  -e PORT=8000 \
  -e MODE="$SERVING_MODE" \
  -e DSPARK_DEPTH_MODE="$DSPARK_DEPTH_MODE" \
  -e DSPARK_TOKENS="$DSPARK_TOKENS" \
  -e DSPARK_CAPACITY_ACTIVATION_BATCH_SIZE=0 \
  -e DRAFT_SAMPLE_METHOD=probabilistic \
  -e BACKEND=b12x-a8-dglin \
  -e VLLM_USE_B12X_MHC=0 \
  -e TP_SIZE=2 \
  -e DCP_SIZE=1 \
  -e ALLREDUCE_MODE=auto \
  -e MAX_MODEL_LEN="$MAX_MODEL_LEN" \
  -e MAX_NUM_BATCHED_TOKENS="$MAX_NUM_BATCHED_TOKENS" \
  -e MAX_NUM_SEQS="$MAX_NUM_SEQS" \
  -e GPU_MEMORY_UTILIZATION="$GPU_MEMORY_UTILIZATION" \
  -e GRAPH=auto \
  -e PREFIX_CACHE=1 \
  -e LOAD_FORMAT=instanttensor \
  -e INSTANTTENSOR_BACKEND=BUFFERED \
  -e LMCACHE_MODE=off \
  -e PYTHONHASHSEED=0 \
  -e TMPDIR=/container-tmp \
  -e EXTRA_VLLM_ARGS='--disable-chunked-mm-input --default-chat-template-kwargs.reasoning_effort=max' \
  "$IMAGE" \
  /usr/local/bin/serve-ds4-flash.sh >/dev/null

printf "Started '%s' with restart=no, %s, DSpark tokens=%s.\n" \
  "$NAME" "$SERVING_MODE" "$DSPARK_TOKENS"
printf "Follow: docker logs -f %s\n" "$NAME"
printf "API key: %s (Authorization: Bearer <key>)\n" "$KEYFILE"
