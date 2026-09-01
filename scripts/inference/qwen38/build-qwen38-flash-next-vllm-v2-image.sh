#!/usr/bin/env bash
# Reconstruct vLLM from a public commit, apply the Qwen-owned safety patchset, and build an immutable image.
set -euo pipefail

SOURCE_COMMIT="e126687a9a828d513c01a07cd69f025f27d63280"
BASE_SOURCE_OVERLAY_COMMIT="815d965f7ccddd6a2b2da072a4a492115fc3a7e1"
SOURCE_OVERLAY_COMMIT="c0ac28980016af357df50359d301648352eebbf2"
SOURCE_DATE_EPOCH=1788208200
BUILD_BASE_IMAGE="pytorch/manylinux2_28-builder:cuda13.0-78e737ad29420ffc4800e677c51e2a852caf8359@sha256:c8d8dba2124931732d1b073dec1d8999cd4d6c5ff7c5e77232137e77d9f00f6a"
FINAL_BASE_IMAGE="nvidia/cuda:13.0.3-base-ubuntu24.04@sha256:7c7413a56200486f71f181cad9310f6fd31b6bb21816ade15fc9c1e1e927a5c1"
SOURCE_TAG="peterstorm/vllm:qwen38-flash-next-v2-source-e126687"
REPAIRED_SOURCE_TAG="peterstorm/vllm:qwen38-flash-next-v2-source-e126687-topk"
FINAL_TAG="peterstorm/vllm:qwen38-flash-next-v2-safe"
EXPECTED_IMAGE_ID="sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/flash-next-v2-safe"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/qwen38/flash-next-vllm-v2-image.identity}"

PATCHES=(
  qwen38-v2-ple-uva.patch
  qwen38-v2-exact-persistent-topk.patch
  qwen38-v2-accepted-state-safety.patch
  qwen38-v2-qsa-canonical-order.patch
  qwen38-v2-ple-state-safety.patch
)
PATCH_SHA256=(
  009d4acd2f3b96dd1b2e63b085855ad885e1d2832c0d6eb96d0e0ef4118b90b3
  8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395
  db95c8dc58cf8ae7b89f61e7194649dab52eacc07cac447cb84bcf8404062ba8
  fca4f69894c8583665e9b0758f92ef661b6de68ed550c804588c485fc28159d3
  653469b47e8e1eec7e45cf0aa1090796d78fb45c43ab91084bf950d18381cc5e
)
REPAIR_PATCH="qwen38-v2-large-topk-ties.patch"
REPAIR_PATCH_SHA256="287c32801f6a7d8700849afad6b0efa03b1885063cdd37864265512fea3414bc"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is supported only on linux/amd64" >&2
  exit 1
}
for command in docker git patch sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required" >&2
    exit 1
  }
done
for index in "${!PATCHES[@]}"; do
  echo "${PATCH_SHA256[$index]}  $OVERLAY_DIR/${PATCHES[$index]}" |
    sha256sum --check --strict
done
echo "$REPAIR_PATCH_SHA256  $OVERLAY_DIR/$REPAIR_PATCH" |
  sha256sum --check --strict

worktree="$(mktemp -d "${TMPDIR:-/tmp}/qwen38-v2-source.XXXXXX")"
trap 'rm -rf "$worktree"' EXIT

git -C "$worktree" init -q
git -C "$worktree" remote add origin https://github.com/vllm-project/vllm.git
git -C "$worktree" fetch --quiet --depth=1 origin "$SOURCE_COMMIT"
git -C "$worktree" checkout --quiet --detach FETCH_HEAD
[ "$(git -C "$worktree" rev-parse HEAD)" = "$SOURCE_COMMIT" ] || {
  echo "error: fetched vLLM source does not match $SOURCE_COMMIT" >&2
  exit 1
}

for patch_name in "${PATCHES[@]}"; do
  patch_file="$OVERLAY_DIR/$patch_name"
  patch --dry-run --batch --fuzz=0 -d "$worktree" -p1 <"$patch_file" >/dev/null
  patch --batch --fuzz=0 -d "$worktree" -p1 <"$patch_file" >/dev/null
