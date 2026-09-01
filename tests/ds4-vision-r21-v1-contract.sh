#!/usr/bin/env bash
# Static release contract for the immutable DS4 Vision r21 overlay.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIR="$ROOT/scripts/inference/deepseek"
OVERLAY="$DIR/ds4-vision-r21-safe"
BUILD="$DIR/build-ds4-flash-vision-r21-image.sh"
DOWNLOAD="$DIR/download-ds4-flash-vision.sh"
PULL="$DIR/pull-ds4-flash-vision-r21-v1-image.sh"
RUN="$DIR/run-ds4-flash-vision-r21-v1.sh"
SWITCH="$DIR/switch-ds4-flash-vision-r21-v1.sh"
PROBE="$DIR/probe-ds4-flash-vision-r21-v1.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
MODELS="$ROOT/pi/models.json"
PATCH_SHA="800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469"
IMAGE="sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183"
REV="86f746b36186f0e567729a5c06a8c918caba82a9"
BASE="sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 lacks: $2"; }

for executable in "$BUILD" "$DOWNLOAD" "$PULL" "$RUN" "$SWITCH" "$PROBE"; do
  [[ -x "$executable" ]] || fail "$executable is not executable"
  bash -n "$executable"
done
[[ -f "$OVERLAY/Dockerfile" && -f "$OVERLAY/verify.py" ]] || fail "overlay files missing"
if command -v python3 >/dev/null; then
  python3 -m py_compile "$OVERLAY/verify.py"
fi

[[ "$(sha256sum "$OVERLAY/ds4-vision-r21.patch" | cut -d' ' -f1)" == "$PATCH_SHA" ]] \
  || fail "overlay patch hash differs"
[[ "$(sha256sum "$OVERLAY/base-source-sha256.txt" | cut -d' ' -f1)" == \
  59a763fb58677c327aa5dd8516fed81ced34da4e61b0ac701e0eb572dd38ff82 ]] \
  || fail "base manifest hash differs"
[[ "$(sha256sum "$OVERLAY/final-source-sha256.txt" | cut -d' ' -f1)" == \
  967c6a451abe7049a66e974148cf8feabbcbbf43511d0c1b32248c8ed0fcf770 ]] \
  || fail "final manifest hash differs"

contains "$OVERLAY/Dockerfile" "FROM voipmonitor/vllm@$BASE"
contains "$OVERLAY/Dockerfile" 'patch --batch --fuzz=0 -p1'
contains "$OVERLAY/Dockerfile" "$PATCH_SHA"
contains "$OVERLAY/Dockerfile" "$REV"
contains "$BUILD" "EXPECTED_IMAGE_ID=\"$IMAGE\""
contains "$DOWNLOAD" "REV=\"$REV\""
contains "$PULL" "IMAGE=\"$IMAGE\""
contains "$RUN" "IMAGE=\"$IMAGE\""
contains "$RUN" 'SERVING_MODE="${SERVING_MODE:-dspark}"'
contains "$RUN" 'DSPARK_TOKENS="${DSPARK_TOKENS:-6}"'
contains "$RUN" 'requires DSpark depth 6 (block size 5, n_predict 3)'
contains "$RUN" '-e VLLM_USE_B12X_MHC=0'
contains "$RUN" '-e PREFIX_CACHE=1'
contains "$RUN" '--disable-chunked-mm-input'
contains "$RUN" '--default-chat-template-kwargs.reasoning_effort=max'
contains "$RUN" '--restart no'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  fail "launcher leaks VLLM_API_KEY through argv"
fi
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$SWITCH" 'any(. == "MODE=dspark") and any(. == "DSPARK_TOKENS=6")'
contains "$PROBE" 'data:image/png;base64'
contains "$CATALOG" 'ds4-flash-vision-infernal-invocation-cu133-r21-v1'
jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "deepseek-v4-flash-vision") |
  .input == ["text", "image"] and
  .contextWindow == 312000 and
  .compat.thinkingFormat == "deepseek"
' "$MODELS" >/dev/null || fail "Pi DS4 Vision model contract differs"

contains "$OVERLAY/ds4-vision-r21.patch" 'class DeepseekV4VisionTransformer'
contains "$OVERLAY/ds4-vision-r21.patch" 'class DeepseekV4VisionMultiModalProcessor'
contains "$OVERLAY/ds4-vision-r21.patch" 'NUM_IMAGE_TOKEN_TYPES = 5'
contains "$OVERLAY/ds4-vision-r21.patch" 'vision_aware_topk'
contains "$OVERLAY/ds4-vision-r21.patch" 'build_image_partition_indices'
contains "$OVERLAY/ds4-vision-r21.patch" 'merge_attention_partitions'
contains "$OVERLAY/ds4-vision-r21.patch" '_repair_partial_multimodal_prefix_hit'
contains "$OVERLAY/ds4-vision-r21.patch" 'self._has_synthetic_image_tokens'

printf 'PASS: DS4 Vision r21 is source-guarded, multimodal, image-visible, OOV-bounded, prefix-atomic, DSpark-safe, and rollback-safe\n'
