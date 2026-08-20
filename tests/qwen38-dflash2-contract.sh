#!/usr/bin/env bash
# Static contract for the 2026-08-19 Qwen3.8 DFlash 2 profile:
#
#   * download-qwen38-27b-dflash2.sh pins z-lab/Qwen3.8-27B-DFlash2 to
#     revision ac04198556 (last modified 2026-08-18) and writes to the
#     desktop user's Desktop folder by default (deliberate deviation from
#     the /models convention; DFLASH2_DEST overrides).
#   * run-qwen38-27b-bf16-dflash2-sglang.sh runs on the SAME pinned SGLang
#     image + digest as the validated DSpark v2 profile (that custom build
#     g561c8f3 already carries DFLASH -> DFlashWorkerV2), serves
#     --speculative-algorithm DFLASH with block size 8, and keeps the
#     isolated-copy draft-config surgery (architectures ->
#     DFlashDraftModel; the checkpoint's DFlash2DraftModel is not in the
#     image's model registry).
#   * switch-qwen38-backend-v2.sh gains a 'dflash2' mode with the SGLang
#     DSpark v2 profile as its same-engine fallback.
#   * The runbook documents the checkpoint pin, the upstream DFlash 2 PRs
#     (sglang #35371 — merged 2026-08-19 as c14312a6; vllm #52816 — open)
#     that gate future re-pins, and the Desktop destination.
#
# No GPU, container, or network access is required.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DFLASH2_DL="$ROOT/scripts/inference/qwen38/download-qwen38-27b-dflash2.sh"
DFLASH2_SGLANG="$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang.sh"
SWITCHER="$ROOT/scripts/inference/qwen38/switch-qwen38-backend-v2.sh"
DOC="$ROOT/docs/runbooks/qwen38-27b-dflash2-runbook-2026-08-19.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

for file in "$DFLASH2_DL" "$DFLASH2_SGLANG" "$SWITCHER" "$DOC"; do
  [[ -f "$file" ]] || fail "missing $file"
done
for file in "$DFLASH2_DL" "$DFLASH2_SGLANG"; do
  [[ -x "$file" ]] || fail "$file is not executable"
  bash -n "$file"
done

command -v jq >/dev/null 2>&1 || fail "jq is required for the surgery assertion"

# --- downloader: pinned repo/revision, Desktop destination, resumable ------
contains "$DFLASH2_DL" 'REPO="z-lab/Qwen3.8-27B-DFlash2"'
contains "$DFLASH2_DL" 'REV="ac04198556d7e8867853cbc356807b969f311b05"'
contains "$DFLASH2_DL" 'DFLASH2_DEST:-$DESKTOP_HOME/Desktop/Qwen3.8-27B-DFlash2'
contains "$DFLASH2_DL" 'export HF_HUB_DISABLE_XET=1'
contains "$DFLASH2_DL" 'docker rm -f qwen38-dflash2-model-dl'
# The in-container destination must be the mapped path (host home is mounted
# at /home/dl, /models 1:1); downloading to the raw host path would land in
# the container layer, not on the host.
contains "$DFLASH2_DL" 'CONTAINER_DEST="/home/dl${DEST#"$DESKTOP_HOME"}"'
contains "$DFLASH2_DL" 'hf download "$REPO" --revision "$REV" --local-dir "$CONTAINER_DEST"'
contains "$DFLASH2_DL" '-v "$DESKTOP_HOME:/home/dl" -v /models:/models'
# The tree must be handed back to the desktop user from INSIDE the root
# container (this host's user cannot sudo non-interactively).
contains "$DFLASH2_DL" 'chown -R "$TARGET_UID:$TARGET_GID" "$CONTAINER_DEST"'
if grep -Eq '^DEST="/models/' "$DFLASH2_DL"; then
  fail "$DFLASH2_DL defaults to a /models destination; the agreed default is the Desktop folder"
fi

