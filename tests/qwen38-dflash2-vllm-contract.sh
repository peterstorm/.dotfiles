#!/usr/bin/env bash
# Static contract for the Qwen3.8 DFlash 2 vLLM profile
# (run-qwen38-27b-bf16-dflash2-vllm.sh), its GHCR routing, and the
# 'dflash2-vllm' switcher mode.
#
#   * Image is overridable (DFLASH2_VLLM_IMAGE) and defaults to the canonical
#     tag the CI build + pull helper produce; tag-based reference with an
#     optional digest pin.
#   * NO stray unbound variable (the old `$IMAGE_IS_BUILT` bug that exited 1
#     under set -u is gone); presence is probed via the resolved IMAGE_REF.
#   * Native DFlash 2 (PR #52816 registers DFlash2DraftModel) — no surgery.
#   * switch-qwen38-backend-v2.sh gains a 'dflash2-vllm' mode, falling back to
#     the DSpark vLLM v2 profile (same engine).
#   * pull-qwen38-dflash2-images.sh maps the GHCR vllm image to the canonical
#     local tag.
#
# No GPU, container, or network access is required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VLLM="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-vllm.sh"
BUILD="$ROOT/scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh"
SWITCHER="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v2.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-dflash2-images.sh"
WF="$ROOT/.github/workflows/build-dflash2-vllm-image.yml"
DOC="$ROOT/docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md"
BENCH="$ROOT/benchmarks/vllm-tps/2026-08-20-dflash2-vllm.md"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
absent() { grep -Fq -- "$2" "$1" && fail "$1 must NOT contain: $2"; return 0; }

for file in "$VLLM" "$BUILD" "$SWITCHER" "$PULL" "$WF" "$DOC" "$BENCH"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$VLLM" ]] || fail "$VLLM is not executable"
[[ -x "$BUILD" ]] || fail "$BUILD is not executable"
[[ -x "$PULL" ]] || fail "$PULL is not executable"
bash -n "$VLLM"
bash -n "$BUILD"
bash -n "$PULL"
bash -n "$SWITCHER"

# --- immutable source pin + host CPU/RAM budget ----------------------------
contains "$BUILD" 'VLLM_PR_SHA="66e5414c6d75a8529473d977f7458c140bbab8a0"'
contains "$BUILD" 'VLLM_MAX_JOBS="${VLLM_MAX_JOBS:-$_jobs}"'
contains "$BUILD" 'VLLM_NVCC_THREADS="${VLLM_NVCC_THREADS:-2}"'
contains "$BUILD" '_by_ram=$(( _ram_gb / 3 ))'
contains "$BUILD" '[ "$_jobs" -gt 16 ] && _jobs=16'
contains "$BUILD" 'checkout --detach "$VLLM_PR_SHA"'
contains "$BUILD" '--build-arg RUN_WHEEL_CHECK=false'
contains "$BUILD" '--build-arg "max_jobs=$VLLM_MAX_JOBS"'
contains "$BUILD" '--build-arg "nvcc_threads=$VLLM_NVCC_THREADS"'
contains "$BUILD" '--label "org.opencontainers.image.revision=$VLLM_PR_SHA"'
absent "$BUILD" 'pull/52816/head'

# Verification follows the imported package instead of assuming Ubuntu's
# site-packages layout (the built Debian image installs under dist-packages).
contains "$BUILD" 'registry = Path(vllm.__file__).parent / "model_executor/models/registry.py"'
contains "$BUILD" '"Qwen3_5ForConditionalGeneration" in supported'
contains "$BUILD" '"DFlash2DraftModel" in supported'
contains "$BUILD" 'DFlash2Speculator'
absent "$BUILD" '/usr/local/lib/python3.12/site-packages/vllm'

