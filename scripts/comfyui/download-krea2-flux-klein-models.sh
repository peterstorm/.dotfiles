#!/usr/bin/env bash
# Download the BF16 Krea 2 -> FLUX.2 Klein 9B refinement profile for ComfyUI.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="krea2-flux2-klein9b-bf16-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"
FLUX_LICENSE_URL="https://huggingface.co/black-forest-labs/FLUX.2-klein-9B/blob/92196c8e11f7b6cf2b7493e037d8c5345c559216/LICENSE.md"
FAMEGRID_LICENSE_URL="https://civitai.com/models/2088956?modelVersionId=3154245"
ULTRAREAL_LICENSE_URL="https://civitai.com/models/2462105?modelVersionId=3182356"

# sha256, exact bytes, repository, immutable revision, source, destination
read -r -d '' HF_MANIFEST <<'EOF' || true
0975d6b77b5f510b99547d6724a208e36527df654e8f6134f59ece3f9f30da58 18157185168 black-forest-labs/FLUX.2-klein-9B 92196c8e11f7b6cf2b7493e037d8c5345c559216 flux-2-klein-9b.safetensors diffusion_models/flux-2-klein-9b-bf16.safetensors
f0ff9239d56269ca1d05e5f86da6a79fac111af464955681f11c7ab0ec5ef6c1 16381517176 Comfy-Org/flux2-klein-9B 3f62d9d8ae1fec33c6e91453d5c712855b096b55 split_files/text_encoders/qwen_3_8b.safetensors text_encoders/qwen_3_8b_bf16.safetensors
d64f3a68e1cc4f9f4e29b6e0da38a0204fe9a49f2d4053f0ec1fa1ca02f9c4b5 336213556 Comfy-Org/flux2-dev ab9055628ea245000e610f2aa2c96f4746093546 split_files/vae/flux2-vae.safetensors vae/flux2-vae.safetensors
EOF

# sha256, exact bytes, immutable model-version URL, destination
read -r -d '' CIVITAI_MANIFEST <<'EOF' || true
233a8b1df4b3387f9f2bedaa2099d0e14cc946d1105f732de2a8600310b86f07 228588904 https://civitai.com/api/download/models/3182356?fileId=3062944 loras/ultra_real_krea2_v2_bf16.safetensors
40ce4ebd8af41f985ef7ff0b15c4989eacec155b9975c9649dbce00ba31fed46 228587744 https://civitai.com/api/download/models/3154245?fileId=3035036 loras/famegrid_standard_krea2_bf16.safetensors
EOF

# This profile depends on the existing standard Krea BF16 profile.
read -r -d '' KREA_DEPENDENCY_MANIFEST <<'EOF' || true
78bbf8f4165eda19cea3cb06c78089221932a39e2eed8af9da741f942c47ffb3 26283332608 diffusion_models/krea2_turbo_bf16.safetensors
36f3ff447ef59201722e8f9ce6020c9819fdcfba6aa2608c4e09b1c0ce114e34 8875719384 text_encoders/qwen3vl_4b_bf16.safetensors
a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f 253806246 vae/qwen_image_vae.safetensors
EOF

