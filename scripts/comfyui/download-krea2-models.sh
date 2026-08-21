#!/usr/bin/env bash
# Download the production Krea 2 local profile for the Nix-managed ComfyUI.
#
# The profile contains highest-fidelity BF16 Turbo text-to-image weights plus
# the official INT8 style-reference path and Krea's nine released style LoRAs.
# Every artifact is pinned to one Hugging Face revision and verified by size +
# SHA-256 before an atomic rename into /models/comfyui.
set -euo pipefail

REPO="Comfy-Org/Krea-2"
REV="e5ea8b4dd7f38f348b138eb0fe29f92c0e367e96"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-krea2-$REV"
MARKER="$MODELS_ROOT/.krea2-production-complete"
LOCK="$MODELS_ROOT/.krea2-download.lock"
LICENSE_URL="https://www.krea.ai/krea-2-licensing"

if [ "${KREA2_ACCEPT_LICENSE:-}" != yes ]; then
  cat >&2 <<EOF
error: Krea 2 uses the Krea 2 Community License, not an open-source weight license.
Read $LICENSE_URL, including the commercial revenue threshold, content-filter duty,
and acceptable-use terms. Re-run with KREA2_ACCEPT_LICENSE=yes only after accepting it.
EOF
  exit 2
fi

for command in hf sha256sum flock stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is unavailable: $command" >&2
    echo "apply the desktop NixOS configuration before downloading" >&2
    exit 1
  }
done

if [ ! -d "$MODELS_ROOT" ]; then
  sudo install -d -m 0750 -o "$USER" -g users "$MODELS_ROOT"
fi
if [ ! -w "$MODELS_ROOT" ]; then
  echo "error: model root is not writable by $USER: $MODELS_ROOT" >&2
  exit 1
fi

# sha256, exact bytes, repository-relative path
read -r -d '' MANIFEST <<'EOF' || true
78bbf8f4165eda19cea3cb06c78089221932a39e2eed8af9da741f942c47ffb3 26283332608 diffusion_models/krea2_turbo_bf16.safetensors
8e4eeda70dd5037ab1ba2bef6b417f9f901e26093117cf397f741fc1fdaaf3f1 13492686496 diffusion_models/krea2_turbo_int8_convrot.safetensors
36f3ff447ef59201722e8f9ce6020c9819fdcfba6aa2608c4e09b1c0ce114e34 8875719384 text_encoders/qwen3vl_4b_bf16.safetensors
54bd5144df0bbc25dd6ccadfcb826b521445a1b06ae5a42570bdd2974ca87094 5242467968 text_encoders/qwen3vl_4b_fp8_scaled.safetensors
a70580f0213e67967ee9c95f05bb400e8fb08307e017a924bf3441223e023d1f 253806246 vae/qwen_image_vae.safetensors
f50df5a9e62e4be8aa926a63dd5bb1a64770c4004f763c1208007ae13daa82b8 457111760 loras/krea2_style_reference.safetensors
f47c4316dd93af66e0518c93b582f459571d4925b519133770c73a52cd5db7c6 469291992 loras/krea2_darkbrush.safetensors
805aa30d863347222485b9d3ce81642dbc70a73cebc95ab57219d98b878fceec 469291992 loras/krea2_dotmatrix.safetensors
8c1d45d204aeb4e34a7d9e16a7d473917592ba0048b03f4e03e037e3578ca500 469291992 loras/krea2_kidsdrawing.safetensors
a779c14435949eabae9ce0bface4320cad6672ef3547e8489107e3498d65e871 469291992 loras/krea2_neondrip.safetensors
7063a6f15ec6112ad3c06d79097b2a30a3ea7d9072821cb36021010d55989fe5 469291992 loras/krea2_rainywindow.safetensors
ca42107783d9e517c5d62cb9a9db9ab2ba4887d90e9dad97a9d1a7fe6ff14c56 469291992 loras/krea2_retroanime.safetensors
3805e8655f19fbcac116542685e3f78f3a642e8fbfb857b5352bb32a4b3d445a 469291992 loras/krea2_softwatercolor.safetensors
194abdd531ca190d32799f26ab5bab634aa5ba3f07b7a60ffb282657db8bf3a0 469291992 loras/krea2_sunsetblur.safetensors
8cca96c56658fb3ac5269f9ef2245bd07cbf1b7a189f517c8763470bb1385f9f 469291992 loras/krea2_vintagetarot.safetensors
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

exec 9>"$LOCK"
if ! flock -n 9; then
  echo "error: another Krea 2 download or verification owns $LOCK" >&2
  exit 1
fi

if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER"; then
  echo "Verifying the existing Krea 2 production profile..."
  if verify_manifest "$MODELS_ROOT"; then
    echo "KREA2_MODELS_READY: $REPO@$REV"
    exit 0
  fi
  echo "Existing profile is incomplete or corrupt; resuming the pinned download." >&2
fi

mkdir -p "$STAGING"
mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
export HF_HUB_DISABLE_XET=1
hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"

printf 'Verifying %d pinned artifacts...\n' "${#files[@]}"
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
  printf '%s\n' "$MANIFEST"
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "KREA2_MODELS_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT"
