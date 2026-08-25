#!/usr/bin/env bash
# Run one offline IndexTTS-2.5 no-guide calibration package.
set -euo pipefail

IMAGE="${INDEXTTS25_IMAGE:-peterstorm/indextts25:2.5.0-39207d9-cu128}"
EXPECTED_IMAGE_ID="${INDEXTTS25_EXPECTED_IMAGE_ID:?set INDEXTTS25_EXPECTED_IMAGE_ID to the qualified sha256 image ID}"
EXPECTED_REV="39207d91c30899cad1e7c1b9eb678c241f678e55"
MODEL_ROOT="${INDEXTTS25_MODEL_ROOT:-/models/voice/indextts/2.5-c39ce5b}"
MODEL_MARKER="${INDEXTTS25_MODEL_MARKER:-/models/voice/indextts/.indextts25-c39ce5b-complete}"
SPEC="${INDEXTTS25_SPEC:?set INDEXTTS25_SPEC to an absolute specification path}"
ANCHORS_ROOT="${INDEXTTS25_ANCHORS_ROOT:?set INDEXTTS25_ANCHORS_ROOT to an absolute VoiceAnchor root}"
GENERATOR="${INDEXTTS25_GENERATOR:?set INDEXTTS25_GENERATOR to the absolute generator path}"
OUTPUT="${INDEXTTS25_OUTPUT:?set INDEXTTS25_OUTPUT to a new absolute output directory}"
GPU_DEVICE="${VOICE_GPU_DEVICE:-0}"

require_absolute() {
  [[ "$1" = /* ]] || { echo "error: path must be absolute: $1" >&2; return 1; }
}

main() {
  local image_id image_rev marker_image used_mib output_parent output_name
  for path in "$SPEC" "$ANCHORS_ROOT" "$GENERATOR" "$OUTPUT"; do require_absolute "$path"; done
  [[ -f "$SPEC" ]] || { echo "error: specification is unavailable: $SPEC" >&2; return 1; }
  [[ -d "$ANCHORS_ROOT" ]] || { echo "error: anchors root is unavailable: $ANCHORS_ROOT" >&2; return 1; }
  [[ -f "$GENERATOR" ]] || { echo "error: generator is unavailable: $GENERATOR" >&2; return 1; }
  [[ -d "$MODEL_ROOT" ]] || { echo "error: model root is unavailable: $MODEL_ROOT" >&2; return 1; }
  [[ ! -e "$OUTPUT" ]] || { echo "error: output already exists: $OUTPUT" >&2; return 1; }
  grep -Fxq 'usage=noncommercial-development-only' "$MODEL_MARKER" || {
    echo 'error: noncommercial Development model marker is absent' >&2
    return 1
  }

  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  image_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$image_id" == "$EXPECTED_IMAGE_ID" ]] || { echo "error: image ID mismatch: $image_id" >&2; return 1; }
  [[ "$image_rev" == "$EXPECTED_REV" ]] || { echo "error: image revision mismatch: $image_rev" >&2; return 1; }
  marker_image="$(sed -n 's/^image-id=//p' "$MODEL_MARKER")"
  [[ "$marker_image" == "$image_id" ]] || { echo "error: model marker image mismatch: $marker_image" >&2; return 1; }

  used_mib="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
  [[ "$used_mib" =~ ^[0-9]+$ ]] || { echo "error: cannot parse GPU memory use: $used_mib" >&2; return 1; }
  (( used_mib <= 4096 )) || { echo "error: GPU $GPU_DEVICE is busy (${used_mib} MiB used)" >&2; return 1; }

  output_parent="$(dirname "$OUTPUT")"
  output_name="$(basename "$OUTPUT")"
  install -d -m 0750 "$output_parent"
  docker run --rm --init \
    --network none \
    --read-only \
    --cap-drop all \
    --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" \
    --gpus "device=$GPU_DEVICE" \
    --shm-size 16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=16g,mode=1777 \
    --mount "type=bind,src=$MODEL_ROOT,dst=/models/indextts25,readonly" \
    --mount "type=bind,src=$ANCHORS_ROOT,dst=/anchors,readonly" \
    --mount "type=bind,src=$SPEC,dst=/input/spec.json,readonly" \
    --mount "type=bind,src=$GENERATOR,dst=/work/generate.py,readonly" \
    --mount "type=bind,src=$output_parent,dst=/output" \
    "$image_id" /work/generate.py \
      --spec /input/spec.json \
      --anchors-root /anchors \
      --model-dir /models/indextts25 \
      --output "/output/$output_name"

  {
    printf 'image=%s\n' "$IMAGE"
    printf 'image_id=%s\n' "$image_id"
    printf 'source_revision=%s\n' "$image_rev"
    printf 'model_root=%s\n' "$MODEL_ROOT"
    printf 'model_artifacts_sha256=%s\n' "$(sha256sum "$MODEL_ROOT/ARTIFACTS.sha256" | cut -d' ' -f1)"
    printf 'gpu=%s\n' "$GPU_DEVICE"
    printf 'network=none\nusage=noncommercial-development-only\n'
  } >"$OUTPUT/runtime-receipt.txt"
  local ledger_tmp
  ledger_tmp="$(mktemp "$output_parent/.indextts25-sha256.XXXXXX")"
  trap 'rm -f "$ledger_tmp"' EXIT
  (
    cd "$OUTPUT"
    find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' \
      | LC_ALL=C sort -z \
      | xargs -0 sha256sum >"$ledger_tmp"
    mv "$ledger_tmp" SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  )
  trap - EXIT
  printf 'INDEXTTS25_NO_GUIDE_READY=%s\n' "$OUTPUT"
}

main "$@"
