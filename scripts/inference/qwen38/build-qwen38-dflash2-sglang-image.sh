#!/usr/bin/env bash
# 2026-08-19: build the SGLang image at the DFlash 2 MERGE commit, because no
# released SGLang image carries DFlash 2 yet.
#
# Source: sgl-project/sglang PR #35371 (DFlash 2: DFlash2DraftModel +
# CandidateSelector + DFlashGroupedConv + the ragged verify buffer), MERGED to
# main on 2026-08-19 as merge commit c14312a66420b75ca9a11bf1817c4db1fa26b097.
# No release or nightly contains it yet as of this writing (v0.5.17 is
# 2026-08-08; the newest nightly at pin time, 20260818-c0b6474b, predates the
# merge).
#
# The build uses SGLang's own docker/Dockerfile, final stage 'runtime' (the
# same recipe as the official lmsysorg/sglang images): nvidia/cuda
# 13.0.3-cudnn-devel-ubuntu24.04, sgl-kernel 0.4.6.post1, flashinfer
# 0.6.17, and torch 2.13.0. BRANCH_TYPE=local packages the SHA-pinned
# checkout rather than substituting a released SGLang package. The pinned
# Dockerfile's unusable NCCL 2.28.3-1 default is overridden with torch's
# required nvidia-nccl-cu13 2.29.7.
#
# Result: peterstorm/sglang:qwen38-dflash2-c14312a — a NEW tag. The pinned
# qwen38-27b image (and the DSpark profiles that run on it, including the
# rollback path) are never touched.
#
# Serve with:
#   DFLASH2_IMAGE=peterstorm/sglang:qwen38-dflash2-c14312a \
#   DFLASH2_IMAGE_DIGEST=<digest printed at completion> \
#     bash scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang.sh
# or, once it passes the runbook validation gate, flip the launcher defaults.
# The launcher probes the image: native DFlash2DraftModel registration means
# the canonical draft tree is mounted as-is (no surgery).
#
# Expect: one-off pull of nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04 and a
# 1-2 h build (the hpc-ops CUTLASS compile is the long pole). Unattended:
#   nohup bash scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh \
#     > "$HOME/.local/state/qwen38/sglang-dflash2-build.log" 2>&1 &
#
# Idempotent: skips when the image already exists (REBUILD=1 to force).
# On completion it prints the immutable local image ID and a repository digest
# when one exists (local-only images have no repository digest).
set -euo pipefail

SGL_MERGE_SHA="c14312a66420b75ca9a11bf1817c4db1fa26b097"
IMAGE="peterstorm/sglang:qwen38-dflash2-c14312a"
BUILD_ROOT="${SGL_DFLASH2_BUILD_ROOT:-$HOME/.local/state/qwen38/sglang-dflash2-build}"
SGL_NCCL_VERSION="${SGL_NCCL_VERSION:-2.29.7}"
if ! [[ "$SGL_NCCL_VERSION" =~ ^[0-9]+([.][0-9]+){2}$ ]]; then
  echo "error: SGL_NCCL_VERSION must be x.y.z (got: $SGL_NCCL_VERSION)" >&2
  exit 2
fi

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ "${REBUILD:-0}" != 1 ]; then
  echo "$IMAGE already present (REBUILD=1 to force a rebuild)"
