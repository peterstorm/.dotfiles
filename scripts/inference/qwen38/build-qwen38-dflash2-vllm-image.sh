#!/usr/bin/env bash
# 2026-08-19: build a vllm-openai image from the DFlash 2 PR branch, because
# DFlash 2 support is not in any released vLLM.
#
# Source: vllm-project/vllm PR #52816 "[Spec Decode] DFlash2: local
# convolution + candidate selector", head branch subsir/upstream-dflash2 at
# 19c9351904df4c63042671bc67a866ca48dc7d6f (base main @ 9842d701). PR status
# at pin time (checked 2026-08-19 via GitHub API): OPEN, commit check-run
# state SUCCESS, +755 lines across 11 files (adds
# vllm/model_executor/models/qwen3_dflash2.py and
# vllm/v1/worker/gpu/spec_decode/dflash2/speculator.py, tests included).
# The PR's own CI builds vLLM from source with this exact Dockerfile, so the
# artifact is a faithful reproduction of the pinned commit — the same thing
# the vllm/vllm-openai:nightly-* images are, except pinned to a PR instead of
# a main commit.
#
# What this is NOT: a replacement for a release. The code is unmerged and
# unreviewed; if the DFlash2 path misbehaves, there is no upstream release to
# bisect against. Treat the resulting profile as experimental.
#
# The build uses vLLM's own docker/Dockerfile, stage 'vllm-openai'
# (ENTRYPOINT ["vllm","serve"] — the same image variant as
# vllm/vllm-openai:nightly-aa99034...). Defaults: CUDA 13.0.3, Python 3.12,
# Ubuntu 24.04, NCCL 2.30.7, torch pinned to 2.13.0 by the PR's
# pyproject.toml, builder pytorch/manylinux2_28-builder:cuda13.0.
#
# Expect: one-off pull of the builder + final base images (multi-GB) and a
# 1-2h source build (Rust + C++/CUDA extensions). Runs unattended:
#   nohup bash scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh \
#     > "$HOME/.local/state/qwen38/vllm-dflash2-build.log" 2>&1 &
#
# Idempotent: skips when the image already exists (REBUILD=1 to force).
# On completion it prints the image ID and manifest digest — record the
# digest in docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md and the
# vLLM run script before serving.
set -euo pipefail

VLLM_PR="vllm-project/vllm#52816"
VLLM_PR_SHA="19c9351904df4c63042671bc67a866ca48dc7d6f"
IMAGE="peterstorm/vllm:qwen38-dflash2-pr52816-19c9351"
BUILD_ROOT="${VLLM_BUILD_ROOT:-$HOME/.local/state/qwen38/vllm-dflash2-build}"

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ "${REBUILD:-0}" != 1 ]; then
  echo "$IMAGE already present (REBUILD=1 to force a rebuild)"
else
  mkdir -p "$BUILD_ROOT"
  if [ ! -d "$BUILD_ROOT/src/.git" ]; then
    echo "Cloning vllm (full history: the rust build stage bind-mounts .git)..."
    git clone https://github.com/vllm-project/vllm.git "$BUILD_ROOT/src"
  fi
  echo "Checking out $VLLM_PR_SHA ($VLLM_PR head)..."
  # A plain clone does not contain PR head commits (they live under
  # refs/pull/N/head, not on any upstream branch) — fetch the PR ref
  # explicitly, then verify the checkout lands exactly on the pinned SHA.
  git -C "$BUILD_ROOT/src" fetch --tags origin
  git -C "$BUILD_ROOT/src" fetch origin pull/52816/head
  git -C "$BUILD_ROOT/src" checkout --detach FETCH_HEAD
  HEAD_SHA="$(git -C "$BUILD_ROOT/src" rev-parse HEAD)"
  if [ "$HEAD_SHA" != "$VLLM_PR_SHA" ]; then
    echo "error: checkout landed on $HEAD_SHA, expected $VLLM_PR_SHA (PR ref moved?)" >&2
    exit 1
  fi

  # vLLM's Dockerfile defaults `max_jobs=2`, which runs the CUDA/CUTLASS
  # compile nearly serially (observed: one nvcc at a time) — hours on a
  # many-core box instead of ~30 min. Parallelize by core count, capped by RAM
  # (~3 GB peak per concurrent CUDA unit) and a ceiling of 16 (the heaviest
  # CUTLASS units gate beyond that; more jobs just raise peak memory). Pair
  # with nvcc_threads=2 so jobs x threads tracks the core count rather than
  # the Dockerfile's default 8. Override VLLM_MAX_JOBS / VLLM_NVCC_THREADS.
  _cores="$(nproc)"
  _ram_gb="$(free -g | awk '/^Mem:/{print $2}')"
  _by_ram=$(( _ram_gb / 3 )); [ "$_by_ram" -lt 1 ] && _by_ram=1
  _jobs="$_cores"; [ "$_by_ram" -lt "$_jobs" ] && _jobs="$_by_ram"
  [ "$_jobs" -gt 16 ] && _jobs=16
  VLLM_MAX_JOBS="${VLLM_MAX_JOBS:-$_jobs}"
  VLLM_NVCC_THREADS="${VLLM_NVCC_THREADS:-2}"
  echo "Building $IMAGE (stage vllm-openai, max_jobs=$VLLM_MAX_JOBS nvcc_threads=$VLLM_NVCC_THREADS)..."
  docker build \
    --target vllm-openai \
    --build-arg max_jobs="$VLLM_MAX_JOBS" \
    --build-arg nvcc_threads="$VLLM_NVCC_THREADS" \
    -t "$IMAGE" \
    -f "$BUILD_ROOT/src/docker/Dockerfile" \
    "$BUILD_ROOT/src"
fi

# --- post-build verification (no GPU needed) --------------------------------
# The image entrypoint is ["vllm","serve"], so every probe overrides it.
echo
echo "Verifying the built image..."
docker run --rm --entrypoint python3 "$IMAGE" -c "import vllm; print('vllm', vllm.__version__)"
docker run --rm --entrypoint bash "$IMAGE" -lc \
  "grep -c 'DFlash2DraftModel' /usr/local/lib/python3.12/site-packages/vllm/model_executor/models/registry.py" \
  || { echo "error: DFlash2DraftModel not registered in the built image" >&2; exit 1; }
docker run --rm --entrypoint python3 "$IMAGE" -c "
from vllm.v1.worker.gpu.spec_decode.dflash2.speculator import DFlash2Speculator
print('dflash2 speculator: OK')
" || { echo "error: dflash2 speculator module missing" >&2; exit 1; }

ID="$(docker inspect --format '{{.Id}}' "$IMAGE")"
DIGEST_LINE="$(docker images --no-trunc --digests --format '{{.Repository}}:{{.Tag}} {{.Digest}}' "$IMAGE")"
echo
echo "VLLM_DFLASH2_BUILD_COMPLETE"
echo "image:  $IMAGE"
echo "id:     $ID"
echo "digest: $DIGEST_LINE"
echo "Record the digest in the runbook and the vLLM run script before serving."
