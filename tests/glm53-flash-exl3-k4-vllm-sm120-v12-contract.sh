#!/usr/bin/env bash
# Static release contract for the candidate GLM-5.3 v12 upstream-core-port profile.
#
# v12 is v11.1 (legend r2.1) plus exactly the four changes ported from the Spark
# TP2 source-locked image (2026-09-13 R2 update): PR #710 SM120/121
# disjoint-batch BMM, PR #718 Mamba recurrent-state cleanup across null gaps,
# PR #694 graph-memory double-count fix, and the CUBLAS_WORKSPACE_CONFIG=:4096:1
# launcher setting. The upstream patches are made against 7f4aecc6 and do not
# apply to the legend r2.1 overlay files, so the port is by hand. The contract
# proves, without Docker or a GPU, that the vendored overlay IS that port:
# byte-pinned archive, exactly three modified files plus one new overlay file
# and one manifest line against v11.1's archive, the three r2.1 fix sites plus
# the four port sites present, the code each fix replaces absent, the base
# stop-at-first-null behavior preserved, and every serve/switch/build pin
# coherent with it.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
PULL="$GLM/pull-glm53-flash-exl3-k4-vllm-sm120-v12-image.sh"
RUN="$GLM/run-glm53-flash-exl3-k4-vllm-sm120-v12.sh"
SWITCH="$GLM/switch-glm53-exl3-profile-v12.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_README="$ROOT/pi/README.md"
OVERLAY="$GLM/glm53-v12-upstream-core-port"
DOCKERFILE="$OVERLAY/Dockerfile"
INSTALLER="$OVERLAY/install-overlay.py"
COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"
SOURCE_PORT="pr710-sm120-disjoint-bmm+pr718-mamba-null-gap+pr694-graph-memory-once+cublas-4mib"
ARCHIVE="$OVERLAY/upstream-core-port-v12-pr710-pr718-pr694.tar.gz"
ARCHIVE_SHA256="f36de6931717fa114476a518513fa2a1f2f307c50f9a64cdee1d6666b42cf553"
V11_ARCHIVE="$GLM/glm53-v11.1-upstream-core-port/upstream-core-port-$COMMIT.tar.gz"
V11_ARCHIVE_SHA256="91c370ce94e93ef73b09974a2b627cf6b26e8bd3f5a1d4a88022c56742db3c83"
CORE="upstream-core-port/upstream-g1/vllm/v1/core"
# The exact line fix 0006 deletes; shipping it means shipping the wedge.
R2_DRAIN_GATE='if self.defer_block_free and scheduler_output.total_num_scheduled_tokens > 0:'
# The exact v11.1 double-count line PR #694 replaces.
V111_DOUBLE_COUNT='profile_result.transient_peak_headroom + cudagraph_memory_estimate_applied'
# The exact v11.1 decode-path bmm calls PR #710 replaces.
V111_DECODE_BMM='torch.bmm(mqa_q_nope, W_UK_T, out=mqa_ql_nope)'
V111_V_UP_BMM='torch.bmm(x, self.W_UV, out=out.transpose(0, 1))'

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

for file in "$PULL" "$RUN" "$SWITCH"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
  bash -n "$file"
done
jq -e . "$PI_MODELS" >/dev/null

# --- the vendored overlay is the v12 port and nothing else -------------------
digest_is "$ARCHIVE" "$ARCHIVE_SHA256"
digest_is "$V11_ARCHIVE" "$V11_ARCHIVE_SHA256"
if tar -tzf "$ARCHIVE" | grep -Eq '__pycache__|\.pyc$'; then
  echo 'FAIL: v12 overlay archive ships compiled artifacts' >&2
  exit 1
