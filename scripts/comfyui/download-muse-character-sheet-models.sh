#!/usr/bin/env bash
# Download the Muse Character Sheet model profile for ComfyUI (the models the
# two Muse Character Sheet workflows queue against): the RMBG-2.0 background
# removal family, the Face Detail Ultralytics detector models, and the two
# Krea 2 LoRAs the Krea2 graph wires. The Krea 2 / FLUX.2 Klein base models,
# encoders, VAEs, and the Identity Edit LoRA are owned by the existing
# profiles and verified here as dependencies.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="muse-character-sheet-models-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"
RMBG_LICENSE_URL="https://huggingface.co/briaai/RMBG-2.0"
DETECTOR_LICENSE_URL="https://github.com/ultralytics/ultralytics/blob/main/AGPL-3.0"

# sha256, exact bytes, repository, immutable revision, source, destination
read -r -d '' HF_MANIFEST <<'EOF' || true
566ed80c3d95f87ada6864d4cbe2290a1c5eb1c7bb0b123e984f60f76b02c3a7 884878856 1038lab/RMBG-2.0 1cd4787601caeb4c8e826dba7ea8e2163b5208df model.safetensors RMBG/RMBG-2.0/model.safetensors
c97ea21569daf66b205491a4635147dd3bc42c7c168b89d7d75b53f67ef548ae 405 1038lab/RMBG-2.0 1cd4787601caeb4c8e826dba7ea8e2163b5208df config.json RMBG/RMBG-2.0/config.json
8f498727f4bdb7dfaa4d66190f0ebf55392bda62c1b4f224be39f9b750a8915d 91320 1038lab/RMBG-2.0 1cd4787601caeb4c8e826dba7ea8e2163b5208df birefnet.py RMBG/RMBG-2.0/birefnet.py
e7b8c2a74f6cea6a59553d517f71d47f2c1d90e670a13416af17c25fe2f3dc52 298 1038lab/RMBG-2.0 1cd4787601caeb4c8e826dba7ea8e2163b5208df BiRefNet_config.py RMBG/RMBG-2.0/BiRefNet_config.py
5ec8728156b6c2c21d8d3bcfb6c09e010b9552c68d7b95c47589aa61cc727433 11524152 ivanlf98/DetailerKrea 06e27efaa7469217e371e03ce9ca36eac7f343fc Detailer-KREA2.safetensors loras/Krea2/Detailer-KREA2.safetensors
ec5901a2d0b8f4e4e1e7e62fe4567566f0837799f7a413b03a06f72f47934dda 160 uzumix/krea2filterbypass3.safetensors 66f26e38045ad7f34fd93e87ca6e7206552c7080 krea2filterbypass3.safetensors loras/Krea2/krea2filterbypass3.safetensors
717923c19b3f4bbf5250b728f1fa6b2cb72a33aed1d236ea9caf0e21ad943e5f 52026019 Bingsu/adetailer 53cc19de382014514d9d4038601d261a7faa9b7b face_yolov8m.pt ultralytics/bbox/face_yolov8m.pt
70b540063fbc385736d8258970744a4afbc4cbf7932134bae3b24cdadeadec06 22507643 Bingsu/adetailer 53cc19de382014514d9d4038601d261a7faa9b7b hand_yolov8s.pt ultralytics/bbox/hand_yolov8s.pt
c8ab26f517173b1fe8342d336a09f443eb61cb08dcbfc78d53fff4c2547ae81e 54827683 Bingsu/adetailer 53cc19de382014514d9d4038601d261a7faa9b7b person_yolov8m-seg.pt ultralytics/segm/person_yolov8m-seg.pt
EOF

# This profile depends on artifacts the existing Krea / Klein / Identity
# profiles already own; they are verified here, never re-downloaded.
read -r -d '' DEPENDENCY_MANIFEST <<'EOF' || true
6adf9a69cc9502d286db7b69964d37da7e9cfe4b05b4d004bc275f087d3fd3cf 1828256432 loras/krea2/krea2_identity_edit_v1_2.safetensors
0975d6b77b5f510b99547d6724a208e36527df654e8f6134f59ece3f9f30da58 18157185168 diffusion_models/flux-2-klein-9b-bf16.safetensors
f0ff9239d56269ca1d05e5f86da6a79fac111af464955681f11c7ab0ec5ef6c1 16381517176 text_encoders/qwen_3_8b_bf16.safetensors
d64f3a68e1cc4f9f4e29b6e0da38a0204fe9a49f2d4053f0ec1fa1ca02f9c4b5 336213556 vae/flux2-vae.safetensors
78bbf8f4165eda19cea3cb06c78089221932a39e2eed8af9da741f942c47ffb3 26283332608 diffusion_models/krea2_turbo_bf16.safetensors
36f3ff447ef59201722e8f9ce6020c9819fdcfba6aa2608c4e09b1c0ce114e34 8875719384 text_encoders/qwen3vl_4b_bf16.safetensors
a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f 253806246 vae/qwen_image_vae.safetensors
EOF

verification_manifest() {
  awk 'NF == 6 { print $1, $2, $6 }' <<<"$HF_MANIFEST"
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

  # RMBG-2.0 weights are gated upstream under bria's own license terms (the
  # muse pack's own model card claims Apache-2.0; the briaai model card is
  # the authoritative gate). Re-run with the acceptance flag only after
  # accepting those terms.
  if [ "${MUSE_SHEET_ACCEPT_RMBG_LICENSE:-}" != yes ]; then
    cat >&2 <<EOF
error: RMBG-2.0 is published upstream under bria's own license terms.
Read $RMBG_LICENSE_URL and accept its terms before downloading. Re-run with
MUSE_SHEET_ACCEPT_RMBG_LICENSE=yes only after accepting those terms.
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
    echo "error: another Muse Character Sheet download owns $LOCK" >&2
    return 1
  fi

  if ! verify_manifest "$MODELS_ROOT" "$DEPENDENCY_MANIFEST"; then
    echo "error: Muse Character Sheet dependencies are incomplete" >&2
    echo "run scripts/comfyui/download-krea2-models.sh and" >&2
    echo "scripts/comfyui/download-krea2-flux-klein-models.sh first" >&2
    return 1
  fi
  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    echo "Verifying the existing Muse Character Sheet model profile..."
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "MUSE_CHARACTER_SHEET_MODELS_READY: $PROFILE_REV"
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
  echo "MUSE_CHARACTER_SHEET_MODELS_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
  echo "detector models are AGPL-3.0 (see $DETECTOR_LICENSE_URL);"
  echo "the two Krea 2 LoRAs ship without a declared license - the"
  echo "Development-only note travels with the model."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