done

(
  cd "$worktree"
  sha256sum --check --strict <<'EOF_HASHES'
6dab4bf9931a5bd1cb6820178d701d458344dbd557a7f6dcdddb48003f2744af  csrc/libtorch_stable/persistent_topk.cuh
16422e743eaec98ee517bb77288e7b4200bd13431d77956caf6dcbc1a54c7020  csrc/libtorch_stable/topk_histogram_4096.cuh
5baec281455281510c0929e939f978e72ba39d77eaf4f97417c218052debeabf  vllm/models/qwen4_exp/nvidia/ops/qsa.py
79ccc700f665d7b0a86f8c4b6de5837e5183ec699aa318da014755eacd47acc3  vllm/models/qwen4_exp/nvidia/ple_layer.py
29c8508894f51ac94912eabe399211579ec89c7ace87e3b5c7f86db711e52ce1  vllm/models/qwen4_exp/nvidia/model.py
1dab1e645452def753286f44a25f61b180e07e0e1aea5a877bcf0fb663f239b9  vllm/v1/attention/backends/gdn_attn.py
d5089ad9aa54fb41806db29ae3b6845a882332a5a8b56bcc4f849ab0b10bd851  vllm/v1/worker/mamba_utils.py
64635e5747a81192005fb67a191fdad591f008031d5415defc687279e98f9c71  vllm/model_executor/layers/mamba/ops/causal_conv1d.py
a76315029a3cb82d7540306d060dddbd6238c7ee2436635210fdfab0494241d8  vllm/model_executor/layers/mamba/ops/mamba_ssm.py
085fa04ef2cabd9604bda3ac5bfc567480bc59a890b78cb9886561285db35036  vllm/third_party/flash_linear_attention/ops/fused_recurrent.py
c45f746199067fb3981ca0e9c136a8109a12666d44a39ea5daae03d19c4be132  vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py
EOF_HASHES
)

git -C "$worktree" config user.name "Qwen v2 source overlay"
git -C "$worktree" config user.email "qwen-v2@local.invalid"
git -C "$worktree" add --all
GIT_AUTHOR_DATE="2026-08-31T20:30:00Z" \
GIT_COMMITTER_DATE="2026-08-31T20:30:00Z" \
  git -C "$worktree" commit --quiet \
    --message "Qwen3.8 Flash-Next v2 immutable safety overlay"
actual_overlay_commit="$(git -C "$worktree" rev-parse HEAD)"
[ "$actual_overlay_commit" = "$BASE_SOURCE_OVERLAY_COMMIT" ] || {
  echo "error: reconstructed base overlay commit is $actual_overlay_commit, expected $BASE_SOURCE_OVERLAY_COMMIT" >&2
  exit 1
}
[ -z "$(git -C "$worktree" status --short)" ] || {
  echo "error: reconstructed source tree is dirty" >&2
  exit 1
}

SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  --provenance=false \
  --target vllm-openai \
  --build-arg "BUILD_BASE_IMAGE=$BUILD_BASE_IMAGE" \
  --build-arg "FINAL_BASE_IMAGE=$FINAL_BASE_IMAGE" \
  --build-arg "VLLM_BUILD_COMMIT=$BASE_SOURCE_OVERLAY_COMMIT" \
  --build-arg "VLLM_BUILD_PIPELINE=qwen38-flash-next-v2-safe" \
  --build-arg "VLLM_BUILD_URL=https://github.com/vllm-project/vllm/commit/$SOURCE_COMMIT" \
  --build-arg "VLLM_IMAGE_TAG=$FINAL_TAG" \
  --build-arg "torch_cuda_arch_list=12.0" \
  --build-arg "MAX_JOBS=${MAX_JOBS:-4}" \
  --build-arg "NVCC_THREADS=${NVCC_THREADS:-2}" \
  --output "type=docker,name=$SOURCE_TAG,rewrite-timestamp=true" \
  --file "$worktree/docker/Dockerfile" \
  "$worktree"

