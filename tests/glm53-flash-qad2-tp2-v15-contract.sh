#!/usr/bin/env bash
# Static release contract for the GLM-5.3 v15 qad2 glm53-tp2 profile.
#
# v15 is a stock upstream deployment that follows the vendored "GLM-5.3-Flash
# vLLM Recipe": ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2
# pulled by digest, lil-serve --preset glm53-tp2 on the qad2 checkpoint
# (TP2/DCP2, MTP3, eight slots, 4096-token prefill, 7296 MiB/GPU FP8 KV,
# memory-resolved 1M context, CACHE_MODE=vram, server-default effort high).
# The contract proves, without Docker or a GPU, that the pull/download/run/
# switch scripts pin the recipe facts and the workstation gates, that the
# proof and the launch share one launcher argv, that the Pi catalog carries
# the exact id, and that the vendored recipe is the version the profile was
# built against.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
PULL="$GLM/pull-glm53-flash-qad2-tp2-v15-image.sh"
DL="$GLM/download-glm53-flash-qad2-tp2-v15-checkpoint.sh"
RUN="$GLM/run-glm53-flash-qad2-tp2-v15.sh"
SWITCH="$GLM/switch-glm53-qad2-tp2-v15.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_README="$ROOT/pi/README.md"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-qad2-tp2-v15-runbook-2026-10-16.md"
EVIDENCE="$ROOT/docs/research/glm53-qad2-tp2-v15-2026-10-16-evidence"
RECIPE="$EVIDENCE/recipe-glm-5.3-flash-vllm.md"
RECIPE_SHA256="3aad218f4f92e8e2db243c7f639c1f20359ecffad5d293f656120e590b516774"

PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20261015.2"
PULL_DIGEST="sha256:a7dc6c5f23310c0949e72fc1977fdcdaa5d8a4e1a9e7ee8f2482e6163b296178"
IMAGE_CONFIG="sha256:02c46866e4358592f43083980b35f73fbd08c723813b92f8205ab6446bc2b45d"
PRESET="glm53-tp2"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-MXFP8-CSF-QAD"
REVISION="0a0417631b4065d16e9639f327f44a0a4237a537"
SERVED_MODEL="glm-5.3-flash-qad2-tp2-v15"
CONTAINER="glm53-flash-qad2-tp2-v15"
KV_CACHE_BYTES="7650410496" # 7296 MiB per GPU
CHAT_TEMPLATE_KWARGS='{"reasoning_effort":"high","clear_thinking":false}'

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}
lacks() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then echo "FAIL: $file must not contain $text" >&2; exit 1; fi
}

for file in "$PULL" "$DL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done
jq -e . "$PI_MODELS" >/dev/null
[ -r "$RUNBOOK" ] || { echo "FAIL: v15 runbook is missing" >&2; exit 1; }

# --- the vendored recipe is pinned and names the same facts ------------------
actual_recipe_sha="$(sha256sum "$RECIPE" | cut -d' ' -f1)"
[ "$actual_recipe_sha" = "$RECIPE_SHA256" ] \
  || { echo "FAIL: $RECIPE digest is $actual_recipe_sha, expected $RECIPE_SHA256" >&2; exit 1; }
for fact in "$PULL_REF" "${PULL_DIGEST#sha256:}" "$CHECKPOINT" "$REVISION" \
  "--preset $PRESET" 'CACHE_MODE: vram' '"reasoning_effort":"high"' '1,844,162'; do
  contains "$RECIPE" "$fact"
done