fi
[ "$(tar -tzf "$ARCHIVE" | grep -vc '/$')" = 102 ] || {
  echo 'FAIL: v12 overlay archive must carry 102 files (99 manifest sources + gpu_worker.py + 2 supplements + MANIFEST.txt)' >&2
  exit 1
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/r21" "$scratch/r2"
tar -xzf "$ARCHIVE" -C "$scratch/r21"
tar -xzf "$V11_ARCHIVE" -C "$scratch/r2"
# Exactly three modified files plus the new gpu_worker.py and the one manifest
# line differ from v11.1's overlay; every kernel/model file is byte-identical,
# so v11.1's install counts move only by the pinned gpu_worker additions.
changed="$(cd "$scratch" && { diff -rq r2/upstream-core-port r21/upstream-core-port || true; } | sed -E 's#^Files r2/upstream-core-port/(.*) and .*#\1#' | sort)"
expected_changed="$(printf '%s\n' \
  'MANIFEST.txt' \
  'Only in r21/upstream-core-port/upstream-g2/vllm/v1/worker: gpu_worker.py' \
  'upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py' \
  'upstream-g2/vllm/model_executor/layers/attention/mla_attention.py' \
  'upstream-g2/vllm/v1/attention/ops/dcp.py')"
[ "$changed" = "$expected_changed" ] || {
  printf 'FAIL: v12 overlay must differ from v11.1 in exactly three modified files, the new gpu_worker.py, and MANIFEST.txt; got:\n%s\n' "$changed" >&2
  exit 1
}
# The manifest extends v11.1's by exactly one line: the gpu_worker.py mapping.
v12_mappings="$(grep -v '^#' "$scratch/r21/upstream-core-port/MANIFEST.txt" | grep -c ' -> ')"
[ "$v12_mappings" = 100 ] || {
  echo "FAIL: v12 MANIFEST.txt must carry 100 mappings, got $v12_mappings" >&2
  exit 1
}
grep -v '^#' "$scratch/r2/upstream-core-port/MANIFEST.txt" | grep ' -> ' | sort >"$scratch/v11-mappings.txt"
grep -v '^#' "$scratch/r21/upstream-core-port/MANIFEST.txt" | grep ' -> ' | sort >"$scratch/v12-mappings.txt"
comm -13 "$scratch/v11-mappings.txt" "$scratch/v12-mappings.txt" >"$scratch/added-mappings.txt"
[ "$(wc -l <"$scratch/added-mappings.txt")" = 1 ] || {
  echo 'FAIL: v12 MANIFEST.txt must add exactly one mapping over v11.1' >&2
  exit 1
}
grep -Fq 'upstream-g2/vllm/v1/worker/gpu_worker.py -> /opt/infernal-invocation/vllm/vllm/v1/worker/gpu_worker.py' "$scratch/added-mappings.txt" || {
  echo 'FAIL: the added v12 mapping is not the gpu_worker.py replacement' >&2
  exit 1
}
SINGLE_TYPE="$scratch/r21/$CORE/single_type_kv_cache_manager.py"
MLA="$scratch/r21/upstream-core-port/upstream-g2/vllm/model_executor/layers/attention/mla_attention.py"
DCP="$scratch/r21/upstream-core-port/upstream-g2/vllm/v1/attention/ops/dcp.py"
GPU_WORKER="$scratch/r21/upstream-core-port/upstream-g2/vllm/v1/worker/gpu_worker.py"
digest_is "$SINGLE_TYPE" '917fd3d501cd98d8f9c85750ed2d3abd419bf9f8f558aa86e2dc3a00394f523e'
digest_is "$MLA" 'c9cf1e6869dbd47bb081e6a49ed9ed5723333e689c5f21ff3174927ef8d1e480'
digest_is "$DCP" '9c9d883633b43f901279b5daff5f310c2fe9f6fb13da368635f19ed2f9279ab0'
digest_is "$GPU_WORKER" '2ddbc92952dcf7e4be8f8128e6dd4c000b0422b58703fb2b27e21db4ffe5c704'
# r2.1 fixes remain: 0004 align cap bills the real footprint; legacy billing is
# an explicit opt-in; 0005 reserve aging; 0006 deferred frees drain.
KV_MANAGER="$scratch/r21/$CORE/kv_cache_manager.py"
SCHEDULER="$scratch/r21/$CORE/sched/scheduler.py"
contains "$SINGLE_TYPE" 'VLLM_MAMBA_ALIGN_CAP_LEGACY'
contains "$SINGLE_TYPE" 'self._align_cap_legacy'
contains "$KV_MANAGER" 'VLLM_MAMBA_STATE_PROTECT_AGE'
contains "$KV_MANAGER" '[MAMBA-RESERVE-AGE]'
contains "$SCHEDULER" '[DEFER-FREE-DRAIN]'
lacks "$SCHEDULER" "$R2_DRAIN_GATE"
lacks "$SCHEDULER" 'chunk_cap'
# PR #710: SM120 disjoint-batch BMM; raw call sites replaced in v12, intact in v11.1.
contains "$MLA" 'def _bmm_with_disjoint_batches('
contains "$MLA" 'current_platform.is_device_capability_family(120)'
[ "$(grep -c '_bmm_with_disjoint_batches(' "$MLA")" = 3 ] || {
  echo 'FAIL: PR #710 helper must route both decode-path bmm sites plus its definition' >&2
  exit 1
}
lacks "$MLA" "$V111_DECODE_BMM"
lacks "$MLA" "$V111_V_UP_BMM"
contains "$scratch/r2/upstream-core-port/upstream-g2/vllm/model_executor/layers/attention/mla_attention.py" "$V111_DECODE_BMM"
contains "$scratch/r2/upstream-core-port/upstream-g2/vllm/model_executor/layers/attention/mla_attention.py" "$V111_V_UP_BMM"
contains "$DCP" 'cp_group.reduce_scatter(out.transpose(0, 1).contiguous(), dim=0)'
contains "$DCP" 'cp_group.reduce_scatter(out, dim=1)'
contains "$DCP" 'from vllm.platforms import current_platform'
# PR #718: Mamba null-gap cleanup; the base stop-at-first-null is preserved.
contains "$SINGLE_TYPE" '_num_retired_blocks'
contains "$SINGLE_TYPE" '[MAMBA-NULL-GAP]'
contains "$SINGLE_TYPE" 'if blocks[i].is_null:
                continue'
contains "$SINGLE_TYPE" 'if blocks[i] == self._null_block:
                break'
contains "$SINGLE_TYPE" 'self._num_retired_blocks.pop(request_id, None)'
lacks "$scratch/r2/$CORE/single_type_kv_cache_manager.py" '_num_retired_blocks'
# PR #694: graph-memory double-count fix; the v11.1 double-count line is gone.
contains "$GPU_WORKER" '[GRAPH-MEMORY-ONCE]'
contains "$GPU_WORKER" 'self.peak_activation_memory = profile_result.transient_peak_headroom'
lacks "$GPU_WORKER" "$V111_DOUBLE_COUNT"
contains "$GPU_WORKER" '- cudagraph_memory_estimate_applied'
# The double-count line lives in the base image's gpu_worker.py (verified
# against the pinned base blob in the research evidence); the v11.1 overlay
# does not carry gpu_worker.py at all — v12 introduces it as an overlay file.
if tar -tzf "$V11_ARCHIVE" | grep -q 'gpu_worker'; then
  echo 'FAIL: v11.1 overlay must not carry gpu_worker.py; v12 introduces it' >&2
  exit 1
fi

# --- build pins -------------------------------------------------------------
contains "$DOCKERFILE" 'FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$DOCKERFILE" 'ADD upstream-core-port-v12-pr710-pr718-pr694.tar.gz /tmp/'
contains "$DOCKERFILE" 'ai.peterstorm.inference.upstream-core-port.release=v12'
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.commit=$COMMIT"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.source-port=$SOURCE_PORT"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.overlay-sha256=$ARCHIVE_SHA256"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.predecessor=r2.1-$COMMIT"
contains "$DOCKERFILE" 'ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b'
contains "$DOCKERFILE" 'RUN /opt/venv/bin/python /tmp/install-overlay.py'
contains "$DOCKERFILE" 'COPY upstream-core-port-v12-pr710-pr718-pr694.tar.gz /opt/glm53/upstream-core-port-v12.tar.gz'

contains "$INSTALLER" 'EXPECTED_MAPPINGS = 100'
contains "$INSTALLER" 'EXPECTED_DESTINATIONS = 102'
contains "$INSTALLER" 'EXPECTED_REPLACEMENTS = 92'
contains "$INSTALLER" 'EXPECTED_ADDITIONS = 10'
contains "$INSTALLER" '"r7/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py"'
contains "$INSTALLER" '"r7/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py"'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/kv_cache_manager.py", "VLLM_MAMBA_STATE_PROTECT_AGE")'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py", "VLLM_MAMBA_ALIGN_CAP_LEGACY")'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/sched/scheduler.py", "[DEFER-FREE-DRAIN]")'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py", "[MAMBA-NULL-GAP]")'
contains "$INSTALLER" '("upstream-g2/vllm/v1/worker/gpu_worker.py", "[GRAPH-MEMORY-ONCE]")'
contains "$INSTALLER" '("upstream-g2/vllm/model_executor/layers/attention/mla_attention.py", "[SM120-DISJOINT-BMM]")'
contains "$INSTALLER" '("upstream-g2/vllm/v1/attention/ops/dcp.py", "[SM120-DISJOINT-BMM]")'
contains "$INSTALLER" 'py_compile.compile(str(destination), doraise=True)'
contains "$INSTALLER" 'V12 OVERLAY INSTALLED'

