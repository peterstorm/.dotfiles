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
SWITCHER="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v2.sh"
PULL="$ROOT/scripts/inference/qwen38/pull-qwen38-dflash2-images.sh"
WF="$ROOT/.github/workflows/build-dflash2-vllm-image.yml"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "$1 does not contain: $2"; }
absent() { grep -Fq -- "$2" "$1" && fail "$1 must NOT contain: $2"; return 0; }

for file in "$VLLM" "$SWITCHER" "$PULL" "$WF"; do
  [[ -f "$file" ]] || fail "missing $file"
done
[[ -x "$VLLM" ]] || fail "$VLLM is not executable"
[[ -x "$PULL" ]] || fail "$PULL is not executable"
bash -n "$VLLM"
bash -n "$PULL"
bash -n "$SWITCHER"

# --- image routing: overridable, tag-based, digest optional ----------------
contains "$VLLM" 'IMAGE="${DFLASH2_VLLM_IMAGE:-peterstorm/vllm:qwen38-dflash2-pr52816-19c9351}"'
contains "$VLLM" 'DIGEST="${DFLASH2_VLLM_IMAGE_DIGEST:-}"'
contains "$VLLM" 'IMAGE_REF="${IMAGE}${DIGEST:+@$DIGEST}"'
contains "$VLLM" 'docker image inspect "$IMAGE_REF"'
contains "$VLLM" 'pull-qwen38-dflash2-images.sh vllm'

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
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang|dflash2-native|dflash2-vllm)'
# The original guard substring the other contracts rely on must still be intact.
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang'

# --- pull helper maps GHCR vllm -> canonical local tag ---------------------
contains "$PULL" '[vllm]="$REGISTRY/$GHCR_OWNER/vllm:qwen38-dflash2-pr52816-19c9351"'
contains "$PULL" '[vllm]="peterstorm/vllm:qwen38-dflash2-pr52816-19c9351"'

# --- CI workflow publishes the matching GHCR tag ---------------------------
contains "$WF" 'ghcr.io/${{ github.repository_owner }}/vllm:qwen38-dflash2-pr52816-19c9351'
contains "$WF" 'build-qwen38-dflash2-vllm-image.sh'

printf 'PASS: Qwen3.8 DFlash 2 vLLM profile + GHCR routing contract is internally consistent\n'
