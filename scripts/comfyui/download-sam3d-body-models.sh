#!/usr/bin/env bash
# Download the SAM 3D Body workstation model profile: the four pinned artifacts
# the dedicated SAM 3D Body workflow queues against, each kept at its exact
# repository revision under models/<folder>/ — nothing is converted on disk.
#
#   checkpoints/sam3.1_multiplex_fp16.safetensors      (SAM 3.1 multiplex — SAM3 VideoTrack)
#   detection/sam_3d_body_dinov3_bf16.safetensors      (SAM 3D Body DiT)
#   geometry_estimation/moge_2_vitl_normal_fp16.safetensors (MoGe-2 metric scale → FoV)
#   diffusion_models/rt_detr_v4-x-hgnet_fp32.safetensors    (RT-DETR person bboxes)
#
# The bf16 SAM 3D Body release is pinned, not the optional int8 ConvRot
# quantization — the same BF16-profile discipline as the rest of the stack.
set -euo pipefail

MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-sam3d-body-models"
MARKER="$MODELS_ROOT/.sam3d-body-models-complete"
LOCK="$MODELS_ROOT/.sam3d-body-models-download.lock"

if [ "${SAM3D_BODY_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
sam3.1 and sam-3d-body weights ship under the Meta sam-license.
Set SAM3D_BODY_ACCEPT_LICENSE=yes only after reviewing:
https://huggingface.co/facebook/sam-3d-body-dinov3/blob/main/LICENSE
MoGe-2 is MIT (Microsoft); RT-DETR (SDPose repack) is MIT.
EOF
  exit 2
fi
if ! command -v hf >/dev/null 2>&1; then
  echo "error: the Hugging Face 'hf' CLI is required" >&2
  exit 1
fi
for command in flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

# sha256, exact bytes, repo, pinned revision, path relative to the repo root.
# The destination folder name equals the repo-relative folder name, matching
# the workstation's modelSubdirectories entries exactly.
read -r -d '' MANIFEST <<'EOF' || true
9ba99c92703c2e8b4f47de2d34a539bb8e18923049e238b780d70dbe6368eb03 1745546848 Comfy-Org/sam3.1 f38cd62b71494b53ac2b56ca36e24f3c8d565581 checkpoints/sam3.1_multiplex_fp16.safetensors
59fa45200c504c5b56625004d7d3385daf48c616613e88099e43bf83b3e249cf 2830737652 Comfy-Org/sam-3d-body 60476aced0b8de0a0e82a318c79a85061cc97434 detection/sam_3d_body_dinov3_bf16.safetensors
cb1a692d03235671e959e81360d7b4d9f44aefadb1f852d6ca6aa17799d5e31f 661859924 Comfy-Org/MoGe 14cbe5bcaaab2fcabaccac085b24a82af2669b14 geometry_estimation/moge_2_vitl_normal_fp16.safetensors
1ba4a7794c2f8b176327c887ba38fbe0f977049cbef149960288aa923d0239f3 247790660 Comfy-Org/SDPose f122ac7976997885e3bfeab2bb3a537a6bc250bc diffusion_models/rt_detr_v4-x-hgnet_fp32.safetensors
EOF

# Staged layout: STAGING/<repo>/<relative>.
verify_staged() {
  local expected_sha expected_size repo revision relative file actual_size actual_sha
  while read -r expected_sha expected_size repo revision relative; do
    [ -n "$relative" ] || continue
    file="$STAGING/$repo/$relative"
    if [ ! -f "$file" ]; then
      echo "missing: $repo/$relative" >&2
      return 1
    fi
    actual_size="$(stat -c %s "$file")"
    if [ "$actual_size" != "$expected_size" ]; then
      echo "size mismatch: $repo/$relative (expected $expected_size, got $actual_size)" >&2
      return 1
    fi
    actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
    if [ "$actual_sha" != "$expected_sha" ]; then
      echo "checksum mismatch: $repo/$relative" >&2
      return 1
    fi
  done <<<"$MANIFEST"
}

# Installed layout: MODELS_ROOT/<relative>.
verify_installed() {
  local expected_sha expected_size repo revision relative file actual_size actual_sha
  while read -r expected_sha expected_size repo revision relative; do
    [ -n "$relative" ] || continue
    file="$MODELS_ROOT/$relative"
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

if [ -f "$MARKER" ]; then
  complete=yes
  while read -r _ _ repo revision _; do
    [ -n "$repo" ] || continue
    grep -Fxq "$repo@$revision" "$MARKER" || complete=no
  done <<<"$MANIFEST"
  if [ "$complete" = "yes" ]; then
    echo "Verifying the existing SAM 3D Body profile..."
    if verify_installed; then
      echo "SAM3D_BODY_MODELS_READY: pinned profile"
      exit 0
    fi
  fi
  echo "Existing profile is incomplete or corrupt; resuming." >&2
fi

# Preserve completed artifacts across retries. The pinned manifest remains the
# authority before anything reaches MODELS_ROOT.
rm -rf "$STAGING"
mkdir -p "$STAGING"
unset HF_HUB_DISABLE_XET
while read -r _ _ repo revision _; do
  [ -n "$repo" ] || continue
  mapfile -t files < <(awk -v r="$repo" -v v="$revision" '$3 == r && $4 == v { print $5 }' <<<"$MANIFEST")
  hf download "$repo" "${files[@]}" --revision "$revision" --local-dir "$STAGING/$repo"
done <<<"$MANIFEST"

printf 'Verifying %d pinned SAM 3D Body artifacts...\n' "$(wc -l <<<"$MANIFEST")"
verify_staged
while read -r _ _ repo _ relative; do
  [ -n "$relative" ] || continue
  destination="$MODELS_ROOT/$relative"
  mkdir -p "$(dirname "$destination")"
  mv -f "$STAGING/$repo/$relative" "$destination.new"
  chmod 0640 "$destination.new"
  mv -f "$destination.new" "$destination"
done <<<"$MANIFEST"

marker_tmp="$MARKER.new"
{
  while read -r _ _ repo revision _; do
    [ -n "$repo" ] || continue
    printf '%s@%s\n' "$repo" "$revision"
  done <<<"$MANIFEST"
  printf '%s\n' "$MANIFEST"
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "SAM3D_BODY_MODELS_READY: pinned profile"
echo "model root: $MODELS_ROOT"