contains "$PULL" 'BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"'
contains "$PULL" 'BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"'
contains "$PULL" 'BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"'
contains "$PULL" 'DERIVED_TAG="peterstorm/vllm:glm53-v12-upstream-core-port"'
contains "$PULL" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$PULL" "UPSTREAM_PREDECESSOR=\"$COMMIT\""
contains "$PULL" "SOURCE_PORT=\"$SOURCE_PORT\""
contains "$PULL" "OVERLAY_SHA256=\"$ARCHIVE_SHA256\""
contains "$PULL" 'OVERLAY_DIR="$SCRIPT_DIR/glm53-v12-upstream-core-port"'
contains "$PULL" '[ "$release_label" = v12 ]'
contains "$PULL" '[ "$source_port_label" = "$SOURCE_PORT" ]'
contains "$PULL" "\"710 mla contiguous-operand helper\": '_bmm_with_disjoint_batches' in mla"
contains "$PULL" "\"710 dcp head-major reduce-scatter\": (
        "
contains "$PULL" "\"718 retirement high-water mark\": '_num_retired_blocks' in single_type"
contains "$PULL" "\"694 activation-only profile peak\": (
        "
contains "$PULL" "$V111_DOUBLE_COUNT"
contains "$PULL" 'V12 IMAGE CONTENT PROOF'
contains "$PULL" 'class CountedBlocks(list):' # focused CPU test: no-rescan lineage
contains "$PULL" 'assert blocks.reads == 0, "cleanup rescanned already-retired history"'

