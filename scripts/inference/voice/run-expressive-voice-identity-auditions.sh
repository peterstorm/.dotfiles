#!/usr/bin/env bash
# Run a pinned reference-free VoxCPM2 or Breeze TTS 2 identity audition.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GENERATOR="${EXPRESSIVE_VOICE_IDENTITY_GENERATOR:-$SCRIPT_DIR/generate_expressive_voice_identity_auditions.py}"
SPEC="${VOICE_IDENTITY_SPEC:?set VOICE_IDENTITY_SPEC to an absolute JSON path}"
OUTPUT="${VOICE_IDENTITY_OUTPUT:?set VOICE_IDENTITY_OUTPUT to a new absolute output path}"
GPU_DEVICE="${VOICE_GPU_DEVICE:-0}"
MODEL_ROOT_BASE="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"

require_absolute() {
  [[ "$1" = /* ]] || { echo "error: path must be absolute: $1" >&2; return 1; }
}

resolve_engine() {
  local engine="$1"
  case "$engine" in
    voxcpm2)
      IMAGE="${VOXCPM2_IMAGE:-peterstorm/voxcpm2:f5a1c6a-cu130}"
      MODEL_ROOT="$MODEL_ROOT_BASE/voxcpm2-32279eff"
      MODEL_MARKER="$MODEL_ROOT_BASE/.voxcpm2-32279eff.complete"
      EXPECTED_SOURCE_REV="f5a1c6a6b901bc732e20f0d59a369f6829ad717a"
      EXPECTED_MODEL_REV="32279effe8c19989596f05d353d1447f51d9e915"
      ;;
    breeze-tts2)
      IMAGE="${BREEZE_TTS2_IMAGE:-peterstorm/breeze-tts2:ca632ce-cu130}"
      MODEL_ROOT="$MODEL_ROOT_BASE/breeze-tts2-c1c8ca18"
      MODEL_MARKER="$MODEL_ROOT_BASE/.breeze-tts2-c1c8ca18.complete"
      EXPECTED_SOURCE_REV="ca632ce6c4d05f7985da4eab29b1a5d445b43f7b"
      EXPECTED_MODEL_REV="c1c8ca18b70b30822735633991d9ebf4898e47d4"
      ;;
    *)
      echo "error: unsupported engine: $engine" >&2
      return 2
      ;;
  esac
}

main() {
  require_absolute "$SPEC"
  require_absolute "$GENERATOR"
  require_absolute "$OUTPUT"
  test -f "$SPEC" || { echo "error: specification is unavailable: $SPEC" >&2; return 1; }
  test -f "$GENERATOR" || { echo "error: generator is unavailable: $GENERATOR" >&2; return 1; }
  test ! -e "$OUTPUT" || { echo "error: output path already exists: $OUTPUT" >&2; return 1; }

  local engine specification_model_revision image_id image_revision used_mib output_parent output_name
  engine="$(jq -er '.engine' "$SPEC")"
  resolve_engine "$engine"
  specification_model_revision="$(jq -er '.model.revision' "$SPEC")"
  [ "$specification_model_revision" = "$EXPECTED_MODEL_REV" ] || {
    echo "error: model revision mismatch in specification: $specification_model_revision" >&2
    return 1
  }
  test -d "$MODEL_ROOT" || { echo "error: model directory is unavailable: $MODEL_ROOT" >&2; return 1; }
  test -f "$MODEL_MARKER" || { echo "error: verified model marker is unavailable: $MODEL_MARKER" >&2; return 1; }

  image_id="$(docker image inspect "$IMAGE" --format '{{.Id}}')"
  image_revision="$(docker image inspect "$IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.revision"}}')"
  [ "$image_revision" = "$EXPECTED_SOURCE_REV" ] || {
    echo "error: image source revision mismatch: $image_revision" >&2
    return 1
  }

  docker run --rm --network none --read-only --cap-drop all \
    --security-opt no-new-privileges \
    --user "$(id -u):$(id -g)" \
    --tmpfs /tmp:rw,nosuid,nodev,size=1g,mode=1777 \
    --mount "type=bind,src=$SPEC,dst=/input/spec.json,readonly" \
    --mount "type=bind,src=$GENERATOR,dst=/work/generate.py,readonly" \
    "$image_id" python /work/generate.py --spec /input/spec.json --validate-only

  used_mib="$(nvidia-smi --id="$GPU_DEVICE" --query-gpu=memory.used --format=csv,noheader,nounits | tr -d ' ')"
  [[ "$used_mib" =~ ^[0-9]+$ ]] || { echo "error: cannot parse GPU memory use: $used_mib" >&2; return 1; }
  if (( used_mib > 4096 )); then
    echo "error: GPU $GPU_DEVICE is not free enough for voice generation (${used_mib} MiB used)" >&2
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
    --shm-size 16g \
    --tmpfs /tmp:rw,nosuid,nodev,size=16g,mode=1777 \
    --env HOME=/tmp/home \
    --env USER=voice \
    --env LOGNAME=voice \
    --env HF_HOME=/tmp/huggingface \
    --env XDG_CACHE_HOME=/tmp/cache \
    --mount "type=bind,src=$MODEL_ROOT,dst=/models/model,readonly" \
    --mount "type=bind,src=$SPEC,dst=/input/spec.json,readonly" \
    --mount "type=bind,src=$GENERATOR,dst=/work/generate.py,readonly" \
    --mount "type=bind,src=$output_parent,dst=/output" \
    "$image_id" \
    python /work/generate.py --spec /input/spec.json --output "/output/$output_name"

  (
    cd "$OUTPUT"
    sha256sum -c SHA256SUMS >/dev/null
    jq -n \
      --arg image "$IMAGE" \
      --arg imageId "$image_id" \
      --arg sourceRevision "$image_revision" \
      --arg modelRevision "$EXPECTED_MODEL_REV" \
      --arg gpu "$GPU_DEVICE" \
      '{
        image: $image,
        imageId: $imageId,
        sourceRevision: $sourceRevision,
        modelRevision: $modelRevision,
        gpu: ($gpu | tonumber),
        network: "none",
        gpuRuntimeStarted: true,
        productionAuthority: false
      }' >runtime-receipt.json
    sha256sum runtime-receipt.json >>SHA256SUMS
    sha256sum -c SHA256SUMS >/dev/null
  )
  printf 'EXPRESSIVE_VOICE_IDENTITY_AUDITIONS_READY=%s\n' "$OUTPUT"
}

main "$@"
