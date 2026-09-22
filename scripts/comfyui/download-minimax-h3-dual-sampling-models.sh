#!/usr/bin/env bash
# Download the one model artifact not already owned by the workstation's
# MiniMax H3 profiles: Alissonerdx's rank-64 LMS detail LoRA used by the
# Dual Sampling refinement pass. The LoRA is Apache-2.0; the MiniMax H3 base
# model remains subject to its Community License and territorial restriction.
set -euo pipefail

REPO="Alissonerdx/Minimax-H3-ComfyUI"
REV="0ff489e781c274d17b2e3a30cd6f9a8d40ca49ff"
SOURCE="loras/minimax_h3_lms_v1.0_r64.safetensors"
SHA256="16f3195bc6bffa431c0598dc2031e520ba058b4fcbc9f104db9e3fdfdeacf60c"
SIZE="1239664536"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
DESTINATION="$MODELS_ROOT/loras/minimax_h3_lms_v1.0_r64.safetensors"
STAGING="$MODELS_ROOT/.staging-minimax-h3-dual-sampling-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-dual-sampling-lms-complete"
LOCK="$MODELS_ROOT/.minimax-h3-dual-sampling-lms.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != yes ]; then
  cat >&2 <<'EOF'
error: the LMS LoRA is a MiniMax H3 derivative. Review and accept the base
Community License before setting MINIMAX_H3_ACCEPT_LICENSE=yes:
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE
EOF
  exit 2
fi
if [ "${MINIMAX_H3_AUTHORIZED:-}" != yes ]; then
  echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
  exit 2
fi
for command in hf flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is unavailable: $command" >&2
    echo "apply the desktop NixOS configuration before downloading" >&2
    exit 1
  }
done

verify_file() {
  local file="$1" actual_size actual_sha
  [ -f "$file" ] || return 1
  actual_size="$(stat -c %s "$file")"
  [ "$actual_size" = "$SIZE" ] || return 1
  actual_sha="$(sha256sum "$file")"
  actual_sha="${actual_sha%% *}"
  [ "$actual_sha" = "$SHA256" ]
}

mkdir -p "$MODELS_ROOT"
exec 9>"$LOCK"
flock 9

if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER" \
  && verify_file "$DESTINATION"; then
  echo "MINIMAX_H3_DUAL_SAMPLING_LMS_READY: $REPO@$REV"
  exit 0
fi

rm -rf "$STAGING"
mkdir -p "$STAGING"
unset HF_HUB_DISABLE_XET
hf download "$REPO" "$SOURCE" --revision "$REV" --local-dir "$STAGING"
verify_file "$STAGING/$SOURCE" || {
  echo "error: LMS LoRA failed pinned size/sha256 verification" >&2
  exit 1
}
mkdir -p "$(dirname "$DESTINATION")"
mv -f "$STAGING/$SOURCE" "$DESTINATION.new"
chmod 0640 "$DESTINATION.new"
mv -f "$DESTINATION.new" "$DESTINATION"
verify_file "$DESTINATION"

marker_tmp="$MARKER.new"
{
  printf '%s@%s\n' "$REPO" "$REV"
  printf '%s %s %s\n' "$SHA256" "$SIZE" "loras/${SOURCE##*/}"
  printf 'territorial-authorization-attested=yes\n'
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "MINIMAX_H3_DUAL_SAMPLING_LMS_READY: $REPO@$REV"
echo "model: $DESTINATION"
