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
# 13.0.3-cudnn-devel-ubuntu24.04, prebuilt sgl-kernel 0.4.6.post1 wheels
# (BRANCH_TYPE=remote), flashinfer 0.6.17, NCCL 2.30.7.
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
# On completion it prints the image ID and manifest digest.
set -euo pipefail

SGL_MERGE_SHA="c14312a66420b75ca9a11bf1817c4db1fa26b097"
IMAGE="peterstorm/sglang:qwen38-dflash2-c14312a"
BUILD_ROOT="${SGL_DFLASH2_BUILD_ROOT:-$HOME/.local/state/qwen38/sglang-dflash2-build}"

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

  # Upstream's Dockerfile at c14312a6 force-reinstalls a pinned NCCL wheel
  # (ARG NCCL_VERSION default 2.28.3-1) that is BOTH unpublished on PyPI and
  # too old for the torch it installs: torch 2.13.0+cu130 depends on
  # nvidia-nccl-cu13 2.29.7 and is built against it, so anything older breaks
  # `import torch` with "undefined symbol: ncclCommResume" (which then cascades
  # into missing torch/*.h in the hpc-ops stage). Pin to the version torch
  # itself pulls, making the force-reinstall a no-op instead of a downgrade.
  # Override with SGL_NCCL_VERSION if upstream aligns the pins.
  SGL_NCCL_VERSION="${SGL_NCCL_VERSION:-2.29.7}"
  echo "Building $IMAGE (stage runtime, NCCL_VERSION=$SGL_NCCL_VERSION)..."
  docker build \
    --target runtime \
    --build-arg NCCL_VERSION="$SGL_NCCL_VERSION" \
    -t "$IMAGE" \
    -f "$BUILD_ROOT/src/docker/Dockerfile" \
    "$BUILD_ROOT/src"
fi

# --- post-build verification (no GPU needed) --------------------------------
# The image ships CMD /bin/bash; every probe overrides the entrypoint.
echo
echo "Verifying the built image..."
docker run --rm --entrypoint python3 "$IMAGE" -c "
import sglang
import sglang.srt.models.dflash as dflash
assert hasattr(dflash, 'DFlash2DraftModel'), 'DFlash2DraftModel missing'
assert hasattr(dflash, 'CandidateSelector'), 'CandidateSelector missing'
assert hasattr(dflash, 'DFlashGroupedConv'), 'DFlashGroupedConv missing'
names = [c.__name__ for c in dflash.EntryClass]
assert 'DFlash2DraftModel' in names, f'not in EntryClass: {names}'
try:
    import sglang.srt.models.dspark  # informational: upstream DSpark parity
    print('dspark import: ok (future single-image consolidation possible)')
except Exception as e:
    print('dspark import: FAILED (informational only, DFlash2 unaffected):', e)
print('sglang', sglang.__version__)
print('dflash EntryClass:', names)
" || { echo "error: DFlash 2 verification failed in $IMAGE" >&2; exit 1; }

ID="$(docker inspect --format '{{.Id}}' "$IMAGE")"
DIGEST_LINE="$(docker images --no-trunc --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' "$IMAGE")"
echo
echo "SGLANG_DFLASH2_BUILD_COMPLETE"
echo "image:  $IMAGE"
echo "id:     $ID"
echo "digest: $DIGEST_LINE"
echo "Next: record the digest in the runbook, boot via the DFLASH2_IMAGE"
echo "override, and run the runbook validation gate (expect 4.1-5.5"
echo "acceptance under the card's conditions)."
