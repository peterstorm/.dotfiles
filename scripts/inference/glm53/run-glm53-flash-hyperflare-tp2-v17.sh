#!/usr/bin/env bash
# GLM-5.3 v17: GLM-5.3-Flash (v16's nvidia/GLM-5.3-Flash-FP4-Local checkpoint)
# served by upstream NVIDIA Hyperflare from a core exported with
# hyperflare-recipes PR #55 + FlashInfer PR #151 (glm53-v17-hyperflare/pins.sh):
# TP2/DCP2, 8 slots, MTP 5 drafts with adaptive verification, images, the
# 1,048,576-token prepared context, and in PREFILL=rowshard (default) the
# sequence-parallel row-sharded prefill. PREFILL=baseline serves the
# head-sharded control core from the same image.
#
# A test profile, not a primary: switch-glm53-hyperflare-tp2-v17.sh starts it
# transactionally; switch-primary.sh and Pi's catalog do not offer it.
#
# Differences from v16 that are upstream's, not choices made here:
#   - SCHEDULER is balanced (default) or throughput. Upstream has no
#     `interactive` policy: v16's TTFT guard is a fork feature.
#   - The token embedding and vision tower stay in VRAM: host-memory embedding and
#     staged vision are fork features too. v17's KV room is whatever upstream's
#     planner leaves; the boot receipt records it.
# Kept from v16: PREFIX_CACHE 16G (desktop has 96 GB of RAM), 400 W per GPU, the
# API key as a read-only file, the pinned signing key, and the fail-closed
# workstation gates (hyperflare-workstation.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$SCRIPT_DIR/glm53-v17-hyperflare/pins.sh"
# shellcheck source=scripts/inference/glm53/hyperflare-workstation.sh
source "$SCRIPT_DIR/hyperflare-workstation.sh"

PREFILL="$(v17_resolve_prefill "${PREFILL:-rowshard}")" || exit 2
V17_ROOT="${V17_ROOT:-$V17_DEFAULT_ROOT}"
FLARE_HOME="$V17_ROOT/flare-home"
CORE_RECEIPT="$V17_ROOT/core-$PREFILL.txt"
PREFIX_CACHE="${PREFIX_CACHE:-16G}"
SCHEDULER="${SCHEDULER:-balanced}"
MODE="${1:---launch}"

case "$MODE" in
  --launch | --preflight) ;;
  *) echo "usage: ${0##*/} [--launch|--preflight]" >&2; exit 2 ;;
esac
case "$SCHEDULER" in
  balanced | throughput) ;;
  *) echo "error: SCHEDULER must be balanced (upstream default) or throughput" >&2; exit 2 ;;
esac
[[ "$PREFIX_CACHE" =~ ^[1-9][0-9]*G$ ]] || {
  echo "error: PREFIX_CACHE must be whole gibibytes, e.g. 16G" >&2
  exit 2
}
# flare resolves ~/.cache/flare through getpwuid, not $HOME; the image maps
# only uid 1000's home to /flare-home (see the Dockerfile).
[ "$(id -u)" = 1000 ] || {
  echo "error: run as uid 1000 (the image maps only uid 1000's home to /flare-home)" >&2
  exit 2
}

labels="$(docker image inspect "$V17_IMAGE" --format "$(v17_image_labels_format)" 2>/dev/null)" || {
  echo "error: image $V17_IMAGE is absent; run scripts/inference/glm53/build-glm53-flash-hyperflare-tp2-v17-image.sh" >&2
  exit 1
}
mismatch="$(v17_image_matches_pins "$labels")" || { echo "error: image $V17_IMAGE: $mismatch" >&2; exit 1; }

