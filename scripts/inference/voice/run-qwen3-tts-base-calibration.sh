#!/usr/bin/env bash
# Run one immutable, offline Qwen3-TTS Base direct-clone calibration.
set -euo pipefail

IMAGE="${QWEN3_TTS_IMAGE:-peterstorm/qwen3-tts:0.1.1-022e286-cu130}"
EXPECTED_SOURCE_REV="022e286b98fbec7e1e916cb940cdf532cd9f488e"
MODEL_ROOT="${QWEN3_TTS_BASE_ROOT:-/models/voice/qwen3-tts/base-1.7b}"
MODEL_MARKER="${QWEN3_TTS_BASE_MARKER:-/models/voice/qwen3-tts/.qwen3-tts-base-complete}"
SPEC="${QWEN3_TTS_BASE_SPEC:?set QWEN3_TTS_BASE_SPEC to an absolute JSON path}"
ANCHORS_ROOT="${QWEN3_TTS_ANCHORS_ROOT:?set QWEN3_TTS_ANCHORS_ROOT to the canonical-01 directory}"
GENERATOR="${QWEN3_TTS_BASE_GENERATOR:?set QWEN3_TTS_BASE_GENERATOR to the generator path}"
OUTPUT="${QWEN3_TTS_BASE_OUTPUT:?set QWEN3_TTS_BASE_OUTPUT to a new absolute output path}"
GPU_DEVICE="${VOICE_GPU_DEVICE:-0}"

require_absolute() {
  [[ "$1" = /* ]] || { echo "error: path must be absolute: $1" >&2; return 1; }
}

main() {
  local path image_id image_rev used_mib output_parent output_name ledger_tmp
  for path in "$SPEC" "$ANCHORS_ROOT" "$GENERATOR" "$OUTPUT"; do
    require_absolute "$path"
  done
  [[ -f "$SPEC" ]] || { echo "error: specification is unavailable: $SPEC" >&2; return 1; }
  [[ -d "$ANCHORS_ROOT" ]] || { echo "error: anchors root is unavailable: $ANCHORS_ROOT" >&2; return 1; }
  [[ -f "$GENERATOR" ]] || { echo "error: generator is unavailable: $GENERATOR" >&2; return 1; }
  [[ -d "$MODEL_ROOT" ]] || { echo "error: model directory is unavailable: $MODEL_ROOT" >&2; return 1; }
  grep -Fxq 'Qwen/Qwen3-TTS-12Hz-1.7B-Base@fd4b254389122332181a7c3db7f27e918eec64e3' "$MODEL_MARKER" || {
    echo "error: verified Base marker is absent or wrong" >&2
    return 1
  }
  [[ ! -e "$OUTPUT" ]] || { echo "error: output path already exists: $OUTPUT" >&2; return 1; }

  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  image_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [[ "$image_rev" == "$EXPECTED_SOURCE_REV" ]] || { echo "error: image revision mismatch: $image_rev" >&2; return 1; }
  if [[ -n "${QWEN3_TTS_EXPECTED_IMAGE_ID:-}" && "$image_id" != "$QWEN3_TTS_EXPECTED_IMAGE_ID" ]]; then
    echo "error: image ID mismatch (expected $QWEN3_TTS_EXPECTED_IMAGE_ID, got $image_id)" >&2
    return 1
  fi

  used_mib="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
  [[ "$used_mib" =~ ^[0-9]+$ ]] || { echo "error: cannot parse GPU memory use: $used_mib" >&2; return 1; }
  (( used_mib <= 4096 )) || { echo "error: GPU $GPU_DEVICE is not free enough (${used_mib} MiB used)" >&2; return 1; }

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
    --shm-size 8g \
    --tmpfs /tmp:rw,nosuid,nodev,size=8g,mode=1777 \
    --env HF_HOME=/tmp/huggingface \
    --env XDG_CACHE_HOME=/tmp/cache \
    --mount "type=bind,src=$MODEL_ROOT,dst=/models/base,readonly" \
    --mount "type=bind,src=$ANCHORS_ROOT,dst=/anchors,readonly" \
    --mount "type=bind,src=$SPEC,dst=/input/spec.json,readonly" \
    --mount "type=bind,src=$GENERATOR,dst=/work/generate.py,readonly" \
    --mount "type=bind,src=$output_parent,dst=/output" \
    "$image_id" \
    python /work/generate.py --spec /input/spec.json --output "/output/$output_name"

  {
    printf 'image=%s\n' "$IMAGE"
    printf 'image_id=%s\n' "$image_id"
    printf 'source_revision=%s\n' "$image_rev"
    printf 'model=Qwen/Qwen3-TTS-12Hz-1.7B-Base@fd4b254389122332181a7c3db7f27e918eec64e3\n'
    printf 'gpu=%s\n' "$GPU_DEVICE"
    printf 'network=none\n'
  } >"$OUTPUT/runtime-receipt.txt"
  chmod 0640 "$OUTPUT/runtime-receipt.txt"

  ledger_tmp="$(mktemp "$output_parent/.qwen3-tts-base-sha256.XXXXXX")"
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
  printf 'QWEN3_TTS_BASE_CALIBRATION_READY=%s\n' "$OUTPUT"
}

main "$@"