# --- SGLang DFlash 2: image override, DFLASH spec path, conditional surgery -
contains "$DFLASH2_SGLANG" 'IMAGE="${DFLASH2_IMAGE:-lmsysorg/sglang:qwen38-27b}"'
contains "$DFLASH2_SGLANG" 'DIGEST="${DFLASH2_IMAGE_DIGEST:-sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124}"'
contains "$DFLASH2_SGLANG" 'NAME="qwen38-27b-bf16-dflash2-sglang"'
contains "$DFLASH2_SGLANG" 'ENVFILE="$CONFIG_DIR/sglang-dflash2.env"'
contains "$DFLASH2_SGLANG" 'DRAFT_CONTAINER="/models/z-lab/Qwen3.8-27B-DFlash2-sglang"'
# The surgery copy must live in the user-writable Desktop (next to the
# canonical tree), NOT under /models (root:root, unwritable unprivileged).
contains "$DFLASH2_SGLANG" 'DFLASH2_DRAFT_SGLANG_HOST:-$DFLASH2_HOME/Desktop/Qwen3.8-27B-DFlash2-sglang'
if grep -Fq 'DFLASH2_DRAFT_SGLANG_HOST:-/models' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG defaults the surgery copy to /models, which the user cannot write"
fi
contains "$DFLASH2_SGLANG" 'DFLASH2_BLOCK_SIZE="${DFLASH2_BLOCK_SIZE:-8}"'
contains "$DFLASH2_SGLANG" '--speculative-algorithm DFLASH'
contains "$DFLASH2_SGLANG" '--speculative-draft-model-path "$DRAFT_CONTAINER"'
contains "$DFLASH2_SGLANG" '--speculative-num-draft-tokens "$DFLASH2_BLOCK_SIZE"'
if grep -Fq -- '--speculative-algorithm DSPARK' "$DFLASH2_SGLANG" \
  || grep -Fq -- '--speculative-dspark-block-size' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG carries DSPARK-specific spec flags"
fi
if grep -Eq '(^|[^A-Z_])export SGLANG_RAGGED_VERIFY_MODE=|^[[:space:]]*-e SGLANG_RAGGED_VERIFY_MODE=' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG exports SGLANG_RAGGED_VERIFY_MODE, which this image build does not consume"
fi

# Capability probe: images at/after PR #35371's merge register DFlash2DraftModel
# natively and skip surgery (canonical tree served as-is); pre-merge images
# fall through to the isolated-copy surgery below.
contains "$DFLASH2_SGLANG" "hasattr(m, 'DFlash2DraftModel')"
contains "$DFLASH2_SGLANG" 'DRAFT_SERVE_HOST="$DRAFT_HOST"'
contains "$DFLASH2_SGLANG" '-v "$DRAFT_SERVE_HOST":"$DRAFT_CONTAINER":ro'

# Draft config surgery: rewrite architectures on an ISOLATED copy (the image
# knows DFlashDraftModel, not the checkpoint's DFlash2DraftModel), only when
# needed. The canonical downloaded tree must never be rewritten in place.
contains "$DFLASH2_SGLANG" 'cp -a "$DRAFT_HOST" "${DRAFT_SGLANG_HOST}.tmp"'
contains "$DFLASH2_SGLANG" "jq -e '.architectures == [\"DFlashDraftModel\"]'"
if grep -Eq -- 'jq [^|]*"\$DRAFT_HOST' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG rewrites the canonical draft tree in place instead of an isolated copy"
fi
fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT
cat > "$fixture/config.json" <<'JSON'
{"architectures":["DFlash2DraftModel"],"model_type":"qwen3","dflash_config":{"block_size":8,"mask_token_id":248070,"selector_rank":256,"target_layer_ids":[5,19,33,47,61]}}
JSON
jq '(.architectures = ["DFlashDraftModel"])' "$fixture/config.json" > "$fixture/out.json"
jq -e '.architectures == ["DFlashDraftModel"] and .dflash_config.block_size == 8 and .dflash_config.mask_token_id == 248070 and .dflash_config.target_layer_ids == [5,19,33,47,61]' \
  "$fixture/out.json" >/dev/null \
  || fail "draft config surgery expression does not preserve non-architecture fields"

