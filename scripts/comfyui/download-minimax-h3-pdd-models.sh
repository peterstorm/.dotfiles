#!/usr/bin/env bash
# Install the official Alibaba PAI MiniMax H3 PDD acceleration files. These are
# trunk LoRA + parallel-decoding head banks and require the dedicated PDD node.
set -euo pipefail

REPO="alibaba-pai/MiniMax-H3-Acc-LoRAs"
REV="335001fb9e5455d68a0caa18ec2e319072150328"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGING="$MODELS_ROOT/.staging-minimax-h3-pdd-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-pdd-complete"
LOCK="$MODELS_ROOT/.minimax-h3-pdd-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != yes ]; then
  cat >&2 <<'EOF'
MiniMax H3 PDD acceleration remains subject to the MiniMax-H3 Community License.
Set MINIMAX_H3_ACCEPT_LICENSE=yes only after reviewing:
https://huggingface.co/MiniMaxAI/MiniMax-H3/blob/main/LICENSE
EOF
  exit 2
fi
if [ "${MINIMAX_H3_AUTHORIZED:-}" != yes ]; then
  echo "error: set MINIMAX_H3_AUTHORIZED=yes only when separate territorial authorization is in force" >&2
  exit 2
fi
for command in flock hf sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

read -r -d '' MANIFEST <<'EOF' || true
0b29be7042d883970eb0c20774a9ba03d95669ed80a721bb4d21be8ea0d0a196 1372450680 pdd_acc/MiniMax-H3-FL2VA-Acc-8Step.safetensors
111c82e669f6e20e628228172edf39395f1a9fc3ad049793895e542c0f55b18c 1372450680 pdd_acc/MiniMax-H3-Ref2VA-Acc-8Step.safetensors
EOF

verify_manifest() {
  local root=$1 expected_sha expected_size relative file actual_size actual_sha
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    file="$root/$relative"
    [ -f "$file" ] || { echo "missing: $relative" >&2; return 1; }
    actual_size=$(stat -c %s "$file")
    [ "$actual_size" = "$expected_size" ] || {
      echo "size mismatch: $relative (expected $expected_size, got $actual_size)" >&2
      return 1
    }
    actual_sha=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$actual_sha" = "$expected_sha" ] || {
      echo "checksum mismatch: $relative" >&2
      return 1
    }
  done <<<"$MANIFEST"
}

write_marker() {
  {
    printf '%s@%s\n' "$REPO" "$REV"
    printf 'territorial-authorization-attested=yes\n'
    printf 'loader=MiniMaxH3PDDAccApply\n'
    printf '%s\n' "$MANIFEST"
  } >"$MARKER.new"
  chmod 0640 "$MARKER.new"
  mv -f "$MARKER.new" "$MARKER"
}

mkdir -p "$MODELS_ROOT/pdd_acc"
exec 9>"$LOCK"
flock 9

if verify_manifest "$MODELS_ROOT"; then
  write_marker
  echo "MINIMAX_H3_PDD_MODELS_READY: $REPO@$REV"
  exit 0
fi

mkdir -p "$STAGING/download" "$STAGING/pdd_acc"
mapfile -t source_files < <(awk 'NF == 3 { sub(".*/", "", $3); print $3 }' <<<"$MANIFEST")
hf download "$REPO" "${source_files[@]}" --revision "$REV" --local-dir "$STAGING/download"
for source in "${source_files[@]}"; do
  mv -f "$STAGING/download/$source" "$STAGING/pdd_acc/$source"
done
verify_manifest "$STAGING"

while read -r _ _ relative; do
  [ -n "$relative" ] || continue
  destination="$MODELS_ROOT/$relative"
  install -m 0640 "$STAGING/$relative" "$destination.new"
  mv -f "$destination.new" "$destination"
done <<<"$MANIFEST"
write_marker
rm -rf "$STAGING"

echo "MINIMAX_H3_PDD_MODELS_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT/pdd_acc"
