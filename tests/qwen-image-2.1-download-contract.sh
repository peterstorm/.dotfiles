#!/usr/bin/env bash
# Offline fake-HF regression for atomic BF16 closure and fail-closed preflight.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/fixtures" "$tmp/bin" "$tmp/models"
manifest="$tmp/manifest"
for name in diffusion_models/qwen_image_2.1_bf16.safetensors \
            text_encoders/qwen3vl_8b_bf16.safetensors \
            vae/qwen_image_2.1_vae_bf16.safetensors; do
  mkdir -p "$tmp/fixtures/$(dirname "$name")"
  printf 'fixture:%s\n' "$name" >"$tmp/fixtures/$name"
  hash=$(sha256sum "$tmp/fixtures/$name"); hash=${hash%% *}
  size=$(stat -c %s "$tmp/fixtures/$name")
  printf '%s %s %s\n' "$hash" "$size" "$name" >>"$manifest"
done
cat >"$tmp/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == download && $2 == Comfy-Org/Qwen-Image-2.1 ]]
name=$3
[[ $4 == --revision && $5 == 5dc5850eb514a3685f6a03a2641728a8f7549c69 ]]
[[ $6 == --local-dir ]]
mkdir -p "$7/$(dirname "$name")"
cp "$FAKE_HF_FIXTURES/$name" "$7/$name"
EOF
chmod +x "$tmp/bin/hf"
export FAKE_HF_FIXTURES="$tmp/fixtures"
export COMFYUI_MODELS_ROOT="$tmp/models"
export QWEN_IMAGE_21_MANIFEST="$manifest"
export PATH="$tmp/bin:$PATH"
script="$root/scripts/comfyui/download-qwen-image-2.1-bf16.sh"
if "$script" --verify-only >/dev/null 2>&1; then
  echo 'missing closure accepted' >&2; exit 1
fi
"$script" >"$tmp/first.log"
"$script" --verify-only >"$tmp/verified.log"
"$script" >"$tmp/second.log"
[[ -f "$tmp/models/.qwen-image-2.1-bf16-5dc5850eb514a3685f6a03a2641728a8f7549c69.complete" ]]
printf 'corrupt' >"$tmp/models/vae/qwen_image_2.1_vae_bf16.safetensors"
if "$script" --verify-only >/dev/null 2>&1; then
  echo 'corrupt closure accepted' >&2; exit 1
fi
"$script" >/dev/null
"$script" --verify-only >/dev/null
printf 'Qwen 2.1 downloader offline contract: OK\n'
