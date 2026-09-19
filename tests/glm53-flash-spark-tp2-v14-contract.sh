#!/usr/bin/env bash
# Static release contract for the GLM-5.3 v14 upstream spark-preset profile.
#
# v14 is a stock upstream deployment: ghcr.io/local-inference-lab/vllm:karmic-
# kraken-beta with PRESET=glm53-spark-tp2 (TP2/DCP2, MTP3, four slots,
# 3072-token prefill, 3996 MiB/GPU fixed FP8 KV, memory-resolved context,
# vision). No overlay, no derived image, no local checkpoint: the contract
# proves, without Docker or a GPU, that the pull/run/switch scripts pin the
# upstream deployment facts (image ref, preset, served model id, memory
# contract, cache plan, workstation gates, transactional promotion), that the
# Pi catalog and routing policy carry the exact same ids, and that the
# vendored upstream doc is the version the profile was built against.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
PULL="$GLM/pull-glm53-flash-spark-tp2-v14-image.sh"
DL="$GLM/download-glm53-flash-spark-tp2-v14-checkpoint.sh"
RUN="$GLM/run-glm53-flash-spark-tp2-v14.sh"
SWITCH="$GLM/switch-glm53-spark-tp2-v14.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_ROUTING="$ROOT/pi/model-routing.json"
PI_README="$ROOT/pi/README.md"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-spark-tp2-v14-runbook-2026-09-19.md"
EVIDENCE="$ROOT/docs/research/glm53-spark-tp2-v14-2026-09-19-evidence"
UPSTREAM_DOC="$EVIDENCE/upstream-glm-5.3-flash-spark-tp2.md"
UPSTREAM_DOC_SHA256="1afc3a6700471e22bbe60db60e0de7e42527d5bdc83f2c218dbdd51f5607bd74"

PULL_REF="ghcr.io/local-inference-lab/vllm:karmic-kraken-beta"
PRESET="glm53-spark-tp2"
CHECKPOINT="local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"
SERVED_MODEL="glm-5.3-flash-spark-tp2-v14"
CONTAINER="glm53-flash-spark-tp2-v14"
KV_CACHE_BYTES="4190109696" # 3996 MiB per GPU

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}
lacks() {
  local file="$1" text="$2"
  if grep -Fq -- "$text" "$file"; then echo "FAIL: $file must not contain $text" >&2; exit 1; fi
}
digest_is() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "$file" | cut -d' ' -f1)"
  [ "$actual" = "$expected" ] || { echo "FAIL: $file digest is $actual, expected $expected" >&2; exit 1; }
}

for file in "$PULL" "$DL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done
jq -e . "$PI_MODELS" >/dev/null
jq -e . "$PI_ROUTING" >/dev/null
[ -r "$RUNBOOK" ] || { echo "FAIL: v14 runbook is missing" >&2; exit 1; }

# --- the vendored upstream doc is pinned -------------------------------------
digest_is "$UPSTREAM_DOC" "$UPSTREAM_DOC_SHA256"
head -n 1 "$UPSTREAM_DOC" | grep -Fq 'GLM-5.3-Flash on two 96-GB GPUs' \
  || { echo 'FAIL: vendored upstream doc is not the spark-tp2 model page' >&2; exit 1; }

# --- pull script pins the upstream image and proves the preset contract ------
contains "$PULL" "PULL_REF=\"$PULL_REF\""
contains "$PULL" "PRESET=\"$PRESET\""
contains "$PULL" 'docker pull "$PULL_REF"'
contains "$PULL" '--print-config'
contains "$PULL" "SERVED_MODEL_REPO=\"$SERVED_MODEL\""
contains "$PULL" "CHECKPOINT=\"$CHECKPOINT\""
contains "$PULL" "KV_CACHE_BYTES=\"$KV_CACHE_BYTES\""
contains "$PULL" '.settings["tensor-parallel-size"].value == 2'
contains "$PULL" '.settings["decode-context-parallel-size"].value == 2'
contains "$PULL" '.settings.mode.value == "mtp"'
contains "$PULL" '.settings["draft-tokens"].value == 3'
contains "$PULL" '.settings["max-num-seqs"].value == 4'
contains "$PULL" '.settings["max-num-batched-tokens"].value == 3072'
contains "$PULL" '.settings["kv-cache-memory-bytes"].value == 4190109696'
contains "$PULL" '.settings["gpu-memory-utilization"].value == 0.985'
contains "$PULL" '.settings["max-model-len"].value == -1'
contains "$PULL" '.settings["load-format"].value == "safetensors"'
contains "$PULL" '.settings.model.value == "local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"'
contains "$PULL" '.hardware == "rtx-pro-6000-pcie"'
contains "$PULL" '.settings["served-model-name"].source == "preset:glm53-spark-tp2"'
contains "$PULL" 'startswith("environment:")'
contains "$PULL" '.settings["served-model-name"].source == "cli"'
contains "$PULL" 'base_proof_sha256'
contains "$PULL" 'upstream_doc='
# The proof must stay CPU-only: no GPUs, no model load.
lacks "$PULL" '--gpus'

