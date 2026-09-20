#!/usr/bin/env bash
# Download the workstation's MiniMax H3 Singularity action-candidate profile:
# the full 34 GB v1.3 INT8 fine-tune and its task-matched Ref2V 8-step LoRA.
set -euo pipefail

SINGULARITY_REPO="WarmBloodAban/Minimax-h3_Singularity"
SINGULARITY_REV="af671d9214a6e41ab8c2f43e9f871ea56246115f"
TURBO_REPO="lightx2v/Minimax-h3-Turbo"
TURBO_REV="3ec17a324ced54151364f24f8b5fb6bf7e26414f"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-minimax-h3-singularity-v1.3"
MARKER="$MODELS_ROOT/.minimax-h3-singularity-v1.3-complete"
LOCK="$MODELS_ROOT/.minimax-h3-singularity-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
MiniMax H3 derivative weights require acceptance of the MiniMax-H3 Community License.
The Singularity repository's Apache tag does not replace the base-model terms.
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
  echo "error: hf_xet is required for the 34 GB Singularity checkpoint" >&2
  echo "apply the desktop NixOS configuration before downloading" >&2
  exit 1
fi
for command in flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

# repository|revision|source path|sha256|exact bytes|destination under model root
read -r -d '' MANIFEST <<'EOF' || true
WarmBloodAban/Minimax-h3_Singularity|af671d9214a6e41ab8c2f43e9f871ea56246115f|Minimax-h3_Singularity_ref2va_v1.3_int8.safetensors|551915097b8727537a82f3a2c5acec965165ec84e780b3e9a5f28ce867fddf08|34004507622|diffusion_models/minimax_h3_singularity_ref2va_v1.3_int8.safetensors
lightx2v/Minimax-h3-Turbo|3ec17a324ced54151364f24f8b5fb6bf7e26414f|minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors|6a56f41ab4229c9dd845b9501bbd475ee57e112d846cf2e819d534a1ae928c5a|1956193000|loras/minimax_h3_ref2v_turbo_8step_v1.0_768p_comfyui_bf16.safetensors
EOF

verify_file() {
  local file=$1 expected_sha=$2 expected_size=$3 label=$4 actual_size actual_sha
  if [ ! -f "$file" ]; then
    echo "missing: $label" >&2
    return 1
  fi
  actual_size="$(stat -c %s "$file")"
  if [ "$actual_size" != "$expected_size" ]; then
    echo "size mismatch: $label (expected $expected_size, got $actual_size)" >&2
    return 1
  fi
  actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
  if [ "$actual_sha" != "$expected_sha" ]; then
    echo "checksum mismatch: $label" >&2
    return 1
  fi
}

verify_installed() {
  local repo revision source expected_sha expected_size destination
  while IFS='|' read -r repo revision source expected_sha expected_size destination; do
    [ -n "$destination" ] || continue
    verify_file "$MODELS_ROOT/$destination" "$expected_sha" "$expected_size" "$destination" || return 1
  done <<<"$MANIFEST"
}

mkdir -p "$MODELS_ROOT"
exec 9>"$LOCK"
flock 9

if [ -f "$MARKER" ] \
  && grep -Fxq "$SINGULARITY_REPO@$SINGULARITY_REV" "$MARKER" \
  && grep -Fxq "$TURBO_REPO@$TURBO_REV" "$MARKER"; then
  echo "Verifying the existing MiniMax H3 Singularity profile..."
  if verify_installed; then
    echo "MINIMAX_H3_SINGULARITY_READY: v1.3 action candidate"
    exit 0
  fi
  echo "Existing profile is incomplete or corrupt; resuming." >&2
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
index=0
while IFS='|' read -r repo revision source expected_sha expected_size destination; do
  [ -n "$destination" ] || continue
  index=$((index + 1))
  artifact_staging="$STAGING/$index"
  mkdir -p "$artifact_staging"
  unset HF_HUB_DISABLE_XET
  hf download "$repo" "$source" --revision "$revision" --local-dir "$artifact_staging"
  verify_file "$artifact_staging/$source" "$expected_sha" "$expected_size" "$repo@$revision/$source"
done <<<"$MANIFEST"

index=0
while IFS='|' read -r repo revision source expected_sha expected_size destination; do
  [ -n "$destination" ] || continue
  index=$((index + 1))
  target="$MODELS_ROOT/$destination"
  mkdir -p "$(dirname "$target")"
  mv -f "$STAGING/$index/$source" "$target.new"
  chmod 0640 "$target.new"
  mv -f "$target.new" "$target"
done <<<"$MANIFEST"

verify_installed
marker_tmp="$MARKER.new"
{
  printf '%s@%s\n' "$SINGULARITY_REPO" "$SINGULARITY_REV"
  printf '%s@%s\n' "$TURBO_REPO" "$TURBO_REV"
  printf 'territorial-authorization-attested=yes\n'
  printf '%s\n' "$MANIFEST"
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "MINIMAX_H3_SINGULARITY_READY: v1.3 action candidate"
echo "model root: $MODELS_ROOT"