repair_patch="$OVERLAY_DIR/$REPAIR_PATCH"
patch --dry-run --batch --fuzz=0 -d "$worktree" -p1 <"$repair_patch" >/dev/null
patch --batch --fuzz=0 -d "$worktree" -p1 <"$repair_patch" >/dev/null
(
  cd "$worktree"
  sha256sum --check --strict <<'EOF_REPAIRED_HASHES'
d50fd7f1c2ea917633dbae51134263fad802b5eb94d5610e722d74454cd85c3f  csrc/libtorch_stable/persistent_topk.cuh
d2af016acff1082fdbf1536c934320a11fdd7122a382b6bcc003d589ebfb3b37  csrc/libtorch_stable/topk.cu
EOF_REPAIRED_HASHES
)
git -C "$worktree" reset --soft "$SOURCE_COMMIT"
git -C "$worktree" add --all
GIT_AUTHOR_DATE="2026-08-31T20:30:00Z" \
GIT_COMMITTER_DATE="2026-08-31T20:30:00Z" \
  git -C "$worktree" commit --quiet \
    --message "Qwen3.8 Flash-Next v2 immutable safety overlay"
actual_repaired_commit="$(git -C "$worktree" rev-parse HEAD)"
[ "$actual_repaired_commit" = "$SOURCE_OVERLAY_COMMIT" ] || {
  echo "error: reconstructed repaired overlay commit is $actual_repaired_commit, expected $SOURCE_OVERLAY_COMMIT" >&2
  exit 1
}
[ -z "$(git -C "$worktree" status --short)" ] || {
  echo "error: repaired source tree is dirty" >&2
  exit 1
}

SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  --provenance=false \
  --build-arg "SOURCE_IMAGE=$SOURCE_TAG" \
  --build-arg "REPAIRED_SOURCE_OVERLAY_COMMIT=$SOURCE_OVERLAY_COMMIT" \
  --output "type=docker,name=$REPAIRED_SOURCE_TAG,rewrite-timestamp=true" \
  --file "$OVERLAY_DIR/Dockerfile.topk-rebuild" \
  "$worktree"

SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" docker buildx build \
  --provenance=false \
  --build-arg "SOURCE_IMAGE=$REPAIRED_SOURCE_TAG" \
  --build-arg "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH" \
  --output "type=docker,name=$FINAL_TAG,rewrite-timestamp=true" \
  "$OVERLAY_DIR"

actual_image_id="$(docker image inspect "$FINAL_TAG" --format '{{.Id}}')"
if [ -n "$EXPECTED_IMAGE_ID" ] && [ "$actual_image_id" != "$EXPECTED_IMAGE_ID" ]; then
  echo "error: built image is $actual_image_id, expected $EXPECTED_IMAGE_ID" >&2
  exit 1
fi

gpu_verified=false
if [ "${SKIP_GPU_VERIFY:-0}" != 1 ]; then
  docker run --rm --gpus "${VERIFY_GPUS:-all}" --ipc=host \
    --entrypoint python3 "$actual_image_id" /opt/qwen38-v2/verify.py
  gpu_verified=true
fi

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
umask 077
cat >"$IDENTITY_FILE" <<EOF_IDENTITY
source_commit=$SOURCE_COMMIT
base_source_overlay_commit=$BASE_SOURCE_OVERLAY_COMMIT
source_overlay_commit=$SOURCE_OVERLAY_COMMIT
build_base_image=$BUILD_BASE_IMAGE
final_base_image=$FINAL_BASE_IMAGE
source_image=$SOURCE_TAG
repaired_source_image=$REPAIRED_SOURCE_TAG
stable_extension_sha256=c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95
final_image=$FINAL_TAG
final_image_id=$actual_image_id
ple_pr=vllm-project/vllm#54371@905219234b0698b1f1ec2ed756de7051b080fb1c
persistent_topk_pr=vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3
accepted_state_pr=vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f
gpu_verified=$gpu_verified
prefix_caching=disabled
EOF_IDENTITY
chmod 600 "$IDENTITY_FILE"
printf 'Built %s (gpu_verified=%s); identity: %s\n' \
  "$actual_image_id" "$gpu_verified" "$IDENTITY_FILE"
