#!/usr/bin/env bash
# GLM-5.3 v16: GLM-5.3-Flash (nvidia/GLM-5.3-Flash-FP4-Local @ 76348ddb…)
# served by NVIDIA Hyperflare (AzallazA fork hyperflare-glm-20261112,
# ac9136b0) as the recipe's TP2/DCP2 package: 8 slots, MTP 5 drafts with
# adaptive verification, images (2 at once), 1,048,576-token context, the
# `interactive` scheduler (TTFT guard), token embedding and vision tower in
# host memory. Recipe: AzallazA/RTX-PRO-6000-TP3-Inference-Recipes
# "GLM-5.3-Flash Hyperflare-tp3-20261112" (serve-glm-tp2.sh, vendored in
# glm53-v16-hyperflare/; this launcher passes the same flags plus our port,
# host, served id and API key).
#
# Deliberate differences from the recipe's test system:
#   - PREFIX_CACHE 16G instead of 32G: desktop has 96 GB of RAM, not 256 GB.
#     The recipe measured 75 GiB resident for TP2 with 32G; 16G keeps the
#     server near 60 GiB. Host-RAM prefix reuse only; KV in VRAM is unchanged.
#   - 400 W per GPU (gpuPowerLimitWatts), not 450 W: the package is exported
#     on this box at this limit, so kernel tuning matched what serves.
#
# What the repository owns: the image (built locally from pinned inputs and
# checked by label), the package (read from the export receipt, never a
# floating "latest"), the served model id, and the fail-closed workstation
# gates. Transactional shape as for v15: --restart no here; the switcher
# promotes to unless-stopped only after an accepted boot.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

IMAGE="peterstorm/glm53-hyperflare:ac9136b-cu131"
HYPERFLARE_COMMIT="ac9136b02c7c523f12d6e628e9d94f41006312ea"
CHECKPOINT="nvidia/GLM-5.3-Flash-FP4-Local@76348ddb2be2e35e39ecfc00e75dc07703f4f3d5"
NAME="glm53-flash-hyperflare-tp2-v16"
SERVED_MODEL="glm-5.3-flash-hyperflare-tp2-v16"
ROOT_HOST="${ROOT_HOST:-/models/glm53-hyperflare}"
FLARE_HOME="$ROOT_HOST/flare-home"
PACKAGE_RECEIPT="$ROOT_HOST/package-v16.txt"
PREFIX_CACHE="${PREFIX_CACHE:-16G}"
SCHEDULER="${SCHEDULER:-interactive}"
MODE="${1:---launch}"

case "$MODE" in
  --launch | --preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$SCHEDULER" in
  interactive | balanced) ;;
  *) echo "error: SCHEDULER must be interactive (recipe default) or balanced" >&2; exit 2 ;;
esac
[[ "$PREFIX_CACHE" =~ ^[1-9][0-9]*G$ ]] || {
  echo "error: PREFIX_CACHE must be whole gibibytes, e.g. 16G" >&2
  exit 2
}

label="$(docker image inspect "$IMAGE" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.hyperflare-commit"}}' 2>/dev/null)" || {
  echo "error: image $IMAGE is absent; run scripts/inference/glm53/build-glm53-flash-hyperflare-tp2-v16-image.sh" >&2
  exit 1
}
[ "$label" = "$HYPERFLARE_COMMIT" ] || {
  echo "error: image $IMAGE was built from $label, expected $HYPERFLARE_COMMIT" >&2
  exit 1
}

# The package is whatever the last successful export recorded — parsed once,
# then checked against the store, so a typo or a deleted version fails here.
[ -r "$PACKAGE_RECEIPT" ] || {
  echo "error: no package receipt at $PACKAGE_RECEIPT; run scripts/inference/glm53/export-glm53-flash-hyperflare-tp2-v16.sh" >&2
  exit 1
}
PACKAGE="$(sed -n 's/^package=//p' "$PACKAGE_RECEIPT")"
[[ "$PACKAGE" =~ ^glm53-fp4-local@gb202-tp2-[0-9]+$ ]] || {
  echo "error: package receipt names '$PACKAGE', expected glm53-fp4-local@gb202-tp2-<timestamp>" >&2
  exit 1
}
package_dir="$FLARE_HOME/.cache/flare/packages/models/${PACKAGE%@*}/${PACKAGE#*@}"
[ -d "$package_dir" ] || {
  echo "error: package $PACKAGE is not in the store at $package_dir" >&2
  exit 1
}

# shellcheck disable=SC2054 # "0,1" is flare's single --gpus value, not two elements
FLARE_ARGS=(
  run "$PACKAGE" --gpus 0,1 --host 0.0.0.0 --port 8000
  --served-model-name "$SERVED_MODEL"
  --prefix-cache-memory "$PREFIX_CACHE" --mtp-draft-tokens 5
  --scheduler-policy "$SCHEDULER"
  --api-key-file /run/inference/api-key
)