# Quality profile: identical target-fidelity flags to the validated DSpark
# v2 SGLang profile (one drafter apart, everything else the same).
contains "$DFLASH2_SGLANG" 'MAX_RUNNING_REQUESTS="${MAX_RUNNING_REQUESTS:-8}"'
contains "$DFLASH2_SGLANG" 'CONTEXT_LENGTH="${CONTEXT_LENGTH:-262144}"'
contains "$DFLASH2_SGLANG" 'CHUNKED_PREFILL_SIZE="${CHUNKED_PREFILL_SIZE:-2048}"'
contains "$DFLASH2_SGLANG" 'MEM_FRACTION_STATIC="${MEM_FRACTION_STATIC:-0.85}"'
contains "$DFLASH2_SGLANG" 'MAMBA_STATE_SLOTS="${MAMBA_STATE_SLOTS:-5}"'
contains "$DFLASH2_SGLANG" 'MAX_MAMBA_CACHE_SIZE="${MAX_MAMBA_CACHE_SIZE:-$((MAX_RUNNING_REQUESTS * MAMBA_STATE_SLOTS))}"'
if grep -Eq 'MAX_MAMBA_CACHE_SIZE.*DFLASH2_BLOCK_SIZE' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG folds the draft verify window into the mamba pin"
fi
contains "$DFLASH2_SGLANG" '--dtype bfloat16'
contains "$DFLASH2_SGLANG" '--tp-size 2'
contains "$DFLASH2_SGLANG" '--kv-cache-dtype bfloat16'
contains "$DFLASH2_SGLANG" '--mamba-ssm-dtype float32'
contains "$DFLASH2_SGLANG" '--mamba-radix-cache-strategy extra_buffer'
contains "$DFLASH2_SGLANG" '--max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE"'
contains "$DFLASH2_SGLANG" '--attention-backend flashinfer'
contains "$DFLASH2_SGLANG" '--cuda-graph-max-bs-decode "$MAX_RUNNING_REQUESTS"'
contains "$DFLASH2_SGLANG" '--trust-remote-code'
contains "$DFLASH2_SGLANG" '--enable-multimodal'
contains "$DFLASH2_SGLANG" '--enable-metrics'
contains "$DFLASH2_SGLANG" '--reasoning-parser qwen3'
contains "$DFLASH2_SGLANG" '--tool-call-parser qwen3_coder'
contains "$DFLASH2_SGLANG" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
# INFERENCE_OPERATOR_HOME is used (CONTAINER_ARCHIVE_DIR) before the key is
# prepared, so the operator must be resolved right after sourcing.
contains "$DFLASH2_SGLANG" 'inference_resolve_operator'
contains "$DFLASH2_SGLANG" 'inference_prepare_api_key "${SGLANG_API_KEY:-${VLLM_API_KEY:-}}"'
contains "$DFLASH2_SGLANG" 'inference_write_private_file "$ENVFILE" <<EOF'
contains "$DFLASH2_SGLANG" 'ENTRYPOINT_HOST="$SCRIPT_DIR/../shared/sglang-secure-entrypoint.py"'
contains "$DFLASH2_SGLANG" 'nvidia-smi --query-gpu=index,power.limit'
contains "$DFLASH2_SGLANG" 'MAX_GPU_POWER_LIMIT'
contains "$DFLASH2_SGLANG" 'docker run -d --init'
contains "$DFLASH2_SGLANG" '--gpus all'
contains "$DFLASH2_SGLANG" '--ipc=host'
contains "$DFLASH2_SGLANG" '--network host'
contains "$DFLASH2_SGLANG" '-e CUDA_VISIBLE_DEVICES="$GPU_ORDER"'
contains "$DFLASH2_SGLANG" '--port 8000'
if grep -Eq '^[[:space:]]*-e SGLANG_API_KEY=' "$DFLASH2_SGLANG"; then
  fail "$DFLASH2_SGLANG exposes SGLANG_API_KEY in Docker command arguments"
fi

# --- SGLang merge-commit build (real DFlash 2, PR #35371 merged 2026-08-19) -
SGL_BUILD="$ROOT/scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh"
[[ -f "$SGL_BUILD" ]] || fail "missing $SGL_BUILD"
[[ -x "$SGL_BUILD" ]] || fail "$SGL_BUILD is not executable"
bash -n "$SGL_BUILD"
contains "$SGL_BUILD" 'SGL_MERGE_SHA="c14312a66420b75ca9a11bf1817c4db1fa26b097"'
contains "$SGL_BUILD" 'IMAGE="peterstorm/sglang:qwen38-dflash2-c14312a"'
contains "$SGL_BUILD" -- '--target runtime'
contains "$SGL_BUILD" 'DFlash2DraftModel'

# --- switcher: new dflash2 mode, SGLang DSpark v2 as same-engine fallback --
contains "$SWITCHER" 'status|vllm|sglang|dflash2|v1-vllm|v1-sglang'
contains "$SWITCHER" 'DFLASH2_SGLANG_NAME="qwen38-27b-bf16-dflash2-sglang"'
contains "$SWITCHER" 'DFLASH2_SGLANG_SCRIPT="$SCRIPT_DIR/run-qwen38-27b-bf16-dflash2-sglang.sh"'
contains "$SWITCHER" '"$DFLASH2_SGLANG_NAME"'
contains "$SWITCHER" 'dflash2) FALLBACK="sglang"'
bash -n "$SWITCHER"

# --- runbook: pins, PR gates, destination ----------------------------------
contains "$DOC" 'ac04198556d7e8867853cbc356807b969f311b05'
contains "$DOC" 'sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124'
contains "$DOC" 'sgl-project/sglang#35371'
contains "$DOC" 'c14312a66420b75ca9a11bf1817c4db1fa26b097'
contains "$DOC" 'build-qwen38-dflash2-sglang-image.sh'
contains "$DOC" 'vllm-project/vllm#52816'
contains "$DOC" 'block_size 8'
contains "$DOC" 'Desktop/Qwen3.8-27B-DFlash2'

printf 'PASS: Qwen3.8 DFlash 2 profile contract is internally consistent\n'
