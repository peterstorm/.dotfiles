#!/usr/bin/env bash
# 2026-08-19: build a vllm-openai image from the DFlash 2 PR branch, because
# DFlash 2 support is not in any released vLLM.
#
# Source: vllm-project/vllm PR #52816 "[Spec Decode] DFlash2: local
# convolution + candidate selector", head branch subsir/upstream-dflash2 at
# 66e5414c6d75a8529473d977f7458c140bbab8a0 (base main @ 9842d701). PR status
# at pin time (checked 2026-08-20 via GitHub API): OPEN, +885/-44 across 13
# files. Check-runs were not fully green: pre-run-check failed and DCO required
# action. The PR adds DFlash2 and follow-up sampling, memory, quantized-target,
# ROCm, and compile-cache correctness fixes; tests are included.
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
# 1-2h source build (Rust + C++/CUDA extensions). The build derives a CPU/RAM
# budget, caps MAX_JOBS at 16, and uses two nvcc threads; vLLM setup.py then
# runs up to eight concurrent CUDA units on this 32-thread/91-GiB desktop.
# Both values are overridable for smaller builders. Runs unattended:
#   nohup bash scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh \
#     > "$HOME/.local/state/qwen38/vllm-dflash2-build.log" 2>&1 &
#
# Idempotent: skips when the image already exists (REBUILD=1 to force).
# On completion it prints the image ID and manifest digest — record the
# digest in docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md and the
# vLLM run script before serving.
set -euo pipefail

VLLM_PR="vllm-project/vllm#52816"
VLLM_PR_SHA="66e5414c6d75a8529473d977f7458c140bbab8a0"
IMAGE="peterstorm/vllm:qwen38-dflash2-pr52816-66e5414"
BUILD_ROOT="${VLLM_BUILD_ROOT:-$HOME/.local/state/qwen38/vllm-dflash2-build}"

if docker image inspect "$IMAGE" >/dev/null 2>&1 && [ "${REBUILD:-0}" != 1 ]; then
  echo "$IMAGE already present (REBUILD=1 to force a rebuild)"
else
  mkdir -p "$BUILD_ROOT"
  if [ ! -d "$BUILD_ROOT/src/.git" ]; then
    echo "Cloning vllm (full history: the rust build stage bind-mounts .git)..."
    git clone https://github.com/vllm-project/vllm.git "$BUILD_ROOT/src"
  fi
  echo "Checking out pinned commit $VLLM_PR_SHA ($VLLM_PR)..."
  git -C "$BUILD_ROOT/src" fetch --tags origin
  git -C "$BUILD_ROOT/src" cat-file -e "$VLLM_PR_SHA^{commit}" 2>/dev/null \
    || git -C "$BUILD_ROOT/src" fetch origin "$VLLM_PR_SHA"
  git -C "$BUILD_ROOT/src" checkout --detach "$VLLM_PR_SHA"
  HEAD_SHA="$(git -C "$BUILD_ROOT/src" rev-parse HEAD)"
  if [ "$HEAD_SHA" != "$VLLM_PR_SHA" ]; then
    echo "error: checkout landed on $HEAD_SHA, expected $VLLM_PR_SHA" >&2
    exit 1
  fi

  # vLLM's Dockerfile defaults `max_jobs=2`, which runs the CUDA/CUTLASS
  # compile nearly serially. Derive a host budget, capped by ~3 GiB per
  # concurrent CUDA unit and a ceiling of 16 MAX_JOBS. vLLM setup.py divides
  # that value by NVCC_THREADS, yielding up to eight CUDA units here.
  _cores="$(nproc)"
  _ram_gb="$(free -g | awk '/^Mem:/{print $2}')"
  _by_ram=$(( _ram_gb / 3 )); [ "$_by_ram" -lt 1 ] && _by_ram=1
  _jobs="$_cores"; [ "$_by_ram" -lt "$_jobs" ] && _jobs="$_by_ram"
  [ "$_jobs" -gt 16 ] && _jobs=16
  VLLM_MAX_JOBS="${VLLM_MAX_JOBS:-$_jobs}"
  VLLM_NVCC_THREADS="${VLLM_NVCC_THREADS:-2}"
  for numeric in VLLM_MAX_JOBS VLLM_NVCC_THREADS; do
    value="${!numeric}"
    if ! [[ "$value" =~ ^[1-9][0-9]*$ ]]; then
      echo "error: $numeric must be a positive integer (got: $value)" >&2
      exit 2
    fi
  done

  echo "Building $IMAGE (stage vllm-openai, max_jobs=$VLLM_MAX_JOBS, nvcc_threads=$VLLM_NVCC_THREADS)..."
  # CUDA 13's generic 500-MB wheel publication gate rejects this local image's
  # legitimate FA2/FA3 + Blackwell kernels (observed wheel: 642 MB). The final
  # image is not a PyPI wheel, so retain the kernels and skip only that policy
  # check; compilation and the capability probes below still fail closed.
  docker build \
    --build-arg RUN_WHEEL_CHECK=false \
    --build-arg "max_jobs=$VLLM_MAX_JOBS" \
    --build-arg "nvcc_threads=$VLLM_NVCC_THREADS" \
    --label "org.opencontainers.image.revision=$VLLM_PR_SHA" \
    --label "org.opencontainers.image.source=https://github.com/vllm-project/vllm" \
    --target vllm-openai \
    -t "$IMAGE" \
    -f "$BUILD_ROOT/src/docker/Dockerfile" \
    "$BUILD_ROOT/src"
fi

# --- post-build verification (no GPU needed) --------------------------------
# The image entrypoint is ["vllm","serve"], so the probe overrides it. Resolve
# registry.py through the imported package: Debian installs this image under
# dist-packages, not the site-packages path used by upstream manylinux wheels.
echo
echo "Verifying the built image..."
docker run --rm -i --entrypoint python3 "$IMAGE" - <<'PY'
from pathlib import Path

import vllm
import vllm.model_executor.models.qwen3_dflash2 as dflash2_model
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.worker.gpu.spec_decode.dflash2.speculator import DFlash2Speculator

registry = Path(vllm.__file__).parent / "model_executor/models/registry.py"
supported = ModelRegistry.get_supported_archs()
assert "Qwen3_5ForConditionalGeneration" in supported, "Qwen3.8 target architecture missing"
assert "DFlash2DraftModel" in supported, "DFlash2DraftModel not registered"
assert "DFlash2DraftModel" in registry.read_text(), "DFlash2 registry source entry missing"
assert dflash2_model.__file__, "qwen3_dflash2 model module missing"
print("vllm", vllm.__version__)
print("Qwen3.8 target architecture: OK")
print("DFlash2DraftModel registration: OK")
print("dflash2 speculator: OK")
PY

ID="$(docker inspect --format '{{.Id}}' "$IMAGE")"
REPO_DIGEST="$(docker inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" | head -1)"
if [[ -z "$REPO_DIGEST" ]]; then
  REPO_DIGEST="<none; local-only image — pin with the image ID or push it first>"
fi
echo
echo "VLLM_DFLASH2_BUILD_COMPLETE"
echo "image:       $IMAGE"
echo "id:          $ID"
echo "repo digest: $REPO_DIGEST"
echo "Record the image ID (local build) or repository digest (pushed image) before serving."