if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v16 Hyperflare TP2 preflight: PASS (image $HYPERFLARE_COMMIT, package $PACKAGE)"
  echo "Launch: flare ${FLARE_ARGS[*]}"
  exit 0
fi

NIX_GPU_CONFIG=''
WALK_ROOT="$SCRIPT_DIR"
while [[ -z "$NIX_GPU_CONFIG" && "$WALK_ROOT" != "/" ]]; do
  if [[ -f "$WALK_ROOT/machines/desktop/default.nix" ]]; then
    NIX_GPU_CONFIG="$WALK_ROOT/machines/desktop/default.nix"
  else
    WALK_ROOT="$(dirname "$WALK_ROOT")"
  fi
done
[[ -n "$NIX_GPU_CONFIG" ]] || { echo "error: no machines/desktop/default.nix found above $SCRIPT_DIR" >&2; exit 1; }
DECLARED_GPU_WATTS="$(sed -nE 's/^[[:space:]]*gpuPowerLimitWatts = ([0-9]+);$/\1/p' "$NIX_GPU_CONFIG" | tail -1)"
[[ -n "$DECLARED_GPU_WATTS" ]] || { echo "error: gpuPowerLimitWatts is not pinned in $NIX_GPU_CONFIG" >&2; exit 1; }

if systemctl is-active --quiet comfyui.service 2>/dev/null; then
  echo "error: comfyui.service is active; stop it before reserving both GPUs" >&2
  exit 1
fi
mapfile -t gpu_rows < <(nvidia-smi --query-gpu=index,name,memory.total,memory.used,power.limit --format=csv,noheader,nounits)
[ "${#gpu_rows[@]}" -eq 2 ] || { echo "error: this profile requires exactly two GPUs; found ${#gpu_rows[@]}" >&2; exit 1; }
for row in "${gpu_rows[@]}"; do
  IFS=, read -r index name memory_total memory_used power_limit <<<"$row"
  index="${index//[[:space:]]/}"; name="${name# }"
  memory_total="${memory_total//[[:space:]]/}"; memory_used="${memory_used//[[:space:]]/}"
  power_limit="${power_limit//[[:space:]]/}"
  [[ "$name" == *"RTX PRO 6000 Blackwell"* ]] || { echo "error: GPU $index is not an RTX PRO 6000 Blackwell: $name" >&2; exit 1; }
  ((memory_total >= 97000)) || { echo "error: GPU $index exposes only ${memory_total} MiB" >&2; exit 1; }
  ((memory_used <= 1024)) || { echo "error: GPU $index has ${memory_used} MiB in use; stop every GPU workload" >&2; exit 1; }
  awk -v actual="$power_limit" -v declared="$DECLARED_GPU_WATTS" \
    'BEGIN { exit !(actual >= declared - 0.5 && actual <= declared + 0.5) }' || {
      echo "error: GPU $index power limit is ${power_limit} W; declarative config pins ${DECLARED_GPU_WATTS} W" >&2
      exit 1
    }
done

inference_remove_container_if_present "$NAME"
if ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$'; then
  echo "error: host port 8000 is already listening; use the v16 switcher to replace the active profile" >&2
  exit 1
fi

# The key reaches flare as a read-only file mount (--api-key-file), never as
# an argument or environment variable.
inference_prepare_api_key "${VLLM_API_KEY:-}"
KEYFILE="$INFERENCE_GLM_KEYFILE"

docker run -d --init \
  --restart no \
  --stop-timeout 120 \
  --name "$NAME" \
  --label ai.peterstorm.inference.profile=glm53-flash-hyperflare-tp2-v16 \
  --label ai.peterstorm.inference.engine=hyperflare \
  --label ai.peterstorm.inference.hyperflare-commit="$HYPERFLARE_COMMIT" \
  --label ai.peterstorm.inference.checkpoint="$CHECKPOINT" \
  --label ai.peterstorm.inference.package="$PACKAGE" \
  --label ai.peterstorm.inference.parallelism=tp2-dcp2 \
  --label ai.peterstorm.inference.speculation=mtp5-adaptive \
  --label ai.peterstorm.inference.scheduler="$SCHEDULER" \
  --label ai.peterstorm.inference.prefix-cache="$PREFIX_CACHE" \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864:67108864 \
  --user "$(id -u):$(id -g)" \
  -e HOME=/flare-home \
  -v "$FLARE_HOME:/flare-home" \
  -v "$KEYFILE:/run/inference/api-key:ro" \
  -w /opt/flare \
  --entrypoint /opt/flare/flare-cli/target/release/flare \
  "$IMAGE" \
  "${FLARE_ARGS[@]}"

printf "Started Hyperflare GLM-5.3 TP2 profile '%s' (%s). Follow: docker logs -f %s\n" "$NAME" "$PACKAGE" "$NAME"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' "Served model id: $SERVED_MODEL. Ready at 'Start server.'; recipe startup ~30 s (weights load 21 s)."
printf '%s\n' 'Metrics: :8000/metrics (raw flare_*) and the model-labelled bridge on :8011.'
