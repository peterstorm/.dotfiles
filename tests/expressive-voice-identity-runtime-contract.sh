#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
VOX_DOCKERFILE="$ROOT/scripts/inference/voice/Dockerfile.voxcpm2"
BREEZE_DOCKERFILE="$ROOT/scripts/inference/voice/Dockerfile.breeze-tts2"
BUILD="$ROOT/scripts/inference/voice/build-expressive-voice-identity-images.sh"
GENERATE="$ROOT/scripts/inference/voice/generate_expressive_voice_identity_auditions.py"
RUN="$ROOT/scripts/inference/voice/run-expressive-voice-identity-auditions.sh"

contains() {
  grep -Fq -- "$2" "$1" || { echo "missing contract in $1: $2" >&2; exit 1; }
}

for file in "$VOX_DOCKERFILE" "$BREEZE_DOCKERFILE" "$BUILD" "$GENERATE" "$RUN"; do
  test -f "$file"
done
bash -n "$BUILD" "$RUN"

base='pytorch/pytorch:2.9.1-cuda13.0-cudnn9-runtime@sha256:60f22fb80755fd0b470fb47928dbd55816aa9f847edd95cf43c93253507a9ddf'
contains "$VOX_DOCKERFILE" "$base"
contains "$VOX_DOCKERFILE" 'VOXCPM_SOURCE_REV=f5a1c6a6b901bc732e20f0d59a369f6829ad717a'
contains "$VOX_DOCKERFILE" 'HF_HUB_OFFLINE=1'
contains "$BREEZE_DOCKERFILE" "$base"
contains "$BREEZE_DOCKERFILE" 'BREEZE_SOURCE_REV=ca632ce6c4d05f7985da4eab29b1a5d445b43f7b'
contains "$BREEZE_DOCKERFILE" 'qwen-tts==0.1.1'
contains "$BREEZE_DOCKERFILE" 'transformers==4.57.3'
contains "$BREEZE_DOCKERFILE" 'HF_HUB_OFFLINE=1'

contains "$GENERATE" '@dataclass(frozen=True)'
contains "$GENERATE" 'identity.candidates must contain exactly three entries'
contains "$GENERATE" 'the audition must be Development with no authority'
contains "$GENERATE" 'local_files_only=True'
contains "$GENERATE" 'attn_implementation="eager"'
contains "$GENERATE" 'nativeUnprocessed'
contains "$GENERATE" 'userSelectionRequired'
contains "$GENERATE" 'productionAuthority'

contains "$RUN" '--network none'
contains "$RUN" '--read-only'
contains "$RUN" '--cap-drop all'
contains "$RUN" '--security-opt no-new-privileges'
# Assert the literal runtime variable reference.
# shellcheck disable=SC2016
contains "$RUN" '--gpus "device=$GPU_DEVICE"'
contains "$RUN" 'dst=/models/model,readonly'
contains "$RUN" 'sha256sum -c SHA256SUMS'
contains "$RUN" 'productionAuthority: false'

if grep -Eq 'pip install|hf download|curl |wget ' "$RUN"; then
  echo "runtime script must not download or install anything" >&2
  exit 1
fi

echo EXPRESSIVE_VOICE_IDENTITY_RUNTIME_CONTRACT_PASS