# --- pull script pins the digest and proves the recipe launch plan -----------
contains "$PULL" "PULL_REF=\"$PULL_REF\""
contains "$PULL" "PULL_DIGEST=\"$PULL_DIGEST\""
contains "$PULL" 'IMAGE_REF="$PULL_REF@$PULL_DIGEST"'
contains "$PULL" 'docker pull "$IMAGE_REF"'
contains "$PULL" "PRESET=\"$PRESET\""
contains "$PULL" "SERVED_MODEL_REPO=\"$SERVED_MODEL\""
contains "$PULL" "CHECKPOINT=\"$CHECKPOINT\""
contains "$PULL" "MODEL_REVISION=\"$REVISION\""
contains "$PULL" "KV_CACHE_BYTES=\"$KV_CACHE_BYTES\""
contains "$PULL" "CHAT_TEMPLATE_KWARGS='$CHAT_TEMPLATE_KWARGS'"
contains "$PULL" '--entrypoint /usr/local/bin/lil-serve'
contains "$PULL" '--profile glm53-flash --hardware rtx-pro-6000-pcie --preset "$PRESET"'
contains "$PULL" '--print-config'
contains "$PULL" '-- --cache-mode vram'
contains "$PULL" ".settings.revision.value == \"$REVISION\""
contains "$PULL" '.settings["tensor-parallel-size"].value == 2'
contains "$PULL" '.settings["decode-context-parallel-size"].value == 2'
contains "$PULL" '.settings.mode.value == "mtp"'
contains "$PULL" '.settings["draft-tokens"].value == 3'
contains "$PULL" '.settings["max-num-seqs"].value == 8'
contains "$PULL" '.settings["max-num-batched-tokens"].value == 4096'
contains "$PULL" ".settings[\"kv-cache-memory-bytes\"].value == $KV_CACHE_BYTES"
contains "$PULL" '.settings["max-model-len"].value == -1'
contains "$PULL" '.settings["load-format"].value == "nvfp4_csf"'
contains "$PULL" '.settings["cache-mode"].value == "vram" and .cache_service == null'
contains "$PULL" '.settings["default-chat-template-kwargs"].value == {"reasoning_effort":"high","clear_thinking":false}'
contains "$PULL" '.settings["served-model-name"].source == "preset:glm53-tp2"'
contains "$PULL" 'startswith("environment:")'
contains "$PULL" 'base_proof_sha256'
# The proof must stay CPU-only: no GPUs, no model load.
lacks "$PULL" '--gpus'

# --- download script pins the exact checkpoint revision -----------------------
contains "$DL" "REPO=\"$CHECKPOINT\""
contains "$DL" "REV=\"$REVISION\""
contains "$DL" "IMAGE_CONFIG=\"$IMAGE_CONFIG\""
contains "$DL" 'CACHE_HOST="${CACHE_HOST:-/models/hf-cache/glm53-flash-qad2-tp2-v15}"'
contains "$DL" 'hf download "$REPO" --revision "$REV"'
contains "$DL" 'local_files_only=True'
contains "$DL" '.download-complete'
contains "$DL" 'flash-qad2-tp2-v15-checkpoint.txt'
contains "$DL" 'exit_code="$(docker wait "$NAME")"'
lacks "$DL" '--gpus'
lacks "$DL" 'GLM-5.3-Flash-NVFP4-Spark'

# --- run script serves exactly the pinned profile -----------------------------
contains "$RUN" "IMAGE_CONFIG=\"$IMAGE_CONFIG\""
contains "$RUN" "PULL_DIGEST=\"$PULL_DIGEST\""
contains "$RUN" 'endswith("@" + $digest)'
contains "$RUN" "PRESET=\"$PRESET\""
contains "$RUN" "CHECKPOINT=\"$CHECKPOINT\""
contains "$RUN" "MODEL_REVISION=\"$REVISION\""
contains "$RUN" "NAME=\"$CONTAINER\""
contains "$RUN" "SERVED_MODEL=\"$SERVED_MODEL\""
contains "$RUN" "CHAT_TEMPLATE_KWARGS='$CHAT_TEMPLATE_KWARGS'"
contains "$RUN" 'HF_CACHE_HOST="${HF_CACHE_HOST:-/models/hf-cache/glm53-flash-qad2-tp2-v15}"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-qad2-tp2-v15}"'
contains "$RUN" 'GPU_ORDER="${GPU_ORDER:-0,1}"'
# One launcher argv for both the proof and the launch.
contains "$RUN" 'LIL_SERVE_ARGS=(--profile glm53-flash --hardware rtx-pro-6000-pcie --preset "$PRESET")'
contains "$RUN" 'LIL_SERVE_NATIVE_ARGS=(-- --cache-mode vram)'
[ "$(grep -Fc '"${LIL_SERVE_ARGS[@]}"' "$RUN")" -eq 2 ] \
  || { echo 'FAIL: LIL_SERVE_ARGS must feed exactly the proof and the launch' >&2; exit 1; }
[ "$(grep -Fc -- '--entrypoint /usr/local/bin/lil-serve' "$RUN")" -eq 2 ] \
  || { echo 'FAIL: proof and launch must both enter through lil-serve' >&2; exit 1; }