else
  mkdir -p "$BUILD_ROOT"
  if [ ! -d "$BUILD_ROOT/src/.git" ]; then
    echo "Cloning sgl-project/sglang..."
    git clone https://github.com/sgl-project/sglang.git "$BUILD_ROOT/src"
  fi
  echo "Checking out $SGL_MERGE_SHA (PR #35371 merge commit)..."
  git -C "$BUILD_ROOT/src" fetch --tags origin
  git -C "$BUILD_ROOT/src" checkout --detach "$SGL_MERGE_SHA"
  HEAD_SHA="$(git -C "$BUILD_ROOT/src" rev-parse HEAD)"
  if [ "$HEAD_SHA" != "$SGL_MERGE_SHA" ]; then
    echo "error: checkout landed on $HEAD_SHA, expected $SGL_MERGE_SHA" >&2
    exit 1
  fi

  # hpc-ops' setup.py hardcodes `cmake --build . -j16`, and its fused-MoE
  # CUTLASS translation units are multi-GB each. MAX_JOBS and
  # CMAKE_BUILD_PARALLEL_LEVEL cannot override that explicit flag. Patch a
  # COPY of the pinned Dockerfile so the SHA-pinned source checkout remains
  # clean and every retry starts from the same input. CI defaults to two jobs;
  # the 91-GiB desktop safely overrides SGL_HPC_OPS_JOBS=4.
  HPC_OPS_JOBS="${SGL_HPC_OPS_JOBS:-2}"
  if ! [[ "$HPC_OPS_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: SGL_HPC_OPS_JOBS must be a positive integer (got: $HPC_OPS_JOBS)" >&2
    exit 2
  fi
  UPSTREAM_DOCKERFILE="$BUILD_ROOT/src/docker/Dockerfile"
  DOCKERFILE="$BUILD_ROOT/Dockerfile.dflash2"
  cp "$UPSTREAM_DOCKERFILE" "$DOCKERFILE"
  grep -Fq 'python3 setup.py bdist_wheel -d /wheels;' "$DOCKERFILE" \
    || { echo "error: hpc-ops build command missing from pinned Dockerfile" >&2; exit 1; }
  sed -i "s#python3 setup.py bdist_wheel -d /wheels;#sed -i 's/-j16/-j${HPC_OPS_JOBS}/' setup.py \&\& python3 setup.py bdist_wheel -d /wheels;#" "$DOCKERFILE"
  grep -Fq "sed -i 's/-j16/-j${HPC_OPS_JOBS}/' setup.py" "$DOCKERFILE" \
    || { echo "error: failed to inject hpc-ops -j cap into $DOCKERFILE" >&2; exit 1; }
  echo "Capped hpc-ops CUTLASS build to -j${HPC_OPS_JOBS} (upstream hardcodes -j16)."

  # Upstream's own x86 image build failed because this commit defaults to the
  # unpublished nvidia-nccl-cu13 2.28.3-1. torch 2.13.0+cu130 installs and is
  # built against 2.29.7; force-reinstalling that exact version is a no-op
  # rather than an ABI-breaking downgrade. Override only after re-validating
  # torch's dependency at a future pin.
  echo "Building $IMAGE (stage runtime, NCCL_VERSION=$SGL_NCCL_VERSION)..."
  docker build \
    --target runtime \
    --build-arg BRANCH_TYPE=local \
    --build-arg NCCL_VERSION="$SGL_NCCL_VERSION" \
    --label "org.opencontainers.image.revision=$SGL_MERGE_SHA" \
    --label "org.opencontainers.image.source=https://github.com/sgl-project/sglang" \
    -t "$IMAGE" \
    -f "$DOCKERFILE" \
    "$BUILD_ROOT/src"
fi

# --- post-build verification (no GPU needed) --------------------------------
# The image ships CMD /bin/bash; every probe overrides the entrypoint.
echo
echo "Verifying the built image..."
IMAGE_SOURCE_SHA="$(docker run --rm --entrypoint git "$IMAGE" -C /sgl-workspace/sglang rev-parse HEAD)"
if [[ "$IMAGE_SOURCE_SHA" != "$SGL_MERGE_SHA" ]]; then
  echo "error: image contains SGLang $IMAGE_SOURCE_SHA, expected $SGL_MERGE_SHA" >&2
  exit 1
fi
docker run --rm --entrypoint python3 -e EXPECTED_NCCL="$SGL_NCCL_VERSION" "$IMAGE" -c "
from importlib.metadata import version
import os

import torch
import sglang
import sglang.srt.models.dflash as dflash
import sglang.srt.models.qwen3_5 as qwen3_5

assert '/sgl-workspace/sglang/' in sglang.__file__, f'unexpected sglang source: {sglang.__file__}'
assert hasattr(qwen3_5, 'Qwen3_5ForConditionalGeneration'), 'Qwen3.8 target class missing'
assert hasattr(dflash, 'DFlash2DraftModel'), 'DFlash2DraftModel missing'
assert hasattr(dflash, 'CandidateSelector'), 'CandidateSelector missing'
assert hasattr(dflash, 'DFlashGroupedConv'), 'DFlashGroupedConv missing'
names = [c.__name__ for c in dflash.EntryClass]
assert 'DFlash2DraftModel' in names, f'not in EntryClass: {names}'
assert version('nvidia-nccl-cu13') == os.environ['EXPECTED_NCCL'], 'unexpected NCCL package'
try:
    import sglang.srt.models.dspark  # informational: upstream DSpark parity
    print('dspark import: ok (future single-image consolidation possible)')
except Exception as e:
    print('dspark import: FAILED (informational only, DFlash2 unaffected):', e)
print('source commit', '$SGL_MERGE_SHA')
print('sglang', sglang.__version__)
print('torch', torch.__version__, 'cuda', torch.version.cuda)
print('nccl package', version('nvidia-nccl-cu13'))
print('Qwen3.8 target class: OK')
print('dflash EntryClass:', names)
" || { echo "error: DFlash 2 verification failed in $IMAGE" >&2; exit 1; }

ID="$(docker inspect --format '{{.Id}}' "$IMAGE")"
REPO_DIGEST="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" | head -1)"
if [[ -z "$REPO_DIGEST" ]]; then
  REPO_DIGEST="<none; local-only image — pin with the image ID or push it first>"
fi
echo
echo "SGLANG_DFLASH2_BUILD_COMPLETE"
echo "image:       $IMAGE"
echo "id:          $ID"
echo "repo digest: $REPO_DIGEST"
echo "Next: record the image ID or repository digest in the runbook, boot via the DFLASH2_IMAGE"
echo "override, and run the runbook validation gate (expect 4.1-5.5"
echo "acceptance under the card's conditions)."
