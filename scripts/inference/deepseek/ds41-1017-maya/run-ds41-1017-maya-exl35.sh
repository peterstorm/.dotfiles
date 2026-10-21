#!/usr/bin/env bash
# DeepSeek-V4.1-Flash-1017 on Project Maya (maya-ds4), LibertAIDAI's EXL3
# 3.5 bpw plus DeepSeek's own Engram tables.
#
# Maya places the most-used experts in the two RTX PRO 6000s' VRAM and pins the
# rest in RAM. Maya sizes this quant at ~280 GB of VRAM + RAM; this box has
# 191 GB + ~85 GB free, so only a sliver of cold experts (and the Engram rows)
# come from the NVMe. UD-Q8_K_XL needed ~305 GB and was SSD-bound at ~5 tok/s
# (docs/runbooks/ds41-1017-maya-q8-runbook-2026-10-20.md). Layers are split
# across the two cards (--tp 2).
#
# What the repository owns:
#   - the toolchain/runtime image by id (the local Karmic Kraken beta build:
#     CUDA 13.4, cmake, g++ 13, Python 3.12 - Maya's engine is compiled with it
#     and runs in it; nothing new is pulled);
#   - the Maya source by commit (MAYA_COMMIT, a clean checkout on the dataset;
#     its .venv and build/ live beside it, so they match this image);
#   - the model files by revision and sha256 (download-ds41-1017-maya-exl35.sh,
#     from Maya's own manifest at the same commit);
#   - the workstation gates: two RTX PRO 6000 Blackwell cards idle at the
#     declared power limit, comfyui stopped, port 8000 free;
#   - the API key: the shared inference key, handed to the server through a
#     private env file (STRATA_API_KEY), never on a command line or in Maya's
#     config; served on :8000 like every other profile, so clients only change
#     the model id (deepseek-v4.1-flash);
#   - the transactional shape: --restart no here; the switcher promotes an
#     accepted boot.
#
# Modes:
#   --preflight     check every pin without touching the GPUs
#   --finish-setup  once, with the GPUs free: Maya's setup on the downloaded
#                   files (verifies them, fetches the DSpark drafter and the
#                   vision tower, builds the pack, writes maya-ds4.json, runs
#                   its speed calibration of the drafter)
#   --launch        start the server container
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../../shared/inference-profile-catalog.sh"

IMAGE_CONFIG="sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a"
IMAGE_DIGEST="sha256:495b340eede3bbb348fd6c9662d1535e0d2f27e47c08cc71802fea6bc68caf40"
MAYA_COMMIT="8d9a9b5d705049a87da853717cdc59440252de30"
MODELS_DIR="${MODELS_DIR:-/models/ds41}"
MAYA_DIR="$MODELS_DIR/project-maya"
QUANT="exl3-3.5"
QUANT_DIR="$MODELS_DIR/DeepSeek-V4.1-Flash-1017-3.5bpw"
CONFIG="maya-ds4.json"
CONTEXT="${CONTEXT:-65536}"
NAME="ds41-1017-maya-exl35"
SERVED_MODEL="deepseek-v4.1-flash"
PORT=8000
CONTAINER_HOME="$MODELS_DIR/.home"
MODE="${1:---launch}"

case "$MODE" in
  --preflight | --finish-setup | --launch) ;;
  *) echo "usage: ${0##*/} [--preflight|--finish-setup|--launch]" >&2; exit 2 ;;
esac

die() { echo "error: $*" >&2; exit 1; }

# --- pins: image, source, engine, files -------------------------------------
actual_image_id="$(docker image inspect "$IMAGE_CONFIG" --format '{{.Id}}' 2>/dev/null)" \
  || die "toolchain image $IMAGE_CONFIG is absent (docker pull ghcr.io/local-inference-lab/vllm@$IMAGE_DIGEST)"
[ "$actual_image_id" = "$IMAGE_CONFIG" ] || die "image id is $actual_image_id, expected $IMAGE_CONFIG"
docker image inspect "$IMAGE_CONFIG" --format '{{json .RepoDigests}}' \
  | jq -e --arg d "$IMAGE_DIGEST" 'any(.[]; endswith("@" + $d))' >/dev/null \
  || die "$IMAGE_CONFIG is not the image published under $IMAGE_DIGEST"

mountpoint -q "$MODELS_DIR" || die "$MODELS_DIR is not mounted (rpool/models/ds41)"
[ "$(git -C "$MAYA_DIR" rev-parse HEAD 2>/dev/null)" = "$MAYA_COMMIT" ] \
  || die "Maya checkout at $MAYA_DIR is not at $MAYA_COMMIT"
[ -z "$(git -C "$MAYA_DIR" status --porcelain)" ] || die "Maya checkout at $MAYA_DIR has local changes"
[ -x "$MAYA_DIR/build/maya-ds4" ] || die "engine is not compiled: $MAYA_DIR/build/maya-ds4"
jq -e '(.archs | index(120)) and (.targets | index("maya-ds4"))' "$MAYA_DIR/build/MAYA-BUILD.json" >/dev/null \
  || die "engine stamp does not cover sm_120 / maya-ds4"
[ -f "$QUANT_DIR/.download-complete" ] \
  || die "EXL3 3.5 bpw is not completely downloaded; run download-ds41-1017-maya-exl35.sh"

