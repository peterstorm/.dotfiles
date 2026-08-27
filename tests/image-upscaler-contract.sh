#!/usr/bin/env bash
# shellcheck disable=SC2016 # Static contracts intentionally match literal Nix expressions.
# Contracts for immutable still-image upscaler models, workflows, and phase ownership.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODULE="$ROOT/machines/desktop/comfyui.nix"
DOWNLOADER="$ROOT/scripts/comfyui/download-image-upscaler-models.sh"
PHASE="$ROOT/scripts/comfyui/creative-model-phase.sh"
LOCAL_VALIDATION="$ROOT/comfyui/custom_nodes/seedvr2_local_model_validation.py"
LOCAL_VALIDATION_TEST="$ROOT/tests/test_seedvr2_local_model_validation.py"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

for file in "$MODULE" "$DOWNLOADER" "$PHASE" "$LOCAL_VALIDATION" "$LOCAL_VALIDATION_TEST"; do
  [ -f "$file" ] || fail "missing $file"
done
for executable in "$DOWNLOADER" "$LOCAL_VALIDATION_TEST"; do
  [ -x "$executable" ] || fail "$executable is not executable"
done
bash -n "$DOWNLOADER" "$PHASE"
nix-instantiate --parse "$MODULE" >/dev/null

for expected in \
  'rev = "4490bd1f482e026674543386bb2a4d176da245b9";' \
  'hash = "sha256-6nsqFflLw9vYH/du35ET46fdAm1NMjjTe2bA8JmaBE4=";' \
  'ln -s ${seedVR2Node} "$out/ComfyUI-SeedVR2_VideoUpscaler"' \
  'seedvr2_local_model_validation.py' \
  'validate_installed_weight as download_weight' \
  'Validating immutable locally installed models...' \
  'image-upscaler-qualification-v1-workflows' \
  '00 Lanczos 4x - Zero Hallucination Control.json' \
  '01 Real-ESRGAN x4plus - Learned Fidelity.json' \
  '03 SeedVR2 3B FP16 - Natural 4K.json' \
  '04 SeedVR2 7B FP16 - Natural 4K.json' \
  '05 SeedVR2 7B FP16 Sharp - Adversarial Comparison.json' \
  '06 SeedVR2 7B FP16 - Natural Video 2K.json' \
  '.nodes |= map(select(.id != 18 and .id != 19 and .id != 20))' \
  'minimax-h3-safe-upscaler-workflows' \
  '01 MiniMax H3 Output - SeedVR2 7B FP16 Natural Video 2K.json' \
  'h3_safe_upscaler_dir="$user_workflows/minimax-h3-upscaler-local-safe"' \
  'blocked_h3_upscaler_dir="$user_workflows/minimax-h3-upscaler-research-only"' \
  '42, "fixed", 1536, 2688, 9, true, "lab"' \
  'remux authoritative dialogue after finishing' \
  '"SEEDVR2"' \
  'downloadImageUpscalerModels'; do
  grep -Fq -- "$expected" "$MODULE" || fail "module does not contain: $expected"
done
upscaler_block="$(awk '/^  imageUpscalerWorkflows =/,/^  installCreativeWorkflows =/' "$MODULE")"
if grep -Eqi 'seedvr2_ema_[^" ]*(fp8|int8)|https?://[^" ]*(resolve|tree)/main' \
  <<<"$upscaler_block"; then
  fail "upscaler workflow package contains a lower-precision selector or mutable model URL"
fi
[ "$(grep -Fc '.nodes |= map(select(.id != 18 and .id != 19 and .id != 20))' \
  <<<"$upscaler_block")" -eq 2 ] \
  || fail "all SeedVR2 still/video graphs must remove the unavailable Note node"
if grep -Fq 'select(.id == 18)' <<<"$upscaler_block"; then
  fail "upscaler workflow package still configures the unavailable Note node"
fi
grep -Fq '"$blocked_h3_upscaler_dir"' "$MODULE" \
  || fail "installer does not remove the blocked H3 learned-latent workflow directory"