# --- serve profile ----------------------------------------------------------
contains "$RUN" 'NAME="glm53-flash-exl3-k4-vllm-sm120-v12"'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v12}"'
contains "$RUN" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$RUN" "SOURCE_PORT=\"$SOURCE_PORT\""
contains "$RUN" '[ "$overlay_release" = v12 ]'
contains "$RUN" '[ "$overlay_commit" = "$UPSTREAM_COMMIT" ]'
contains "$RUN" '[ "$overlay_source_port" = "$SOURCE_PORT" ]'
contains "$RUN" '--restart no'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend a2a'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--prefill-schedule-interval 8'
contains "$RUN" '-e VLLM_B12X_FP8_KV=1'
contains "$RUN" '-e CUBLAS_WORKSPACE_CONFIG=:4096:1'
contains "$RUN" '-e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0'
contains "$RUN" 'MAMBA_STATE_PROTECT="${MAMBA_STATE_PROTECT:-16}"'
contains "$RUN" 'MAMBA_STATE_PROTECT_AGE="${MAMBA_STATE_PROTECT_AGE:-128}"'
contains "$RUN" '-e VLLM_MAMBA_STATE_PROTECT="$MAMBA_STATE_PROTECT"'
contains "$RUN" '-e VLLM_MAMBA_STATE_PROTECT_AGE="$MAMBA_STATE_PROTECT_AGE"'
contains "$RUN" '--label ai.peterstorm.inference.mamba-state-protect-age="$MAMBA_STATE_PROTECT_AGE"'
contains "$RUN" '--label ai.peterstorm.inference.upstream-core-port="legend-r2.1-$UPSTREAM_COMMIT+ported"'
contains "$RUN" '--label ai.peterstorm.inference.source-port="$SOURCE_PORT"'
contains "$RUN" '--label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v12-boot'
contains "$RUN" '[ ! -e "$CACHE_HOST/.diff-dump" ]'
contains "$RUN" '"cudagraph_capture_sizes":[1,2,4,8,16,24,32,40,48,56,64]'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}'\'''
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
lacks "$RUN" '-e VLLM_MAMBA_ALIGN_CAP_LEGACY'
lacks "$RUN" '-e VLLM_B12X_GLM_NOPE_NVFP4'
lacks "$RUN" '--enforce-eager'
lacks "$RUN" '--api-key'
if grep -Eiq 'replayssm|method[=:].*dflash' "$RUN"; then
  echo 'FAIL: v12 must use built-in MTP3 without ReplaySSM or DFlash' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v12"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12"'
