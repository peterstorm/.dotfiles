#!/usr/bin/env bash
# Run an offline, GPU-isolated Qwen3-TTS VoiceDesign audition batch.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="${QWEN3_TTS_IMAGE:-peterstorm/qwen3-tts:0.1.1-022e286-cu130}"
EXPECTED_REV="022e286b98fbec7e1e916cb940cdf532cd9f488e"
MODEL_ROOT="${QWEN3_TTS_VOICE_DESIGN_ROOT:-/models/voice/qwen3-tts/voice-design-1.7b}"
MODEL_MARKER="${QWEN3_TTS_MODEL_MARKER:-/models/voice/qwen3-tts/.qwen3-tts-voice-design-complete}"
SPEC="${VOICE_AUDITION_SPEC:?set VOICE_AUDITION_SPEC to an absolute JSON path}"
OUTPUT="${VOICE_AUDITION_OUTPUT:?set VOICE_AUDITION_OUTPUT to a new absolute output path}"
GPU_DEVICE="${VOICE_GPU_DEVICE:-0}"

require_absolute() {
  [[ "$1" = /* ]] || { echo "error: path must be absolute: $1" >&2; return 1; }
}

main() {
  require_absolute "$SPEC"
  require_absolute "$OUTPUT"
  test -f "$SPEC" || { echo "error: specification is unavailable: $SPEC" >&2; return 1; }
  test -d "$MODEL_ROOT" || { echo "error: model directory is unavailable: $MODEL_ROOT" >&2; return 1; }
  grep -Fxq "Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign@5ecdb67327fd37bb2e042aab12ff7391903235d3" "$MODEL_MARKER" || {
    echo "error: verified VoiceDesign marker is absent or wrong" >&2
    return 1
  }
  test ! -e "$OUTPUT" || { echo "error: output path already exists: $OUTPUT" >&2; return 1; }

  local image_id image_rev used_mib output_parent output_name
  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  image_rev="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [ "$image_rev" = "$EXPECTED_REV" ] || { echo "error: image revision mismatch: $image_rev" >&2; return 1; }
  if [ -n "${QWEN3_TTS_EXPECTED_IMAGE_ID:-}" ] && [ "$image_id" != "$QWEN3_TTS_EXPECTED_IMAGE_ID" ]; then
    echo "error: image ID mismatch (expected $QWEN3_TTS_EXPECTED_IMAGE_ID, got $image_id)" >&2
    return 1
  fi

  used_mib="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
  [[ "$used_mib" =~ ^[0-9]+$ ]] || { echo "error: cannot parse GPU memory use: $used_mib" >&2; return 1; }
  if (( used_mib > 4096 )); then
    echo "error: GPU $GPU_DEVICE is not free enough for voice qualification (${used_mib} MiB used)" >&2
    return 1
  fi

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
    --mount "type=bind,src=$MODEL_ROOT,dst=/models/voice-design,readonly" \
    --mount "type=bind,src=$SPEC,dst=/input/spec.json,readonly" \
    --mount "type=bind,src=$SCRIPT_DIR/generate_voice_design_auditions.py,dst=/work/generate.py,readonly" \
    --mount "type=bind,src=$output_parent,dst=/output" \
    "$image_id" \
    python /work/generate.py --spec /input/spec.json --output "/output/$output_name"

  (cd "$OUTPUT" && sha256sum -c SHA256SUMS >/dev/null)
  {
    printf 'image=%s\n' "$IMAGE"
    printf 'image_id=%s\n' "$image_id"
    printf 'source_revision=%s\n' "$image_rev"
    printf 'gpu=%s\n' "$GPU_DEVICE"
  } >"$OUTPUT/runtime-receipt.txt"
  chmod 0640 "$OUTPUT/runtime-receipt.txt"
  (cd "$OUTPUT" && sha256sum runtime-receipt.txt >>SHA256SUMS && sha256sum -c SHA256SUMS >/dev/null)
  printf 'QWEN3_TTS_VOICE_AUDITIONS_READY=%s\n' "$OUTPUT"
}

main "$@"