# The core is whatever the last successful export of this mode recorded: parsed
# once, then checked against the store, so a typo or a deleted version fails here.
[ -r "$CORE_RECEIPT" ] || {
  echo "error: no core receipt at $CORE_RECEIPT; run PREFILL=$PREFILL scripts/inference/glm53/export-glm53-flash-hyperflare-tp2-v17.sh" >&2
  exit 1
}
CORE="$(v17_receipt_core "$V17_MODEL" "$PREFILL" <"$CORE_RECEIPT")" || {
  echo "error: $CORE_RECEIPT: $CORE" >&2
  exit 1
}
ENTRY="$(sed -n 's/^entry=//p' "$CORE_RECEIPT")"
[[ "$ENTRY" == /flare-home/* && "$(v17_core_of_entry "$ENTRY")" == "$CORE" && -d "$FLARE_HOME${ENTRY#/flare-home}" ]] || {
  echo "error: core $CORE is not in the store at $FLARE_HOME${ENTRY#/flare-home}" >&2
  exit 1
}

# shellcheck disable=SC2054 # "0,1" is flare's single --gpus value, not two elements
FLARE_ARGS=(
  run "$CORE" --gpus 0,1 --host 0.0.0.0 --port 8000
  --served-model-name "$V17_SERVED_MODEL"
  --prefix-cache-memory "$PREFIX_CACHE" --mtp-draft-tokens 5
  --scheduler-policy "$SCHEDULER"
  --api-key-file /run/inference/api-key
  # Unattended first use needs explicit trust: v16's local development signing
  # key, which the v17 export seeds into its own state root (pins.sh).
  --dangerously-approve-key "$V17_SIGNING_KEY_FINGERPRINT"
  --dangerously-accept-publisher local-development
)

if [ "$MODE" = --preflight ]; then
  echo "GLM-5.3 v17 ($PREFILL) Hyperflare TP2 preflight: PASS (image $V17_IMAGE, core $CORE)"
  echo "Launch: flare ${FLARE_ARGS[*]}"
  exit 0
fi

hyperflare_require_workstation "$SCRIPT_DIR" || exit 1
inference_remove_container_if_present "$V17_CONTAINER"
hyperflare_require_free_endpoint || exit 1

# The key reaches flare as a read-only file mount (--api-key-file), never as
# an argument or environment variable.
inference_prepare_api_key "${VLLM_API_KEY:-}"
KEYFILE="$INFERENCE_GLM_KEYFILE"

docker run -d --init \
  --restart no \
  --stop-timeout 120 \
  --name "$V17_CONTAINER" \
  --label ai.peterstorm.inference.profile="$V17_CONTAINER" \
  --label ai.peterstorm.inference.engine=hyperflare \
  --label "$V17_LABEL_HFI=$V17_HYPERFLARE_INFERENCE_COMMIT" \
  --label "$V17_LABEL_HFR=$V17_RECIPES_COMMIT" \
  --label "$V17_LABEL_FI=$V17_FLASHINFER_COMMIT" \
  --label ai.peterstorm.inference.checkpoint="$V17_CHECKPOINT" \
  --label ai.peterstorm.inference.package="$CORE" \
  --label ai.peterstorm.inference.prefill="$PREFILL" \
  --label ai.peterstorm.inference.parallelism=tp2-dcp2 \
  --label ai.peterstorm.inference.speculation=mtp5-adaptive \
  --label ai.peterstorm.inference.scheduler="$SCHEDULER" \
  --label ai.peterstorm.inference.prefix-cache="$PREFIX_CACHE" \
  --gpus all \
  --network host \
  --ipc host \
  --ulimit memlock=-1 \
  --ulimit stack=67108864:67108864 \
  --security-opt seccomp=unconfined \
  --user "$(id -u):$(id -g)" \
  -e HOME=/flare-home \
  -v "$FLARE_HOME:/flare-home" \
  -v "$KEYFILE:/run/inference/api-key:ro" \
  -w /opt/hyperflare-recipes \
  --entrypoint /usr/local/bin/flare \
  "$V17_IMAGE" \
  "${FLARE_ARGS[@]}"

printf "Started Hyperflare GLM-5.3 v17 TP2 profile '%s' (%s, %s prefill). Follow: docker logs -f %s\n" \
  "$V17_CONTAINER" "$CORE" "$PREFILL" "$V17_CONTAINER"
printf "API key: %s (send as 'Authorization: Bearer <key>')\n" "$KEYFILE"
printf '%s\n' "Served model id: $V17_SERVED_MODEL."
printf '%s\n' 'Metrics: :8000/metrics (raw flare_*) and the model-labelled bridge on :8011.'