for expected in \
  'SEEDVR_REV="09ced71023636e9bc8cdf9cdecfb2625d1e691e8"' \
  '2fd0e03a3dad24e07086750360727ca437de4ecd456f769856e960ae93e2b304 6783018808' \
  '7b8241aa957606ab6cfb66edabc96d43234f9819c5392b44d2492d9f0b0bbe4a 16479334424' \
  '20a93e01ff24beaeebc5de4e4e5be924359606c356c9c51509fba245bd2d77dd 16479334424' \
  '20678548f420d98d26f11442d3528f8b8c94e57ee046ef93dbb7633da8612ca1 501324814' \
  '4fa0d38905f75ac06eb49a7951b426670021be3018265fd191d2125df9d682f1 67040989' \
  '8dc7edb9ac80ccdc30c3a5dca6616509367f05fbc184ad95b731f05bece96292 4885111' \
  'seedvr-license=Apache-2.0' \
  'realesrgan-license=BSD-3-Clause'; do
  grep -Fq -- "$expected" "$DOWNLOADER" || fail "downloader does not contain: $expected"
done
[ "$(grep -Ec '^[0-9a-f]{64} [0-9]+ .* (SEEDVR2|upscale_models)/' "$DOWNLOADER")" -eq 6 ] \
  || fail "upscaler manifest must contain exactly six pinned artifacts"
grep -Fq 'def validate_installed_weight(' "$LOCAL_VALIDATION" \
  || fail "local-only validator entry point is missing"
grep -Fq '_sha256(artifact) != model_info.sha256' "$LOCAL_VALIDATION" \
  || fail "local-only validator does not verify the registry checksum"
if grep -Eqi 'urllib|requests|huggingface|https?://|download_with_resume' "$LOCAL_VALIDATION"; then
  fail "local-only validator contains a network or download path"
fi
"$LOCAL_VALIDATION_TEST"

# Exercise the complete downloader transaction with tiny deterministic command adapters.
temp="$(mktemp -d)"
trap 'rm -rf "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/models"
cat >"$temp/bin/hf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = download ]
shift 2
files=()
while [ "$1" != --revision ]; do files+=("$1"); shift; done
shift 2
[ "$1" = --local-dir ]
local_dir="$2"
for file in "${files[@]}"; do
  mkdir -p "$local_dir/$(dirname "$file")"
  printf '%s\n' "$file" >"$local_dir/$file"
done
EOF
cat >"$temp/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift 2 ;;
    http*) url="$1"; shift ;;
    *) shift ;;
  esac
done
mkdir -p "$(dirname "$output")"
printf '%s\n' "$(basename "$url")" >"$output"
EOF
chmod +x "$temp/bin/hf" "$temp/bin/curl"

# shellcheck source=scripts/comfyui/download-image-upscaler-models.sh
source "$DOWNLOADER"
MODELS_ROOT="$temp/models"
PROFILE_ID="fixture-image-upscalers"
STAGING="$MODELS_ROOT/.staging-$PROFILE_ID"
MARKER="$MODELS_ROOT/.$PROFILE_ID.complete"
LOCK="$MODELS_ROOT/.$PROFILE_ID.lock"
hf_a='fixture-3b.safetensors'
hf_b='fixture-vae.safetensors'
url_a='fixture-x4plus.pth'
url_b='fixture-general.pth'
sha_of_line() { printf '%s\n' "$1" | sha256sum | cut -d' ' -f1; }
size_of_line() { printf '%s\n' "$1" | wc -c; }
HF_MANIFEST="$(sha_of_line "$hf_a") $(size_of_line "$hf_a") $hf_a SEEDVR2/$hf_a
$(sha_of_line "$hf_b") $(size_of_line "$hf_b") $hf_b SEEDVR2/$hf_b"
URL_MANIFEST="$(sha_of_line "$url_a") $(size_of_line "$url_a") https://example.invalid/$url_a upscale_models/$url_a
$(sha_of_line "$url_b") $(size_of_line "$url_b") https://example.invalid/$url_b upscale_models/$url_b"
PATH="$temp/bin:$PATH" main >/dev/null
verify_manifest "$MODELS_ROOT" || fail "completed fixture profile did not verify"
grep -Fxq "$PROFILE_ID" "$MARKER" || fail "completion marker was not published"
while read -r _ _ relative; do
  [ "$(stat -c %a "$MODELS_ROOT/$relative")" = 640 ] \
    || fail "installed artifact mode is not 0640: $relative"
done < <(verification_manifest)
printf 'corrupt\n' >"$MODELS_ROOT/SEEDVR2/$hf_a"
if verify_manifest "$MODELS_ROOT" 2>/dev/null; then
  fail "corrupt fixture artifact passed verification"
fi

printf 'PASS: still-image upscalers are immutable, full precision, serialized, and transactionally verified\n'
