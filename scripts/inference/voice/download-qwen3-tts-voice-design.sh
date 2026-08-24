#!/usr/bin/env bash
# Download and verify the exact Qwen3-TTS VoiceDesign model used for auditions.
set -euo pipefail

REPO="Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
REV="5ecdb67327fd37bb2e042aab12ff7391903235d3"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice/qwen3-tts}"
DESTINATION="$MODELS_ROOT/voice-design-1.7b"
STAGING="$MODELS_ROOT/.staging-voice-design-$REV"
MARKER="$MODELS_ROOT/.qwen3-tts-voice-design-complete"
LOCK="$MODELS_ROOT/.qwen3-tts-voice-design.lock"

read -r -d '' MANIFEST <<'EOF' || true
11ad7efa24975ee4b0c3c3a38ed18737f0658a5f75a0a96787b576a78a023361 1519 .gitattributes
acfaf6c0d433866cb5e2bb73e7915ea3767f5a2e3abca413b485635a2c72b5e6 3214 README.md
aecd2cc4c1fe9edef1cb7ca7c401685a43879ad43f3f9e883f1c6760b61731e0 4421 config.json
f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa 245 generation_config.json
599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3 1671839 merges.txt
391e8db219f292c515297cdceeb43e4eae67cdde35fa57e79a6a8a532fca0522 3833402552 model.safetensors
efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119 127 preprocessor_config.json
ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167 2336 speech_tokenizer/config.json
6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd 76 speech_tokenizer/configuration.json
836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258 682293092 speech_tokenizer/model.safetensors
fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb 234 speech_tokenizer/preprocessor_config.json
dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670 7344 tokenizer_config.json
ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910 2776833 vocab.json
EOF

verify_manifest() {
  local root="$1" expected_sha expected_size relative file actual_size actual_sha
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    [ -f "$file" ] || { echo "missing: $relative" >&2; return 1; }
    actual_size="$(stat -c %s "$file")"
    [ "$actual_size" = "$expected_size" ] || {
      echo "size mismatch: $relative (expected $expected_size, got $actual_size)" >&2
      return 1
    }
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    [ "$actual_sha" = "$expected_sha" ] || {
      echo "checksum mismatch: $relative" >&2
      return 1
    }
  done <<<"$MANIFEST"
}

main() {
  command -v hf >/dev/null 2>&1 || { echo "error: Hugging Face 'hf' CLI is required" >&2; return 1; }
  local dependency
  for dependency in flock sha256sum stat; do
    command -v "$dependency" >/dev/null 2>&1 || { echo "error: missing command: $dependency" >&2; return 1; }
  done

  mkdir -p "$MODELS_ROOT"
  exec 9>"$LOCK"
  flock 9

  if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER" && verify_manifest "$DESTINATION"; then
    echo "QWEN3_TTS_VOICE_DESIGN_READY: $REPO@$REV"
    return 0
  fi

  rm -rf "$STAGING"
  mkdir -p "$STAGING"
  local files=() relative marker_tmp
  mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
  unset HF_HUB_DISABLE_XET
  hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"
  verify_manifest "$STAGING"

  rm -rf "$DESTINATION.new"
  mv "$STAGING" "$DESTINATION.new"
  chmod -R u=rwX,g=rX,o= "$DESTINATION.new"
  rm -rf "$DESTINATION"
  mv "$DESTINATION.new" "$DESTINATION"

  marker_tmp="$MARKER.new"
  {
    printf '%s@%s\n' "$REPO" "$REV"
    printf 'license=Apache-2.0\n'
    printf '%s\n' "$MANIFEST"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv "$marker_tmp" "$MARKER"

  echo "QWEN3_TTS_VOICE_DESIGN_READY: $REPO@$REV"
  echo "model path: $DESTINATION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
