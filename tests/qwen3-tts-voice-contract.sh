#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKERFILE="$ROOT/scripts/inference/voice/Dockerfile.qwen3-tts"
BUILD="$ROOT/scripts/inference/voice/build-qwen3-tts-image.sh"
DOWNLOAD="$ROOT/scripts/inference/voice/download-qwen3-tts-voice-design.sh"
DOWNLOAD_BASE="$ROOT/scripts/inference/voice/download-qwen3-tts-base.sh"
GENERATE="$ROOT/scripts/inference/voice/generate_voice_design_auditions.py"
RUN="$ROOT/scripts/inference/voice/run-qwen3-tts-voice-auditions.sh"
RUN_BASE="$ROOT/scripts/inference/voice/run-qwen3-tts-base-calibration.sh"

contains() {
  grep -Fq -- "$2" "$1" || { echo "missing contract in $1: $2" >&2; exit 1; }
}

for file in "$DOCKERFILE" "$BUILD" "$DOWNLOAD" "$DOWNLOAD_BASE" "$GENERATE" "$RUN" "$RUN_BASE"; do
  test -f "$file"
done
bash -n "$BUILD" "$DOWNLOAD" "$DOWNLOAD_BASE" "$RUN" "$RUN_BASE"

contains "$DOCKERFILE" 'pytorch/pytorch:2.9.1-cuda13.0-cudnn9-runtime@sha256:60f22fb80755fd0b470fb47928dbd55816aa9f847edd95cf43c93253507a9ddf'
contains "$DOCKERFILE" 'QWEN3_TTS_REV=022e286b98fbec7e1e916cb940cdf532cd9f488e'
contains "$DOCKERFILE" 'transformers==4.57.3'
contains "$DOCKERFILE" 'sed -i '\''/  "gradio",/d'\'' /opt/qwen3-tts/pyproject.toml'
contains "$DOCKERFILE" 'HF_HUB_OFFLINE=1'
contains "$BUILD" 'QWEN3_TTS_IMAGE_ID='
contains "$BUILD" '--network none'

contains "$DOWNLOAD" 'Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign'
contains "$DOWNLOAD" '5ecdb67327fd37bb2e042aab12ff7391903235d3'
contains "$DOWNLOAD" '391e8db219f292c515297cdceeb43e4eae67cdde35fa57e79a6a8a532fca0522 3833402552 model.safetensors'
contains "$DOWNLOAD" '836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258 682293092 speech_tokenizer/model.safetensors'
contains "$DOWNLOAD" "verify_manifest \"\$STAGING\""

contains "$DOWNLOAD_BASE" 'Qwen/Qwen3-TTS-12Hz-1.7B-Base'
contains "$DOWNLOAD_BASE" 'fd4b254389122332181a7c3db7f27e918eec64e3'
contains "$DOWNLOAD_BASE" '38fc7fc51c5e776e840414b6fd443962e9411b9654888fd7913e4da643cb857c 3857413744 model.safetensors'
contains "$DOWNLOAD_BASE" '836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258 682293092 speech_tokenizer/model.safetensors'
contains "$DOWNLOAD_BASE" "verify_manifest \"\$STAGING\""

contains "$GENERATE" '@dataclass(frozen=True)'
contains "$GENERATE" 'language must equal English'
contains "$GENERATE" 'members must contain exactly four entries'
contains "$GENERATE" 'candidates must contain exactly three entries'
contains "$GENERATE" 'local_files_only=True'
contains "$GENERATE" 'attn_implementation="sdpa"'
contains "$GENERATE" 'subtype="PCM_16"'
contains "$GENERATE" 'SHA256SUMS'

contains "$RUN" '--network none'
contains "$RUN" '--read-only'
contains "$RUN" '--cap-drop all'
contains "$RUN" '--security-opt no-new-privileges'
contains "$RUN" "--gpus \"device=\$GPU_DEVICE\""
contains "$RUN" 'dst=/models/voice-design,readonly'
contains "$RUN" 'QWEN3_TTS_GENERATOR'
contains "$RUN" "src=\$GENERATOR,dst=/work/generate.py,readonly"
contains "$RUN" 'QWEN3_TTS_EXPECTED_IMAGE_ID'
contains "$RUN" 'sha256sum -c SHA256SUMS'
contains "$RUN_BASE" '--network none'
contains "$RUN_BASE" '--read-only'
contains "$RUN_BASE" '--cap-drop all'
contains "$RUN_BASE" '--security-opt no-new-privileges'
contains "$RUN_BASE" 'dst=/models/base,readonly'
contains "$RUN_BASE" 'dst=/anchors,readonly'
contains "$RUN_BASE" 'QWEN3_TTS_EXPECTED_IMAGE_ID'
contains "$RUN_BASE" 'Qwen/Qwen3-TTS-12Hz-1.7B-Base@fd4b254389122332181a7c3db7f27e918eec64e3'

for runtime in "$RUN" "$RUN_BASE"; do
  if grep -Eq 'pip install|hf download|curl |wget ' "$runtime"; then
    echo "runtime script must not download or install anything: $runtime" >&2
    exit 1
  fi
done

echo QWEN3_TTS_VOICE_CONTRACT_PASS