verification_manifest() {
  {
    awk 'NF == 6 { print $1, $2, $6 }' <<<"$HF_MANIFEST"
    awk 'NF == 4 { print $1, $2, $4 }' <<<"$CIVITAI_MANIFEST"
  }
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

stage_verified_existing() {
  local expected_sha="$1" expected_size="$2" relative="$3"
  local source="$MODELS_ROOT/$relative" staged="$STAGING/$relative"
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

resolve_civitai_token() {
  local token_file="${CIVITAI_TOKEN_FILE:-$HOME/.config/civitai/token}"
  if [ -n "${CIVITAI_TOKEN:-}" ]; then
    printf '%s' "$CIVITAI_TOKEN"
  elif [ -r "$token_file" ]; then
    local mode
    mode="$(stat -c %a "$token_file")"
    if ((8#$mode & 077)); then
      echo "error: Civitai token file must not be group/world accessible: $token_file" >&2
      return 1
    fi
    tr -d '\r\n' <"$token_file"
  else
    echo "error: Civitai authentication is required for the two pinned LoRAs" >&2
    echo "set CIVITAI_TOKEN_FILE to a mode-0600 token file (default: $token_file)" >&2
    return 1
  fi
}

download_civitai_file() {
  local url="$1" destination="$2" token="$3" config
  if ! [[ "$token" =~ ^[A-Za-z0-9_-]{20,}$ ]]; then
    echo "error: Civitai token has an invalid shape" >&2
    return 1
  fi
  mkdir -p "$(dirname "$destination")"
  config="$(mktemp "$STAGING/.civitai-curl.XXXXXX")"
  chmod 0600 "$config"
  printf '%s\n' \
    'fail' 'location' 'silent' 'show-error' 'retry = 3' 'continue-at = "-"' \
    "url = \"$url&token=$token\"" \
    "output = \"$destination\"" >"$config"
  if ! curl --config "$config"; then
    rm -f "$config"
    return 1
  fi
  rm -f "$config"
}

main() {
  local command expected_sha expected_size repo revision source relative url
  local repo_staging marker_tmp civitai_token="" civitai_download_needed=0

  if [ "${FLUX2_KLEIN_ACCEPT_NONCOMMERCIAL_LICENSE:-}" != yes ]; then
    cat >&2 <<EOF
error: FLUX.2 Klein 9B uses the FLUX Non-Commercial License.
Read $FLUX_LICENSE_URL and the linked Acceptable Use Policy. Re-run with
FLUX2_KLEIN_ACCEPT_NONCOMMERCIAL_LICENSE=yes only after accepting those terms.
EOF
    return 2
  fi
  if [ "${KREA2_FLUX_LORA_ACCEPT_LICENSES:-}" != yes ]; then
    cat >&2 <<EOF
error: the two Civitai LoRAs have creator-specific licenses.
Read $FAMEGRID_LICENSE_URL and $ULTRAREAL_LICENSE_URL. Re-run with
KREA2_FLUX_LORA_ACCEPT_LICENSES=yes only after accepting both sets of terms.
EOF
    return 2
  fi

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
    echo "error: another Krea/FLUX Klein download owns $LOCK" >&2
    return 1
  fi

  if ! verify_manifest "$MODELS_ROOT" "$KREA_DEPENDENCY_MANIFEST"; then
    echo "error: standard BF16 Krea dependencies are incomplete" >&2
    echo "run scripts/comfyui/download-krea2-models.sh first" >&2
    return 1
  fi
  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    echo "Verifying the existing Krea 2 / FLUX.2 Klein BF16 profile..."
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "KREA2_FLUX2_KLEIN_MODELS_READY: $PROFILE_REV"
      return 0
    fi
    echo "Existing profile is incomplete or corrupt; resuming." >&2
  fi

  mkdir -p "$STAGING"
  while read -r expected_sha expected_size _ relative; do
    [ -n "$relative" ] || continue
    if ! stage_verified_existing "$expected_sha" "$expected_size" "$relative"; then
      civitai_download_needed=1
    fi
  done <<<"$CIVITAI_MANIFEST"
  if [ "$civitai_download_needed" -eq 1 ]; then
    civitai_token="$(resolve_civitai_token)"
  fi

  export HF_HUB_DISABLE_XET=1
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

  while read -r expected_sha expected_size url relative; do
    [ -n "$relative" ] || continue
    if stage_verified_existing "$expected_sha" "$expected_size" "$relative"; then
      continue
    fi
    download_civitai_file "$url" "$STAGING/$relative.part" "$civitai_token"
    mv -f "$STAGING/$relative.part" "$STAGING/$relative"
  done <<<"$CIVITAI_MANIFEST"
  unset CIVITAI_TOKEN civitai_token

  echo "Verifying five pinned Krea 2 / FLUX.2 Klein artifacts..."
  verify_manifest "$STAGING" "$(verification_manifest)"
  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    install_file "$relative"
  done < <(verification_manifest)

  marker_tmp="$MARKER.new"
  {
    printf '%s\n' "$PROFILE_REV"
    printf '%s\n' "$HF_MANIFEST"
    printf '%s\n' "$CIVITAI_MANIFEST"
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"
  echo "KREA2_FLUX2_KLEIN_MODELS_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