contains "$SWITCH" 'RUN="$SCRIPT_DIR/run-glm53-flash-exl3-k4-vllm-sm120-v12.sh"'
contains "$SWITCH" "SOURCE_PORT=\"$SOURCE_PORT\""
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'IDLE GATE: no running or waiting requests across three samples'
contains "$SWITCH" 'GPU KV cache size:'
contains "$SWITCH" 'mamba_state_protect_age=%s'
contains "$SWITCH" 'source_port=%s'
contains "$SWITCH" 'docker update --restart=unless-stopped "$TARGET"'
contains "$SWITCH" 'PROMOTED: restart=unless-stopped'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'

contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v10'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v11'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v11.1'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v12'
contains "$PI_README" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1'
contains "$PI_README" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12") |
  .input == ["text", "image"] and
  .contextWindow == 359000 and
  .defaultThinkingLevel == "max" and
  .compat.thinkingFormat == "deepseek"
' "$PI_MODELS" >/dev/null

# --- preflight refuses every invalid shape before touching Docker -----------
assert_invalid_preflight() {
  local expected="$1"
  shift
  local output status
  set +e
  output="$(env "$@" bash "$RUN" --preflight 2>&1)"
  status=$?
  set -e
  [ "$status" -eq 2 ] || { echo "FAIL: invalid preflight status=$status: $*" >&2; exit 1; }
  grep -Fq -- "$expected" <<<"$output" || {
    echo "FAIL: invalid preflight did not report: $expected" >&2
    exit 1
  }
}

assert_invalid_preflight 'MAX_MODEL_LEN must be an integer in [1, 359000]' MAX_MODEL_LEN=359001
assert_invalid_preflight 'MAX_NUM_BATCHED_TOKENS must be an integer in [1, 2048]' MAX_NUM_BATCHED_TOKENS=2049
assert_invalid_preflight 'MAX_NUM_SEQS must be an integer in [1, 16]' MAX_NUM_SEQS=17
assert_invalid_preflight 'MAMBA_STATE_PROTECT must be an integer in [0, 64]' MAMBA_STATE_PROTECT=65
assert_invalid_preflight 'MAMBA_STATE_PROTECT_AGE must be an integer in [1, 100000]' MAMBA_STATE_PROTECT_AGE=0
assert_invalid_preflight 'couples the retention interval to 17920' PREFIX_CACHE_RETENTION_INTERVAL=15616
assert_invalid_preflight 'restores the r2 admission deadlock' VLLM_MAMBA_ALIGN_CAP_LEGACY=1

# The image id is recorded from the first build on the serving host. Until then
# the profile must be unlaunchable; once recorded, the pin must be a real
# config digest. Both states are asserted, so recording the id needs no test
# edit and forgetting to record it cannot pass as "serving".
if grep -Fq 'IMAGE_CONFIG="unrecorded"' "$RUN"; then
  assert_invalid_preflight 'image id is not recorded' HOME="$scratch"
else
  grep -Eq '^IMAGE_CONFIG="sha256:[0-9a-f]{64}"$' "$RUN" || {
    echo 'FAIL: IMAGE_CONFIG must be "unrecorded" or a full sha256 config digest' >&2
    exit 1
  }
fi
contains "$RUN" 'IMAGE="$IMAGE_CONFIG"'

echo 'PASS: GLM-5.3 v12 is v11.1 plus exactly the Spark TP2 port (PR #710 SM120 disjoint-BMM, PR #718 Mamba null-gap cleanup, PR #694 graph-memory double-count fix, cublas 4 MiB workspace), byte-pinned, fail-closed, and promoted only after acceptance'