# --- download script pins the exact checkpoint revision -----------------------
contains "$DL" 'REPO="local-inference-lab/GLM-5.3-Flash-NVFP4-Spark"'
contains "$DL" 'REV="a608241037e4c2565356bff7ca293f2133888f88"'
contains "$DL" 'CACHE_HOST="${CACHE_HOST:-/models/hf-cache/glm53-flash-spark-tp2-v14}"'
contains "$DL" 'hf download "$REPO" --revision "$REV"'
contains "$DL" 'local_files_only=True'
contains "$DL" '.download-complete'
contains "$DL" 'flash-spark-tp2-v14-checkpoint.txt'
contains "$DL" 'IMAGE_CONFIG="sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a"'
contains "$DL" 'HF_XET_HIGH_PERFORMANCE=1'
lacks "$DL" '--gpus'

# --- run script serves exactly the pinned profile in the doc's container shape
contains "$RUN" "IMAGE_CONFIG=\"sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a\""
contains "$RUN" "PULL_REF=\"$PULL_REF\""
contains "$RUN" "PRESET=\"$PRESET\""
contains "$RUN" "NAME=\"$CONTAINER\""
contains "$RUN" "SERVED_MODEL=\"$SERVED_MODEL\""
contains "$RUN" 'HF_CACHE_HOST="${HF_CACHE_HOST:-/models/hf-cache/glm53-flash-spark-tp2-v14}"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-spark-tp2-v14}"'
contains "$RUN" 'GPU_ORDER="${GPU_ORDER:-0,1}"'
contains "$RUN" 'MODEL_REVISION="a608241037e4c2565356bff7ca293f2133888f88"'
contains "$RUN" '-v "$HF_CACHE_HOST:/root/.cache/huggingface"'
contains "$RUN" '-e MODEL_REVISION="$MODEL_REVISION"'
contains "$RUN" '-e HF_HUB_OFFLINE=1'
contains "$RUN" '.download-complete'
contains "$RUN" 'snapshots/$MODEL_REVISION'
contains "$RUN" 'models--${CHECKPOINT%%/*}--${CHECKPOINT##*/}'
contains "$RUN" '-v "$CACHE_HOST:/cache"'
contains "$RUN" '-e PRESET="$PRESET"'
contains "$RUN" '-e PORT=8000'
contains "$RUN" '-e SERVED_MODEL_NAME="$SERVED_MODEL"'
contains "$RUN" '--restart no'
contains "$RUN" '--gpus "\"device=$GPU_ORDER\""'
contains "$RUN" '--network host'
contains "$RUN" '--ipc host'
contains "$RUN" '--shm-size 32g'
contains "$RUN" '--ulimit memlock=-1'
contains "$RUN" '--ulimit stack=67108864:67108864'
contains "$RUN" '--security-opt seccomp=unconfined'
contains "$RUN" 'machines/desktop/default.nix'
contains "$RUN" 'gpuPowerLimitWatts = ([0-9]+);'
contains "$RUN" '--print-config'
contains "$RUN" 'cuda_runtime_probe()'
contains "$RUN" 'CUDA RUNTIME PROBE: PASS'
contains "$RUN" '615.71.09'
contains "$RUN" '--preflight'
if grep -Eq '^[[:space:]]*-e VLLM_API_KEY=' "$RUN"; then
  echo 'FAIL: launcher leaks VLLM_API_KEY through argv' >&2
  exit 1
