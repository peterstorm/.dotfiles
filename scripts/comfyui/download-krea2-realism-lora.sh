#!/usr/bin/env bash
# Download the pinned gokaygokay Krea 2 Realism LoRA for ComfyUI.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="krea2-realism-lora-32f0436-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"
LICENSE_URL="https://huggingface.co/krea/Krea-2-Turbo/blob/main/LICENSE"

# sha256, exact bytes, repository, immutable revision, source, destination
read -r -d '' MANIFEST <<'EOF' || true
6c38a7934c54a56e0f67753660a4500a094d6dce28a0ee4a0d1dc9f4975d32d2 469288512 gokaygokay/Krea-2-Realism-LoRA 32f0436ac10e985134364e7555898c9f121a46ce krea2_realism_lora.safetensors loras/krea2_realism_lora.safetensors
EOF

# The LoRA is intended for the existing full-BF16 Krea 2 Turbo profile.
read -r -d '' KREA_DEPENDENCY_MANIFEST <<'EOF' || true
78bbf8f4165eda19cea3cb06c78089221932a39e2eed8af9da741f942c47ffb3 26283332608 diffusion_models/krea2_turbo_bf16.safetensors
36f3ff447ef59201722e8f9ce6020c9819fdcfba6aa2608c4e09b1c0ce114e34 8875719384 text_encoders/qwen3vl_4b_bf16.safetensors
a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f 253806246 vae/qwen_image_vae.safetensors
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

  if [ "${KREA2_ACCEPT_LICENSE:-}" != yes ]; then
    cat >&2 <<EOF
error: this LoRA is released under the Krea 2 Community License.
Read $LICENSE_URL and the acceptable-use terms. Re-run with
KREA2_ACCEPT_LICENSE=yes only after accepting those terms.
EOF
    return 2
  fi

  for command in hf sha256sum flock stat; do
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
    echo "error: another Krea realism LoRA download owns $LOCK" >&2
    return 1
  fi

  if ! verify_manifest "$MODELS_ROOT" "$KREA_DEPENDENCY_MANIFEST"; then
    echo "error: standard BF16 Krea dependencies are incomplete" >&2
    echo "run scripts/comfyui/download-krea2-models.sh first" >&2
    return 1
  fi
  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "KREA2_REALISM_LORA_READY: $PROFILE_REV"
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
  echo "KREA2_REALISM_LORA_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
