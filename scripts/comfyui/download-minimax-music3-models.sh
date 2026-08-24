#!/usr/bin/env bash
# Download the full-quality local MiniMax Music 3 ComfyUI profile: FP16 DiT,
# unpruned BF16 text encoder, and the full DAV audio decoder.
set -euo pipefail

REPO="Comfy-Org/MiniMax-Music-3"
REV="6baad88896848433857c170ba4f05d2ea9d5f218"
LICENSE_URL="https://huggingface.co/MiniMaxAI/MiniMax-Music3/blob/945655064d59b98004dd70002e7eb5c8c6e11373/LICENSE"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-minimax-music3-full-$REV"
MARKER="$MODELS_ROOT/.minimax-music3-full-quality-complete"
LOCK="$MODELS_ROOT/.minimax-music3-download.lock"

# sha256, exact bytes, destination relative to ComfyUI's model root
read -r -d '' MANIFEST <<'EOF' || true
45494a2b6b69af115902ff28eaf54118d19067aa54da01000f3e3efce7ba0e34 4914197682 diffusion_models/minimax_music3_dit_fp16.safetensors
9805d045978ce917cd1e6327b5cd8b85df1a46e4c69b61c9acf3eb29891c3958 18472478038 text_encoders/minimax_music3_text_encoder_bf16.safetensors
2a32155b769be01445fcc2a8663b910fc9e1751e18dc1c3ec528064512d9ef0c 216696128 vae/minimax_music3_dav.safetensors
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

main() {
  if [ "${MINIMAX_MUSIC3_ACCEPT_LICENSE:-}" != "yes" ]; then
    cat >&2 <<EOF
MiniMax Music 3 weights require acceptance of the MiniMax-Music3 Community License.
Set MINIMAX_MUSIC3_ACCEPT_LICENSE=yes only after reviewing:
$LICENSE_URL
EOF
    return 2
  fi
  if ! command -v hf >/dev/null 2>&1; then
    echo "error: the Hugging Face 'hf' CLI is required" >&2
    return 1
  fi
  if ! python3 -c 'import hf_xet' >/dev/null 2>&1; then
    echo "error: hf_xet is required for the full BF16 text encoder" >&2
    echo "apply the desktop NixOS configuration before downloading" >&2
    return 1
  fi
  local command
  for command in flock sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required command is missing: $command" >&2
      return 1
    }
  done

  mkdir -p "$MODELS_ROOT"
  exec 9>"$LOCK"
  flock 9

  if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER"; then
    echo "Verifying the existing MiniMax Music 3 full-quality profile..."
    if verify_manifest "$MODELS_ROOT"; then
      echo "MINIMAX_MUSIC3_MODELS_READY: $REPO@$REV"
      return 0
    fi
    echo "Existing profile is incomplete or corrupt; resuming." >&2
  fi

  # Preserve completed files in staging across retries. The immutable manifest
  # remains authoritative before any file reaches the model root.
  mkdir -p "$STAGING"
  local files=() relative destination marker_tmp
  mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
  unset HF_HUB_DISABLE_XET
  hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"

  printf 'Verifying %d pinned MiniMax Music 3 artifacts...\n' "${#files[@]}"
  verify_manifest "$STAGING"
  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    destination="$MODELS_ROOT/$relative"
    mkdir -p "$(dirname "$destination")"
    mv -f "$STAGING/$relative" "$destination.new"
    chmod 0640 "$destination.new"
    mv -f "$destination.new" "$destination"
  done <<<"$MANIFEST"

  marker_tmp="$MARKER.new"
  {
    printf '%s@%s\n' "$REPO" "$REV"
    printf 'license=%s\n' "$LICENSE_URL"
    printf 'quality=fp16-dit+unpruned-bf16-text-encoder+full-dav\n'
    printf '%s\n' "$MANIFEST"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"

  echo "MINIMAX_MUSIC3_MODELS_READY: $REPO@$REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
