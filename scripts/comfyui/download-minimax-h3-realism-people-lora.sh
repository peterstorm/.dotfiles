#!/usr/bin/env bash
# Download the fal MiniMax H3 Realism People LoRA for the workstation's MiniMax
# H3 ComfyUI profile: one rank-32 adapter covering text-to-video, image-to-video
# and reference-to-video (shared attention projections only).
set -euo pipefail

REPO="fal/MiniMax-H3-Realism-People-LoRA"
REV="039cc8579d7aa357a882d7f4111b25da4f72dccc"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
LORA_PREFIX="loras"
STAGING="$MODELS_ROOT/.staging-minimax-h3-realism-people-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-realism-people-complete"
LOCK="$MODELS_ROOT/.minimax-h3-realism-people-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
The fal MiniMax H3 Realism People LoRA follows the MiniMax-H3 Community License
of the base model.
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
for command in flock sha256sum stat; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: required command is missing: $command" >&2
    exit 1
  }
done

# sha256, exact bytes, path relative to the repository root. The destination
# prefix below maps it into ComfyUI's loras directory unchanged.
read -r -d '' MANIFEST <<'EOF' || true
acc529601d2da117fb81179e76c56e488a3beab1171659d305f04fa3655b787e 131229656 h3-realism-people-t2v-i2v-r2v.safetensors
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
  echo "Verifying the existing Realism People LoRA..."
  if verify_manifest "$MODELS_ROOT/$LORA_PREFIX"; then
    echo "MINIMAX_H3_REALISM_PEOPLE_READY: $REPO@$REV"
    exit 0
  fi
  echo "Existing LoRA is incomplete or corrupt; resuming." >&2
fi

# Preserve the local-dir metadata and completed artifacts across retries. The
# pinned manifest remains the authority before anything reaches MODELS_ROOT.
mkdir -p "$STAGING"
mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
unset HF_HUB_DISABLE_XET
hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"

printf 'Verifying %d pinned Realism People LoRA artifacts...\n' "${#files[@]}"
verify_manifest "$STAGING"
while read -r _ _ relative; do
  [ -n "$relative" ] || continue
  destination="$MODELS_ROOT/$LORA_PREFIX/$relative"
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

echo "MINIMAX_H3_REALISM_PEOPLE_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT"
