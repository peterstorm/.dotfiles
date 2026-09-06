#!/usr/bin/env bash
# Download the lightweight LTX2.3 preview VAE (madebyollin/taehv) for the Model
# Preview Override nodes: installed under models/vae, then selected as a
# separate Load VAE feeding the preview override vae input. Tiny cosmetic
# preview only - the workflow runs fine without it.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="tiny-preview-vae-taeltx2-3-011dfc2-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"

# sha256, exact bytes, repository, immutable revision, source, destination
read -r -d '' MANIFEST <<'EOF' || true
f0773b4e3e57318e6aa4dd4a35e1d16213a5f160fbc0376163f06888bbcbe246 23531296 madebyollin/taehv 011dfc2112197741c540e0bdd5b7b67bcc930771 taeltx2_3.safetensors vae/taeltx2_3.safetensors
EOF

verification_manifest() {
  awk 'NF == 6 { print $1, $2, $6 }' <<<"$MANIFEST"
}

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

install_file() {
  local relative="$1" destination staged
  destination="$MODELS_ROOT/$relative"
  staged="$STAGING/$relative"
  mkdir -p "$(dirname "$destination")"
  mv -f "$staged" "$destination.new"
  chmod 0640 "$destination.new"
  mv -f "$destination.new" "$destination"
}

main() {
  local command expected_sha expected_size repo revision source relative repo_staging marker_tmp

  for command in hf sha256sum flock stat curl; do
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
    echo "error: another tiny preview VAE download owns $LOCK" >&2
    return 1
  fi

  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "TINY_PREVIEW_VAE_READY: $PROFILE_REV"
      return 0
    fi
    echo "Existing profile is incomplete or corrupt; resuming." >&2
  fi

  mkdir -p "$STAGING"
  while read -r expected_sha expected_size repo revision source relative; do
    [ -n "$relative" ] || continue
    if verify_manifest "$MODELS_ROOT" "$expected_sha $expected_size $relative" \
      >/dev/null 2>&1; then
      mkdir -p "$(dirname "$STAGING/$relative")"
      ln -f "$MODELS_ROOT/$relative" "$STAGING/$relative"
      continue
    fi
    repo_staging="$STAGING/.repositories/${repo//\//--}"
    HF_HUB_DISABLE_XET=1 hf download "$repo" "$source" \
      --revision "$revision" --local-dir "$repo_staging"
    mkdir -p "$(dirname "$STAGING/$relative")"
    mv -f "$repo_staging/$source" "$STAGING/$relative"
  done <<<"$MANIFEST"

  verify_manifest "$STAGING" "$(verification_manifest)"
  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    if [ -e "$MODELS_ROOT/$relative" ] && [ "$STAGING/$relative" -ef "$MODELS_ROOT/$relative" ]; then
      rm -f "$STAGING/$relative"
    else
      install_file "$relative"
    fi
  done < <(verification_manifest)

  marker_tmp="$MARKER.new"
  {
    printf '%s\n' "$PROFILE_REV"
    printf '%s\n' "$MANIFEST"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"
  echo "TINY_PREVIEW_VAE_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
