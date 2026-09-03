#!/usr/bin/env bash
# Install the pinned BF16 curve-form MiniMax H3 Fun ControlNet used by the
# declarative ComfyUI-H3-FunControl node.
set -euo pipefail

REPO="Kijai/MiniMax-H3-experimental"
REV="f4cac997f880e93cf6940af61ee8d58ef31ff7f3"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
RELATIVE="controlnet/minimax_h3_fun_controlnet_union_pruned_bf16.safetensors"
EXPECTED_SHA256="57fe1e64928a63a55e3cd4586b55cd5d0eb4980648b6f31e5d9dac16fe7f1c48"
EXPECTED_BYTES="4222169456"
STAGING="$MODELS_ROOT/.staging-minimax-h3-fun-controlnet-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-fun-controlnet-complete"
LOCK="$MODELS_ROOT/.minimax-h3-fun-controlnet-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
MiniMax H3 derivative weights require acceptance of the MiniMax-H3 Community License.
Set MINIMAX_H3_ACCEPT_LICENSE=yes only after reviewing:
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE
EOF
  exit 2
fi
if [ "${MINIMAX_H3_AUTHORIZED:-}" != "yes" ]; then
  echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
  exit 2
fi
for command in hf flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done
if ! python3 -c 'import hf_xet' >/dev/null 2>&1; then
  echo "error: hf_xet is required for the ControlNet checkpoint" >&2
  exit 1
fi

verify_artifact() {
  local root="$1" file actual_size actual_sha
  file="$root/$RELATIVE"
  [ -f "$file" ] || {
    echo "missing: $RELATIVE" >&2
    return 1
  }
  actual_size="$(stat -c %s "$file")"
  [ "$actual_size" = "$EXPECTED_BYTES" ] || {
    echo "size mismatch: $RELATIVE (expected $EXPECTED_BYTES, got $actual_size)" >&2
    return 1
  }
  actual_sha="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual_sha" = "$EXPECTED_SHA256" ] || {
    echo "checksum mismatch: $RELATIVE" >&2
    return 1
  }
}

mkdir -p "$MODELS_ROOT"
exec 9>"$LOCK"
flock 9

if [ -f "$MARKER" ] && grep -Fxq "$REPO@$REV" "$MARKER"; then
  echo "Verifying the existing MiniMax H3 Fun ControlNet..."
  if verify_artifact "$MODELS_ROOT"; then
    echo "MINIMAX_H3_FUN_CONTROLNET_READY: $REPO@$REV"
    exit 0
  fi
  echo "Existing ControlNet is incomplete or corrupt; resuming." >&2
fi

mkdir -p "$STAGING"
unset HF_HUB_DISABLE_XET
hf download "$REPO" "$RELATIVE" --revision "$REV" --local-dir "$STAGING"
verify_artifact "$STAGING"

destination="$MODELS_ROOT/$RELATIVE"
mkdir -p "$(dirname "$destination")"
mv -f "$STAGING/$RELATIVE" "$destination.new"
chmod 0640 "$destination.new"
mv -f "$destination.new" "$destination"

marker_tmp="$MARKER.new"
{
  printf '%s@%s\n' "$REPO" "$REV"
  printf 'territorial-authorization-attested=yes\n'
  printf '%s %s %s\n' "$EXPECTED_SHA256" "$EXPECTED_BYTES" "$RELATIVE"
} >"$marker_tmp"
chmod 0640 "$marker_tmp"
mv -f "$marker_tmp" "$MARKER"
rm -rf "$STAGING"

echo "MINIMAX_H3_FUN_CONTROLNET_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT"