if [ "$MODE" = --launch ]; then
  [ -f "$MAYA_DIR/$CONFIG" ] || die "$MAYA_DIR/$CONFIG is missing; run ${0##*/} --finish-setup first"
  jq -e --arg d "$QUANT_DIR" --arg q "$QUANT" '.installer.model_dir == $d and .installer.ds4_quant == $q' \
    "$MAYA_DIR/$CONFIG" >/dev/null || die "$CONFIG was not written for $QUANT_DIR ($QUANT)"
fi

if [ "$MODE" = --preflight ]; then
  echo "DS4.1-1017 Maya EXL3 3.5 bpw preflight: PASS (image pin, Maya $MAYA_COMMIT clean, engine sm_120, files verified)"
  [ -f "$MAYA_DIR/$CONFIG" ] && echo "config: $MAYA_DIR/$CONFIG present" || echo "config: not written yet (--finish-setup)"
  exit 0
fi

# --- workstation gates --------------------------------------------------------
NIX_GPU_CONFIG="$(cd "$SCRIPT_DIR/../../../.." && pwd)/machines/desktop/default.nix"
DECLARED_GPU_WATTS="$(sed -nE 's/^[[:space:]]*gpuPowerLimitWatts = ([0-9]+);$/\1/p' "$NIX_GPU_CONFIG" | tail -1)"
[[ -n "$DECLARED_GPU_WATTS" ]] || die "gpuPowerLimitWatts is not pinned in $NIX_GPU_CONFIG"
if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  die "comfyui.service is active; stop it before reserving both GPUs"
fi
mapfile -t gpu_rows < <(nvidia-smi --query-gpu=index,name,memory.total,memory.used,power.limit \
  --format=csv,noheader,nounits)
[ "${#gpu_rows[@]}" -eq 2 ] || die "this profile requires exactly two GPUs; found ${#gpu_rows[@]}"
for row in "${gpu_rows[@]}"; do
  IFS=, read -r index name memory_total memory_used power_limit <<<"$row"
  index="${index//[[:space:]]/}"; name="${name# }"
  memory_total="${memory_total//[[:space:]]/}"; memory_used="${memory_used//[[:space:]]/}"
  power_limit="${power_limit//[[:space:]]/}"
  [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || die "GPU $index is not an RTX PRO 6000 Blackwell: $name"
  ((memory_total >= 97000)) || die "GPU $index exposes only ${memory_total} MiB"
  ((memory_used <= 1024)) || die "GPU $index has ${memory_used} MiB in use; stop every GPU workload"
  awk -v a="$power_limit" -v d="$DECLARED_GPU_WATTS" 'BEGIN { exit !(a >= d - 0.5 && a <= d + 0.5) }' \
    || die "GPU $index power limit is ${power_limit} W; declarative config pins ${DECLARED_GPU_WATTS} W"
done

# Maya pins all but ~6 GB of the free RAM for its expert tier; containers in the
# same image share the checkout's .venv, so it always runs under this image.
common_run=(--gpus all --ipc host --network host --ulimit memlock=-1
  --user "$(id -u):$(id -g)" -e HOME="$CONTAINER_HOME" -e MAYA_UPDATE_CHECK=0
  -v "$MODELS_DIR:$MODELS_DIR" -w "$MAYA_DIR" --entrypoint bash)
mkdir -p "$CONTAINER_HOME"

if [ "$MODE" = --finish-setup ]; then
  docker run --rm --name "$NAME-setup" "${common_run[@]}" "$IMAGE_CONFIG" -c \
    "./setup.sh --setup --model DeepSeek-V4.1-Flash-1017 --ds4-quant '$QUANT' --models-dir '$MODELS_DIR' \
       --gpus 0,1 --context '$CONTEXT' --host 0.0.0.0 --port '$PORT' --download-model --yes --plain --no-start"
  jq -e --arg d "$QUANT_DIR" '.installer.model_dir == $d' "$MAYA_DIR/$CONFIG" >/dev/null \
    || die "setup finished without writing $CONFIG for $QUANT_DIR"
  echo "setup complete: $MAYA_DIR/$CONFIG"
  jq -c '{args, port, host, gpu, model_name}' "$MAYA_DIR/$CONFIG"
  exit 0
fi

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  die "host port 8000 is already listening; use the switcher to replace the active profile"
fi

inference_prepare_api_key "${VLLM_API_KEY:-}"
ENVFILE="$INFERENCE_OPERATOR_HOME/.config/ds41-maya/server.env"
inference_install_private_dir "$(dirname "$ENVFILE")"
inference_write_private_file "$ENVFILE" <<EOF
STRATA_API_KEY=$INFERENCE_API_KEY
EOF

docker run -d --name "$NAME" --restart no \
  --label ai.peterstorm.inference.profile="$NAME" \
  --label ai.peterstorm.inference.served-model="$SERVED_MODEL" \
  --label ai.peterstorm.inference.maya-commit="$MAYA_COMMIT" \
  --env-file "$ENVFILE" "${common_run[@]}" "$IMAGE_CONFIG" -c \
  "exec ./maya.sh --plain --config '$CONFIG' --host 0.0.0.0 --port '$PORT'" >/dev/null
echo "launched $NAME (model $SERVED_MODEL on :$PORT); logs: docker logs -f $NAME"
