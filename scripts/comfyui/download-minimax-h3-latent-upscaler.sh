#!/usr/bin/env bash
# Download the pinned Stage-2 upscale model for the Muse Director two-stage
# sampling pass: LBH-123-AI's MiniMax H3 latent upscaler 3D fp16, installed
# under models/latent_upscale_models. The upstream repo does not declare a
# code license and the model card declares none; this download is authorized
# only for private local Development evaluation, not a Production or
# redistribution grant.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
PROFILE_REV="minimax-h3-latent-upscaler-3d-13ccf95-v1"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"

# sha256, exact bytes, repository, immutable revision, source, destination
read -r -d '' MANIFEST <<'EOF' || true
043e5a48e161610ef6c3ea974645220354d06fa618abca15f76d084812eb55c2 690592672 LBH-123-AI/Minimax_h3_latent_Upscaler 13ccf95d85d120bdbc92c05b1247a6e147bf54bf minimax_h3_latent_upscaler_3d_fp16.safetensors latent_upscale_models/minimax_h3_latent_upscaler_3d_fp16.safetensors
EOF

# The upscale model refines an unpruned BF16 MiniMax H3 latent; both task
# families and the BF16 encoder are its dependencies.
read -r -d '' H3_DEPENDENCY_MANIFEST <<'EOF' || true
907d4add438438ec1544f5240c3b38532ed934fe6be75677a6bbda2a6fdd6182 66280487368 diffusion_models/minimax_h3_fl2va_bf16.safetensors
e32c54c1a7b4f5f397f195cea267ccb18806303bb665678c4bee60953bdf3026 66280487368 diffusion_models/minimax_h3_ref2va_bf16.safetensors
600d567f6a9629c8574e8e7041b199bdd9c59a986afa7906910a81919610607d 51506295256 text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors
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

  if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != yes ]; then
    cat >&2 <<'EOF'
error: this upscale model is a derivative of MiniMax H3, whose original model
is governed by the MiniMax-H3 Community License. Read
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE and re-run with
MINIMAX_H3_ACCEPT_LICENSE=yes only after accepting those terms.
EOF
    return 2
  fi
  if [ "${MINIMAX_H3_AUTHORIZED:-}" != yes ]; then
    echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
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
    echo "error: another latent upscaler download owns $LOCK" >&2
    return 1
  fi

  if ! verify_manifest "$MODELS_ROOT" "$H3_DEPENDENCY_MANIFEST"; then
    echo "error: standard BF16 MiniMax H3 dependencies are incomplete" >&2
    echo "run scripts/comfyui/download-minimax-h3-models.sh first" >&2
    return 1
  fi
  if [ -f "$MARKER" ] && grep -Fxq "$PROFILE_REV" "$MARKER"; then
    if verify_manifest "$MODELS_ROOT" "$(verification_manifest)"; then
      echo "MINIMAX_H3_LATENT_UPSCALER_READY: $PROFILE_REV"
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
    hf download "$repo" "$source" \
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
  echo "MINIMAX_H3_LATENT_UPSCALER_READY: $PROFILE_REV"
  echo "model root: $MODELS_ROOT"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
