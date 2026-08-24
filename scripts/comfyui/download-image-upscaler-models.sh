#!/usr/bin/env bash
# Install the immutable local still-image upscaler qualification profile.
set -euo pipefail

SEEDVR_REPO="numz/SeedVR2_comfyUI"
SEEDVR_REV="09ced71023636e9bc8cdf9cdecfb2625d1e691e8"
REALESRGAN_RELEASE="https://github.com/xinntao/Real-ESRGAN/releases/download"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_ID="image-upscalers-v1-$SEEDVR_REV"
STAGING="$MODELS_ROOT/.staging-$PROFILE_ID"
MARKER="$MODELS_ROOT/.$PROFILE_ID.complete"
LOCK="$MODELS_ROOT/.$PROFILE_ID.lock"

# sha256, exact bytes, source filename, destination relative to model root
read -r -d '' HF_MANIFEST <<'EOF' || true
2fd0e03a3dad24e07086750360727ca437de4ecd456f769856e960ae93e2b304 6783018808 seedvr2_ema_3b_fp16.safetensors SEEDVR2/seedvr2_ema_3b_fp16.safetensors
7b8241aa957606ab6cfb66edabc96d43234f9819c5392b44d2492d9f0b0bbe4a 16479334424 seedvr2_ema_7b_fp16.safetensors SEEDVR2/seedvr2_ema_7b_fp16.safetensors
20a93e01ff24beaeebc5de4e4e5be924359606c356c9c51509fba245bd2d77dd 16479334424 seedvr2_ema_7b_sharp_fp16.safetensors SEEDVR2/seedvr2_ema_7b_sharp_fp16.safetensors
20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1 501324814 ema_vae_fp16.safetensors SEEDVR2/ema_vae_fp16.safetensors
EOF

# sha256, exact bytes, immutable URL, destination relative to model root
read -r -d '' URL_MANIFEST <<EOF || true
4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1 67040989 $REALESRGAN_RELEASE/v0.1.0/RealESRGAN_x4plus.pth upscale_models/RealESRGAN_x4plus.pth
8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292 4885111 $REALESRGAN_RELEASE/v0.2.5.0/realesr-general-x4v3.pth upscale_models/realesr-general-x4v3.pth
EOF

verification_manifest() {
  awk 'NF == 4 { print $1, $2, $4 }' <<<"$HF_MANIFEST"
  awk 'NF == 4 { print $1, $2, $4 }' <<<"$URL_MANIFEST"
}

verify_file() {
  local file="$1" expected_sha="$2" expected_size="$3"
  [ -f "$file" ] \
    && [ "$(stat -c %s "$file")" = "$expected_size" ] \
    && [ "$(sha256sum "$file" | cut -d' ' -f1)" = "$expected_sha" ]
}

verify_manifest() {
  local root="$1" expected_sha expected_size relative file
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    if ! verify_file "$file" "$expected_sha" "$expected_size"; then
      echo "missing or corrupt: $relative" >&2
      return 1
    fi
  done < <(verification_manifest)
}

stage_verified_existing() {
  local expected_sha="$1" expected_size="$2" relative="$3"
  local staged="$STAGING/$relative" installed="$MODELS_ROOT/$relative"
  if verify_file "$staged" "$expected_sha" "$expected_size"; then
    return 0
  fi
  rm -f -- "$staged"
  if verify_file "$installed" "$expected_sha" "$expected_size"; then
    mkdir -p "$(dirname "$staged")"
    ln "$installed" "$staged"
    return 0
  fi
  return 1
}

install_staged_file() {
  local relative="$1"
  local source="$STAGING/$relative" destination="$MODELS_ROOT/$relative"
  mkdir -p "$(dirname "$destination")"
  if [ -e "$destination" ] && [ "$source" -ef "$destination" ]; then
    rm -f -- "$source"
    return 0
  fi
  mv -f "$source" "$destination.new"
  chmod 0640 "$destination.new"
  mv -f "$destination.new" "$destination"
}

main() {
  local command expected_sha expected_size source relative target marker_tmp
  for command in curl flock hf sha256sum stat; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required command is unavailable: $command" >&2
      return 1
    }
  done

  umask 0027
  mkdir -p "$MODELS_ROOT"
  exec 9>"$LOCK"
  flock 9

  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_ID" "$MARKER"; then
    echo "Verifying the existing still-image upscaler profile..."
    if verify_manifest "$MODELS_ROOT"; then
      echo "IMAGE_UPSCALER_MODELS_READY: $PROFILE_ID"
      return 0
    fi
    echo "Existing profile is incomplete or corrupt; resuming." >&2
  fi

  mkdir -p "$STAGING/.hf"
  local hf_sources=()
  while read -r expected_sha expected_size source relative; do
    [ -n "$relative" ] || continue
    if ! stage_verified_existing "$expected_sha" "$expected_size" "$relative"; then
      hf_sources+=("$source")
    fi
  done <<<"$HF_MANIFEST"

  if [ "${#hf_sources[@]}" -gt 0 ]; then
    hf download "$SEEDVR_REPO" "${hf_sources[@]}" \
      --revision "$SEEDVR_REV" --local-dir "$STAGING/.hf"
  fi
  while read -r expected_sha expected_size source relative; do
    [ -n "$relative" ] || continue
    target="$STAGING/$relative"
    if ! verify_file "$target" "$expected_sha" "$expected_size"; then
      mkdir -p "$(dirname "$target")"
      mv -f "$STAGING/.hf/$source" "$target"
    fi
  done <<<"$HF_MANIFEST"

  while read -r expected_sha expected_size source relative; do
    [ -n "$relative" ] || continue
    if stage_verified_existing "$expected_sha" "$expected_size" "$relative"; then
      continue
    fi
    target="$STAGING/$relative"
    mkdir -p "$(dirname "$target")"
    curl --fail --location --retry 5 --retry-all-errors \
      --continue-at - --output "$target" "$source"
  done <<<"$URL_MANIFEST"

  printf 'Verifying %d pinned upscaler artifacts...\n' \
    "$(verification_manifest | wc -l)"
  verify_manifest "$STAGING"
  while read -r _ _ relative; do
    [ -n "$relative" ] || continue
    install_staged_file "$relative"
  done < <(verification_manifest)

  marker_tmp="$MARKER.new"
  {
    printf '%s\n' "$PROFILE_ID"
    printf 'seedvr=%s@%s\n' "$SEEDVR_REPO" "$SEEDVR_REV"
    printf 'seedvr-license=Apache-2.0\n'
    printf 'realesrgan-license=BSD-3-Clause\n'
    verification_manifest
  } >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$MARKER"
  rm -rf "$STAGING"

  echo "IMAGE_UPSCALER_MODELS_READY: $PROFILE_ID"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