fi
lacks "$RUN" '--api-key'
contains "$RUN" '--env-file "$ENVFILE"'
contains "$RUN" 'inference_write_private_file "$ENVFILE" <<EOF'
contains "$RUN" 'CACHE_MODE="${CACHE_MODE:-vram}"'
contains "$RUN" 'LMCACHE_L1_GB'
contains "$RUN" 'LMCACHE_L2_ENABLED'
contains "$RUN" '18000 18001 18002'
# The preset owns the memory contract; these must not be overridden.
lacks "$RUN" 'MAX_MODEL_LEN='
lacks "$RUN" 'KV_CACHE_MEMORY_BYTES='
lacks "$RUN" 'GPU_MEMORY_UTILIZATION='
lacks "$RUN" '--max-model-len'
lacks "$RUN" '--kv-cache-memory-bytes'
lacks "$RUN" '--tensor-parallel-size'
lacks "$RUN" '--max-num-seqs'
lacks "$RUN" '--max-num-batched-tokens'
# The checkpoint is pre-downloaded and pinned: offline serving is the design.
lacks "$RUN" 'HF_HUB_OFFLINE=0'
lacks "$RUN" 'TRANSFORMERS_OFFLINE'
# The retired EXL3 K4 switch set must not be carried into the upstream image.
# The run script rejects every retired variable name at launch; that rejection
# list is the proof, so the contract pins the list and the absence of any
# production use (`-e NAME=` or exports of the variable).
contains "$RUN" 'for switch in VLLM_B12X_FP8_KV VLLM_B12X_GLM_NOPE_NVFP4 VLLM_DCP_GLOBAL_TOPK'
lacks "$RUN" '-e VLLM_B12X_FP8_KV'
lacks "$RUN" '-e VLLM_DCP_GLOBAL_TOPK'
lacks "$RUN" 'VLLM_DCP_GLOBAL_TOPK='
lacks "$RUN" 'VLLM_USE_B12X_DCP_A2A='
lacks "$RUN" 'PCIE_ALLREDUCE='
lacks "$RUN" 'GLM_NOPE_FP8='

# --- switch script is transactional with the boot receipt --------------------
contains "$SWITCH" "TARGET=\"$CONTAINER\""
contains "$SWITCH" "EXPECTED_MODEL=\"$SERVED_MODEL\""
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
contains "$SWITCH" 'promote_restart_policy'
contains "$SWITCH" 'restart=unless-stopped'
contains "$SWITCH" 'flash-spark-tp2-v14-boot-receipt.txt'
contains "$SWITCH" 'STARTUP_TIMEOUT_SECONDS="${STARTUP_TIMEOUT_SECONDS:-5400}"'
contains "$SWITCH" 'require_idle_endpoint'
contains "$SWITCH" 'inference_quiesce_failed_container'
lacks "$SWITCH" 'VLLM_B12X_FP8_KV'

# --- catalog carries the container -------------------------------------------
contains "$CATALOG" "$CONTAINER"

# --- Pi catalog and routing carry the exact same ids --------------------------
jq -e --arg id "$SERVED_MODEL" '
  .providers["desktop-vllm"].models | any(.id == $id)
' "$PI_MODELS" >/dev/null || {
  echo "FAIL: pi/models.json lacks $SERVED_MODEL" >&2
  exit 1
}
jq -e --arg id "$SERVED_MODEL" '
  (.providers["desktop-vllm"].models[] | select(.id == $id)) as $m
  | ($m.contextWindow == 983040)
  and ($m.input | index("image") != null)
  and ($m.input | index("text") != null)
  and ($m.reasoning == true)
  and ($m.compat.thinkingFormat == "deepseek")
  and ($m.compat.supportsDeveloperRole == false)
' "$PI_MODELS" >/dev/null || {
  echo "FAIL: pi/models.json $SERVED_MODEL entry does not match the v14 contract" >&2
  exit 1
}
jq -e '
  .targets["glm-v14"].model == "desktop-vllm/glm-5.3-flash-spark-tp2-v14"
  and .targets["glm-v14"].thinkingLevel == "max"
' "$PI_ROUTING" >/dev/null || {
  echo "FAIL: pi/model-routing.json lacks the glm-v14 exact target" >&2
  exit 1
}
jq -e '
  .rules | any(
    .id == "glm-v14-subagents-use-max"
    and .when.parentModel == "desktop-vllm/glm-5.3-flash-spark-tp2-v14"
    and .use.target == "glm-v14"
  )
' "$PI_ROUTING" >/dev/null || {
  echo "FAIL: pi/model-routing.json lacks the glm-v14 subagent rule" >&2
  exit 1
}
contains "$PI_README" "$SERVED_MODEL"
contains "$PI_README" '983,040'
contains "$PI_README" 'glm-v14'

# --- runbook stays coherent ---------------------------------------------------
contains "$RUNBOOK" "$SERVED_MODEL"
contains "$RUNBOOK" "$PULL_REF"
contains "$RUNBOOK" 'karmic-kraken-beta'
contains "$RUNBOOK" '4190109696'
contains "$RUNBOOK" 'flash-spark-tp2-v14-boot-receipt.txt'
contains "$RUNBOOK" 'Serving since 2026-09-19'
contains "$RUNBOOK" '983,040'

echo "GLM-5.3 v14 upstream spark-preset contract: PASS"
