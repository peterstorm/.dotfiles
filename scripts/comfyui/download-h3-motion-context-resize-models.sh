#!/usr/bin/env bash
# Download the H3 Motion Context Resize model profile for ComfyUI: the 3D
# latent upscaler weights the Motion Context Resize v1.1 workflow's
# post-upscale pass queues against. The H3 Motion Context MultiRef pack, the
# resize node, and the upscaler node are owned by the declarative Nix pins;
# nothing here downloads at runtime beyond this profile.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="h3-motion-context-resize-models-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"
UPSCALER_LICENSE_URL="https://huggingface.co/LBH-123-AI/Minimax_h3_latent_Upscaler"

# sha256, exact bytes, repository, immutable revision, source, destination.
# The HF repo ships only the conv_v1 weights; the BF16 file is the
# highest-quant checkpoint available (fp16 and fp32.pth are deliberately not
# part of this profile). The video's example workflow still names the retired
# fp16 file in its selector - re-pick the installed file on the canvas.
read -r -d '' HF_MANIFEST <<'EOF' || true
4f57821f5837f32f7142b67d815606dbd7550f194e5c769f7d6c3f83b146a5e6 690592992 LBH-123-AI/Minimax_h3_latent_Upscaler 3f941d5d182014dd5c0a5e16330420ee2d4aa0c6 minimax_h3_latent_upscaler_3d_conv_v1/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors latent_upscale_models/minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors
EOF

verify_manifest() {
  local root="$1" manifest="$2" expected_sha expected_size relative file actual_size actual_sha
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
  done <<<"$manifest"
}

stage_verified_existing() {
  local expected_sha="$1" expected_size="$2" relative="$3"
  local source="$MODELS_ROOT/$relative" staged="$STAGING/$relative"
  if verify_manifest "$STAGING" "$expected_sha $expected_size $relative" \
    >/dev/null 2>&1; then
    return 0
  fi
  if ! verify_manifest "$MODELS_ROOT" "$expected_sha $expected_size $relative" \
    >/dev/null 2>&1; then
    return 1
  fi
  mkdir -p "$(dirname "$staged")"
  rm -f "$staged"
  ln "$source" "$staged"
}

install_file() {
  local relative="$1" destination staged
  destination="$MODELS_ROOT/$relative"
  staged="$STAGING/$relative"
  mkdir -p "$(dirname "$destination")"
  if [ -e "$destination" ] && [ "$staged" -ef "$destination" ]; then
    chmod 0640 "$destination"
    rm -f "$staged"
    return 0
  fi
  mv -f "$staged" "$destination.new"
  chmod 0640 "$destination.new"
  mv -f "$destination.new" "$destination"
}

main() {
  local command expected_sha expected_size repo revision source relative repo_staging

  for command in curl hf sha256sum flock stat; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required command is unavailable: $command" >&2
      echo "apply the desktop NixOS configuration before downloading" >&2
      return 1
    }
  done
  if [ ! -d "$MODELS_ROOT" ]; then
    sudo install -d -m 0750 -o "$USER" -g users "$MODELS_ROOT"
  fi
  if [ ! -w "$MODELS_ROOT" ]; then
    echo "error: model root is not writable by $USER: $MODELS_ROOT" >&2
    return 1
  fi

  exec 9>"$LOCK"
  if ! flock -n 9; then
    echo "error: another H3 Motion Context Resize download owns $LOCK" >&2
    return 1
  fi

  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    echo "Verifying the existing H3 Motion Context Resize model profile..."
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "H3_MOTION_CONTEXT_RESIZE_MODELS_READY: $PROFILE_REV"
      return 0
    fi
    echo "Existing profile is incomplete or corrupt; resuming." >&2
  fi

  mkdir -p "$STAGING"
  while read -r expected_sha expected_size repo revision source relative; do
    [ -n "$relative" ] || continue
    if stage_verified_existing "$expected_sha" "$expected_size" "$relative"; then
      continue
    fi
    repo_staging="$STAGING/.repositories/${repo//\//--}"
    hf download "$repo" "$source" --revision "$revision" --local-dir "$repo_staging"
    mkdir -p "$(dirname "$STAGING/$relative")"
    mv -f "$repo_staging/$source" "$STAGING/$relative"
  done <<<"$HF_MANIFEST"

  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    install_file "$relative"
  done < <(verification_manifest)

  marker_tmp="$MARKER.new"
  printf '%s\n' "$PROFILE_REV" >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"
  echo "H3_MOTION_CONTEXT_RESIZE_MODELS_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
  echo "the 3D latent upscaler ships without a declared license (see"
  echo "$UPSCALER_LICENSE_URL) - the Development-only note travels with"
  echo "the model."

}
verification_manifest() {
  awk 'NF == 6 { print $1, $2, $6 }' <<<"$HF_MANIFEST"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