# --- image routing: overridable, tag-based, digest optional ----------------
contains "$VLLM" 'IMAGE="${DFLASH2_VLLM_IMAGE:-peterstorm/vllm:qwen38-dflash2-pr52816-66e5414}"'
contains "$VLLM" 'DIGEST="${DFLASH2_VLLM_IMAGE_DIGEST:-}"'
contains "$VLLM" 'IMAGE_REF="${IMAGE}${DIGEST:+@$DIGEST}"'
contains "$VLLM" 'docker image inspect "$IMAGE_REF"'
contains "$VLLM" 'pull-qwen38-dflash2-images.sh vllm'
contains "$VLLM" '"Qwen3_5ForConditionalGeneration" in supported'
contains "$VLLM" '"DFlash2DraftModel" in supported'
contains "$VLLM" 'DFlash2Speculator'
contains "$VLLM" 'lacks native Qwen3.8 + DFlash 2 support'

# --- the set -u landmine is gone -------------------------------------------
absent "$VLLM" 'IMAGE_IS_BUILT'

# --- full BF16, TP2, native DFlash 2 (no surgery) --------------------------
contains "$VLLM" '--dtype bfloat16'
contains "$VLLM" '--tensor-parallel-size 2'
contains "$VLLM" '\"method\":\"dflash\"'
contains "$VLLM" '.architectures == ["DFlash2DraftModel"]'
absent   "$VLLM" 'DFlashDraftModel"]'
# key never in argv
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$VLLM"; then
  fail "$VLLM exposes VLLM_API_KEY in Docker command arguments"
fi
contains "$VLLM" 'inference_prepare_api_key "${VLLM_API_KEY:-}"'
contains "$VLLM" 'nvidia-smi --query-gpu=index,power.limit'

# --- switcher: dflash2-vllm mode + same-engine fallback --------------------
contains "$SWITCHER" 'DFLASH2_VLLM_NAME="qwen38-27b-bf16-dflash2-vllm"'
contains "$SWITCHER" 'DFLASH2_VLLM_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-vllm.sh"'
contains "$SWITCHER" '"$DFLASH2_VLLM_NAME"'
contains "$SWITCHER" 'dflash2-vllm) START_NAME="$DFLASH2_VLLM_NAME"'
contains "$SWITCHER" 'dflash2-vllm) FALLBACK="vllm"'
contains "$SWITCHER" '*dflash2*vllm*)'
contains "$SWITCHER" 'expected: Qwen3_5ForConditionalGeneration, then DFlash2Qwen3ForCausalLM'
contains "$SWITCHER" "^vllm:spec_decode_num_drafts_total\\{"
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang|dflash2-native|dflash2-vllm)'
# The original guard substring the other contracts rely on must still be intact.
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang'

# --- pull helper maps GHCR vllm -> canonical local tag ---------------------
contains "$PULL" '[vllm]="$REGISTRY/$GHCR_OWNER/vllm:qwen38-dflash2-pr52816-66e5414"'
contains "$PULL" '[vllm]="peterstorm/vllm:qwen38-dflash2-pr52816-66e5414"'

# --- CI workflow publishes the matching GHCR tag ---------------------------
contains "$WF" 'ghcr.io/${{ github.repository_owner }}/vllm:qwen38-dflash2-pr52816-66e5414'
contains "$WF" 'build-qwen38-dflash2-vllm-image.sh'

# --- runbook records the verified local artifact and live validation gate --
contains "$DOC" 'sha256:f07390e05b3bfccd4aa7494fa322a0077f72fbc8842f8b17dca96e57420218a6'
contains "$DOC" 'vllm 0.26.1rc1.dev920+g66e5414c6'
contains "$DOC" 'DFLASH2_VLLM_IMAGE=sha256:f07390e05b3bfccd4aa7494fa322a0077f72fbc8842f8b17dca96e57420218a6'
contains "$DOC" 'DFlash2Qwen3ForCausalLM'
contains "$DOC" "'^vllm:spec_decode_num_(drafts|accepted)'"
contains "$DOC" 'generation applies **350 W**'
contains "$DOC" 'benchmarks/vllm-tps/2026-08-20-dflash2-vllm.md'
contains "$BENCH" '120.3–120.4 tok/s'
contains "$BENCH" '731.3 tok/s'
contains "$BENCH" 'effective acceptance length: `1 + 2768 / 1324 = 3.09`'

printf 'PASS: Qwen3.8 DFlash 2 vLLM profile + GHCR routing contract is internally consistent\n'
