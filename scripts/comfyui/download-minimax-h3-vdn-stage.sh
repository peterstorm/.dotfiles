#!/usr/bin/env bash
# Download the VDN-H3 (Video Delta Net) 8-step stage checkpoint for the
# workstation's MiniMax H3 ComfyUI profile: the original bf16 stage-dmd-step-250
# release directory (linear branch + both LoRA adapters + spec files), kept
# intact under models/vdn/ — nothing is converted on disk.
set -euo pipefail

REPO="OpenVDN/vdn-minimax-h3"
REV="18be6bcc4ee72585eee322ba28b5ccac2cf85ef0"
MODELS_ROOT="${COMFYUI_MODELS_ROOT:-/models/comfyui}"
STAGE_PREFIX="vdn"
STAGING="$MODELS_ROOT/.staging-minimax-h3-vdn-$REV"
MARKER="$MODELS_ROOT/.minimax-h3-vdn-complete"
LOCK="$MODELS_ROOT/.minimax-h3-vdn-download.lock"

if [ "${MINIMAX_H3_ACCEPT_LICENSE:-}" != "yes" ]; then
  cat >&2 <<'EOF'
VDN-H3 weights ship under the MiniMax-H3 Community License.
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

# sha256, exact bytes, path relative to the VDN stage root. The bf16
# stage-dmd-step-250 release is pinned, not the optional int8 ConvRot quantization.
read -r -d '' MANIFEST <<'EOF' || true
89e0ff8920b9629b826eb99ab6150cce6924a53aa445186d1b493225fd091b96 415 stage-dmd-step-250/adapters/default/adapter_config.json
58558fef506f88bb41649242de9b9b3a365da806b51b2e96afbbe1625222058a 334026912 stage-dmd-step-250/adapters/default/adapter_model.safetensors
627968f670747c29cd7a0d3f8c75166e501d70f9e829b5cd3242a8f14cefbc18 22264 stage-dmd-step-250/adapters/turbo/adapter_config.json
24fc93c82fe84dc45d0627f4e72c637bc387d282ba18f60ed3b7f8c81089392c 851452696 stage-dmd-step-250/adapters/turbo/adapter_model.safetensors
decb06ac7e664610f677fb445318502b3c51f9c1b8603a2cdd00b16042be5bc8 465 stage-dmd-step-250/linear_branch/config.json
dec6981c7874f5b3bc92d1a02e256b673a3b3499dc1a124714bb3b19da602855 4279428112 stage-dmd-step-250/linear_branch/model.safetensors
54054ceb1c91b3fdf7fa0278e4a8841c127e8cf666b5e240d69613661f9d3e9e 463 stage-dmd-step-250/metadata.json
4171f4384e952f1f73467981a893440c03298af4956b947e2c8a857ba9f5a62b 25705 stage-dmd-step-250/model_spec.json
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
  echo "Verifying the existing VDN-H3 stage..."
  if verify_manifest "$MODELS_ROOT/$STAGE_PREFIX"; then
    echo "MINIMAX_H3_VDN_READY: $REPO@$REV"
    exit 0
  fi
  echo "Existing stage is incomplete or corrupt; resuming." >&2
fi

# Preserve the local-dir metadata and completed artifacts across retries. The
# pinned manifest remains the authority before anything reaches MODELS_ROOT.
mkdir -p "$STAGING"
mapfile -t files < <(awk 'NF == 3 { print $3 }' <<<"$MANIFEST")
unset HF_HUB_DISABLE_XET
hf download "$REPO" "${files[@]}" --revision "$REV" --local-dir "$STAGING"

printf 'Verifying %d pinned VDN-H3 stage artifacts...\n' "${#files[@]}"
verify_manifest "$STAGING"
while read -r _ _ relative; do
  [ -n "$relative" ] || continue
  destination="$MODELS_ROOT/$STAGE_PREFIX/$relative"
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

echo "MINIMAX_H3_VDN_READY: $REPO@$REV"
echo "model root: $MODELS_ROOT"
