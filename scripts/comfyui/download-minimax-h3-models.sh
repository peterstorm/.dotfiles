#!/usr/bin/env bash
# Download the maximum-quality local MiniMax H3 ComfyUI profile: both original
# unpruned BF16 task families, BF16 Qwen3-VL encoder, both VAEs, and Turbo LoRAs.
set -euo pipefail

REPO="Comfy-Org/MiniMax-H3"
REV="dc559027db79c174125df4d827db55cd11178860"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-minimax-h3-bf16-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-bf16-complete"
LOCK="$MODELS_ROOT/.minimax-h3-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
MiniMax H3 weights require acceptance of the MiniMax-H3 Community License.
Set MINIMAX_H3_ACCEPT_LICENSE=yes only after reviewing:
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE
EOF
  exit 2
fi
if [ "${MINIMAX_H3_AUTHORIZED:-}" != "yes" ]; then
  echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
  exit 2
fi
if ! command -v hf >/dev/null 2>&1; then
  echo "error: the Hugging Face 'hf' CLI is required" >&2
  exit 1
fi
if ! python3 -c 'import hf_xet' >/dev/null 2>&1; then
  echo "error: hf_xet is required for MiniMax H3 files larger than regular Hub downloads support" >&2
  echo "apply the desktop NixOS configuration before downloading" >&2
  exit 1
fi
for command in flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

# sha256, exact bytes, destination relative to ComfyUI's model root
read -r -d '' MANIFEST <<'EOF' || true
907d4add438438ec1544f5240c3b38532ed934fe6be75677a6bbda2a6fdd6182 66280487368 diffusion_models/minimax_h3_fl2va_bf16.safetensors
e32c54c1a7b4f5f397f195cea267ccb18806303bb665678c4bee60953bdf3026 66280487368 diffusion_models/minimax_h3_ref2va_bf16.safetensors
600d567f6a9629c8574e8e7041b199bdd9c59a986afa7906910a81919610607d 51506295256 text_encoders/qwen3vl_32b_minimax_h3_bf16.safetensors
7c1f131492e7eddacaac9069a61b81bdd39de5cc96561e677c5eab1cdce5e522 5207808496 vae/minimax_h3_video_vae_fp16.safetensors
8e505d95dd1561d47abd43d4238fd40d9bb1ae9e147ed0a4cba778d76ae4db48 605254808 vae/minimax_h3_audio_vae_fp32.safetensors
c396a9a06f58399e9df9754b18299818d84a2ddd371724ba48fe4a41221437dc 1956192992 loras/minimax_h3_fl2v_turbo_4step_v1.0_768p_comfyui_bf16.safetensors
2339acdf19bfe123f46b971ea35d367a84adb85de43627e1eceafa5a5b2b111e 1956193000 loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors
5b9ab5ade15d0775676d01a907268a69a1468dc6033b3b0d3ded5502f3ebb84c 1956193000 loras/minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors
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

mkdir -p "$MODELS_ROOT"
exec 9>"$LOCK"
flock 9

if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER"; then
  echo "Verifying the existing MiniMax H3 BF16 profile..."
  if verify_manifest "$MODELS_ROOT"; then
    echo "MINIMAX_H3_MODELS_READY: $REPO@$REV"
    exit 0
  fi
  echo "Existing profile is incomplete or corrupt; resuming." >&2
fi

# Preserve the local-dir metadata and completed artifacts across retries. The
# pinned manifest remains the authority before anything reaches MODELS_ROOT.
mkdir -p "$STAGING"
mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
unset HF_HUB_DISABLE_XET
hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"

printf 'Verifying %d pinned MiniMax H3 BF16 artifacts...\n' "${#files[@]}"
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
  printf 'territorial-authorization-attested=yes\n'
  printf '%s\n' "$MANIFEST"
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "MINIMAX_H3_MODELS_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT"
