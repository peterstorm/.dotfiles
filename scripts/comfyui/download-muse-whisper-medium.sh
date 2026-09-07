#!/usr/bin/env bash
# Install the one transcription profile exposed by the workstation-hardened
# Muse Director: Systran faster-whisper-medium at an immutable revision.
set -euo pipefail

REPO="Systran/faster-whisper-medium"
REV="08e178d48790749d25932bbc082711ddcfdfbc4f"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
DESTINATION="$MODELS_ROOT/audio_encoders/faster-whisper-medium"
STAGING="$MODELS_ROOT/.staging-muse-whisper-medium-$REV"
MARKER="$MODELS_ROOT/.muse-whisper-medium-complete"
LOCK="$MODELS_ROOT/.muse-whisper-medium-download.lock"

# sha256, exact bytes, file relative to the pinned repository root
read -r -d '' MANIFEST <<'EOF' || true
3622a2ddc41ec0e0fd4e68c13c6830f03b90c38d89aaad184de02c8c642cf807 2257 config.json
9b45e1009dcc4ab601eff815b61d80e60ce3fd8c74c1a14f4a282258286b51ae 1527906378 model.bin
fb7b63191e9bb045082c79fd742a3106a12c99513ab30df4a0d47fa6cb6fd0ab 2203239 tokenizer.json
34ce3fe1c5041027b3f8d42912270993f986dbc4bb34cf27f951e34a1e453913 459861 vocabulary.txt
EOF

verify_manifest() {
  local root="$1" expected_sha expected_size relative file actual_size actual_sha
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    if [ ! -f "$file" ]; then
      echo "missing: $relative" >&2
      return 1
    fi
    actual_size="$(stat -c %s "$file")"
    if [ "$actual_size" != "$expected_size" ]; then
      echo "size mismatch: $relative (expected $expected_size, got $actual_size)" >&2
      return 1
    fi
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "checksum mismatch: $relative" >&2
      return 1
    fi
  done <<<"$MANIFEST"
}

install_file() {
  local relative="$1"
  install -m 0640 "$STAGING/$relative" "$DESTINATION/$relative.new"
  mv -f "$DESTINATION/$relative.new" "$DESTINATION/$relative"
}

main() {
  local command relative marker_tmp
  local -a files=()

  for command in hf sha256sum flock stat; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required command is unavailable: $command" >&2
      echo "apply the desktop NixOS configuration before downloading" >&2
      return 1
    }
  done
  mkdir -p "$MODELS_ROOT"
  if [ ! -w "$MODELS_ROOT" ]; then
    echo "error: model root is not writable by $USER: $MODELS_ROOT" >&2
    return 1
  fi

  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "error: another Muse Whisper download owns $LOCK" >&2
    return 1
  fi

  if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER"; then
    if verify_manifest "$DESTINATION"; then
      echo "MUSE_WHISPER_MEDIUM_READY: $REPO@$REV"
      return 0
    fi
    echo "Existing Muse Whisper profile is incomplete or corrupt; resuming." >&2
  fi

  rm -rf "$STAGING"
  mkdir -p "$STAGING" "$DESTINATION"
  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    files+=("$relative")
  done <<<"$MANIFEST"

  HF_HUB_DISABLE_XET=1 hf download "$REPO" "${files[@]}" \
    --revision "$REV" --local-dir "$STAGING"
  verify_manifest "$STAGING"

  for relative in "${files[@]}"; do
    install_file "$relative"
  done
  verify_manifest "$DESTINATION"

  marker_tmp="$MARKER.new"
  {
    printf '%s@%s\n' "$REPO" "$REV"
    printf '%s\n' "$MANIFEST"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"

  echo "MUSE_WHISPER_MEDIUM_READY: $REPO@$REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