contains "$RUN" '.settings.revision.value == $revision'
contains "$RUN" ".settings[\"kv-cache-memory-bytes\"].value == $KV_CACHE_BYTES"
contains "$RUN" '.settings["max-num-seqs"].value == 8'
contains "$RUN" '-v "$HF_CACHE_HOST:/root/.cache/huggingface:ro"'
contains "$RUN" '-v "$CACHE_HOST:/cache"'
contains "$RUN" '-e HF_HUB_OFFLINE=1'
contains "$RUN" '-e CACHE_MODE=vram'
contains "$RUN" '-e DEFAULT_CHAT_TEMPLATE_KWARGS="$CHAT_TEMPLATE_KWARGS"'
contains "$RUN" '-e SERVED_MODEL_NAME="$SERVED_MODEL"'
contains "$RUN" '-e PORT=8000'
contains "$RUN" '.download-complete'
contains "$RUN" 'snapshots/$MODEL_REVISION'
contains "$RUN" '--restart no'
contains "$RUN" '--stop-timeout 180'
contains "$RUN" '--gpus "\"device=$GPU_ORDER\""'
contains "$RUN" '--network host'
contains "$RUN" '--ipc host'
contains "$RUN" '--shm-size 32g'
contains "$RUN" '--ulimit memlock=-1'
contains "$RUN" '--ulimit stack=67108864:67108864'
contains "$RUN" 'machines/desktop/default.nix'
contains "$RUN" 'gpuPowerLimitWatts = ([0-9]+);'
contains "$RUN" 'cuda_runtime_probe()'
contains "$RUN" 'CUDA RUNTIME PROBE: PASS'
contains "$RUN" '--preflight'
contains "$RUN" 'v15 serves CACHE_MODE=vram only'
contains "$RUN" '--env-file "$ENVFILE"'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  echo 'FAIL: launcher leaks VLLM_API_KEY through argv' >&2
  exit 1
fi
lacks "$RUN" '--api-key'
# The preset owns the memory contract (a shorter context shrinks the KV pool).
lacks "$RUN" 'MAX_MODEL_LEN='
lacks "$RUN" 'KV_CACHE_MEMORY_BYTES='
lacks "$RUN" 'GPU_MEMORY_UTILIZATION='
lacks "$RUN" '--max-model-len'
lacks "$RUN" '--kv-cache-memory-bytes'
lacks "$RUN" '--tensor-parallel-size'
lacks "$RUN" '--max-num-seqs'
lacks "$RUN" '--max-num-batched-tokens'
lacks "$RUN" 'HF_HUB_OFFLINE=0'
lacks "$RUN" 'LMCACHE_'
contains "$RUN" 'for switch in VLLM_B12X_FP8_KV VLLM_B12X_GLM_NOPE_NVFP4 VLLM_DCP_GLOBAL_TOPK'

# --- switch script is transactional with the boot receipt --------------------
contains "$SWITCH" "TARGET=\"$CONTAINER\""
contains "$SWITCH" "EXPECTED_MODEL=\"$SERVED_MODEL\""
contains "$SWITCH" 'RUN="$SCRIPT_DIR/run-glm53-flash-qad2-tp2-v15.sh"'
contains "$SWITCH" "PRESET=\"$PRESET\""
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$SWITCH" 'promote_restart_policy'
contains "$SWITCH" 'restart=unless-stopped'
contains "$SWITCH" 'flash-qad2-tp2-v15-boot-receipt.txt'
contains "$SWITCH" 'require_idle_endpoint'
contains "$SWITCH" 'inference_quiesce_failed_container'
lacks "$SWITCH" 'v14-boot-receipt'

# --- catalog carries the container -------------------------------------------
grep -Eq "^[[:space:]]+$CONTAINER\$" "$CATALOG" \
  || { echo "FAIL: $CATALOG lacks $CONTAINER" >&2; exit 1; }

# --- Pi catalog carries the exact id with the client-side context cap ---------
jq -e --arg id "$SERVED_MODEL" '
  [.providers["desktop-vllm"].models[] | select(.id == $id)] as $m
  | ($m | length) == 1
  and ($m[0].contextWindow == 524288)
  and ($m[0].input | index("image") != null)
  and ($m[0].input | index("text") != null)
  and ($m[0].reasoning == true)
  and ($m[0].thinkingLevelMap.high == "high")
  and ($m[0].thinkingLevelMap.max == "max")
  and ($m[0].compat.thinkingFormat == "deepseek")
  and ($m[0].compat.supportsDeveloperRole == false)
' "$PI_MODELS" >/dev/null || {
  echo "FAIL: pi/models.json $SERVED_MODEL entry does not match the v15 contract" >&2
  exit 1
}
contains "$PI_README" "$SERVED_MODEL"
contains "$PI_README" '1,844,162'
contains "$PI_README" '524,288'

# --- runbook stays coherent ---------------------------------------------------
contains "$RUNBOOK" "$SERVED_MODEL"
contains "$RUNBOOK" "$PULL_REF"
contains "$RUNBOOK" "$PULL_DIGEST"
contains "$RUNBOOK" "$IMAGE_CONFIG"
contains "$RUNBOOK" "$REVISION"
contains "$RUNBOOK" 'flash-qad2-tp2-v15-boot-receipt.txt'
contains "$RUNBOOK" '1,844,162'
contains "$RUNBOOK" 'not an instant rollback'

echo "GLM-5.3 v15 qad2 glm53-tp2 contract: PASS"
