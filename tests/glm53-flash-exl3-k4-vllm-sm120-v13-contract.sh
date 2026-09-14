#!/usr/bin/env bash
# Static release contract for the candidate GLM-5.3 v13 grammar-port profile.
#
# v13 is v12 (legend r2.1 + the Spark TP2 port) plus exactly the grammar
# redesign port (PR #52477 fixed-width stride, four new overlay files) and two
# upstream hardening fixes folded into it (#53046 FSM validate-before-accept,
# #55455 warmup defers adaptive verification). The upstream patches are made
# against upstream and do not apply to the legend overlay files, so the port is
# by hand. The contract proves, without Docker or a GPU, that the vendored
# overlay IS that port: byte-pinned archive, exactly four new overlay entries
# and one manifest line extension against v12's archive, the r2.1 fix sites
# plus the four v12 port sites plus the three v13 port sites present, the code
# each fix replaces absent, the crash-design function definition gone, and
# every serve/switch/build pin coherent with it.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
PULL="$GLM/pull-glm53-flash-exl3-k4-vllm-sm120-v13-image.sh"
RUN="$GLM/run-glm53-flash-exl3-k4-vllm-sm120-v13.sh"
SWITCH="$GLM/switch-glm53-exl3-profile-v13.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_README="$ROOT/pi/README.md"
OVERLAY="$GLM/glm53-v13-grammar-port"
DOCKERFILE="$OVERLAY/Dockerfile"
INSTALLER="$OVERLAY/install-overlay.py"
COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"
SOURCE_PORT="pr52477-grammar-port+pr53046-fsm-validate+pr55455-warmup-defer"
ARCHIVE="$OVERLAY/upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz"
ARCHIVE_SHA256="685f6966d72cc643a47a2291ca897f4f09ac3ba42e09bf8663dc5f5028db4ae6"
V12_ARCHIVE="$GLM/glm53-v12-upstream-core-port/upstream-core-port-v12-pr710-pr718-pr694.tar.gz"
V12_ARCHIVE_SHA256="f36de6931717fa114476a518513fa2a1f2f307c50f9a64cdee1d6666b42cf553"
CORE="upstream-core-port/upstream-g1/vllm/v1/core"
# The exact line fix 0006 deletes; shipping it means shipping the wedge.
R2_DRAIN_GATE='if self.defer_block_free and scheduler_output.total_num_scheduled_tokens > 0:'
# The exact v11.1 double-count line PR #694 replaces.
V111_DOUBLE_COUNT='profile_result.transient_peak_headroom + cudagraph_memory_estimate_applied'
# The exact v11.1 decode-path bmm calls PR #710 replaces.
V111_DECODE_BMM='torch.bmm(mqa_q_nope, W_UK_T, out=mqa_ql_nope)'
V111_V_UP_BMM='torch.bmm(x, self.W_UV, out=out.transpose(0, 1))'
# The crash-design function PR #52477 removes: its "def " definition may not
# appear anywhere in the ported worker file (the only _build_grammar_row_mapping
# reference is the header comment describing the bug).
CRASH_DESIGN_DEF='def _build_grammar_row_mapping'

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

# --- the vendored overlay is the v13 port and nothing else -------------------
digest_is "$ARCHIVE" "$ARCHIVE_SHA256"
digest_is "$V12_ARCHIVE" "$V12_ARCHIVE_SHA256"
if tar -tzf "$ARCHIVE" 2>/dev/null | grep -Eq '__pycache__|\.pyc$'; then
  echo 'FAIL: v13 overlay archive ships compiled artifacts' >&2
  exit 1
fi
[ "$(tar -tzf "$ARCHIVE" 2>/dev/null | grep -vc '/$')" = 106 ] || {
  echo 'FAIL: v13 overlay archive must carry 106 files (104 manifest sources + 2 supplements + MANIFEST.txt)' >&2
  exit 1
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/v12" "$scratch/v13"
tar -xzf "$V12_ARCHIVE" -C "$scratch/v12" 2>/dev/null
tar -xzf "$ARCHIVE" -C "$scratch/v13" 2>/dev/null
# Exactly the four new overlay entries and the one manifest line extension
# differ from v12's overlay; every other file is byte-identical, so v12's
# install counts move only by the pinned ported-file replacements.
changed="$(cd "$scratch" && { diff -rq v12/upstream-core-port v13/upstream-core-port || true; } | sed -E 's#^Files v12/upstream-core-port/(.*) and .*#\1#' | sort)"
expected_changed="$(printf '%s\n' \
  'MANIFEST.txt' \
  'Only in v13/upstream-core-port/upstream-g2/vllm/v1: structured_output' \
  'Only in v13/upstream-core-port/upstream-g2/vllm/v1/worker/gpu: structured_outputs.py' \
  'Only in v13/upstream-core-port/upstream-g2/vllm/v1/worker/gpu: warmup.py')"
[ "$changed" = "$expected_changed" ] || {
  printf 'FAIL: v13 overlay must differ from v12 in exactly the four new overlay entries and MANIFEST.txt; got:\n%s\n' "$changed" >&2
  exit 1
}
# The manifest extends v12's by exactly four lines: the four ported files.
v13_mappings="$(grep -v '^#' "$scratch/v13/upstream-core-port/MANIFEST.txt" | grep -c ' -> ')"
[ "$v13_mappings" = 104 ] || {
  echo "FAIL: v13 MANIFEST.txt must carry 104 mappings, got $v13_mappings" >&2
  exit 1
}
grep -v '^#' "$scratch/v12/upstream-core-port/MANIFEST.txt" | grep ' -> ' | sort >"$scratch/v12-mappings.txt"
grep -v '^#' "$scratch/v13/upstream-core-port/MANIFEST.txt" | grep ' -> ' | sort >"$scratch/v13-mappings.txt"
comm -13 "$scratch/v12-mappings.txt" "$scratch/v13-mappings.txt" >"$scratch/added-mappings.txt"
[ "$(wc -l <"$scratch/added-mappings.txt")" = 4 ] || {
  echo 'FAIL: v13 MANIFEST.txt must add exactly four mappings over v12' >&2
  exit 1
}
for mapping in \
  'upstream-g2/vllm/v1/structured_output/__init__.py -> /opt/infernal-invocation/vllm/vllm/v1/structured_output/__init__.py' \
  'upstream-g2/vllm/v1/structured_output/utils.py -> /opt/infernal-invocation/vllm/vllm/v1/structured_output/utils.py' \
  'upstream-g2/vllm/v1/worker/gpu/structured_outputs.py -> /opt/infernal-invocation/vllm/vllm/v1/worker/gpu/structured_outputs.py' \
  'upstream-g2/vllm/v1/worker/gpu/warmup.py -> /opt/infernal-invocation/vllm/vllm/v1/worker/gpu/warmup.py'; do
  grep -Fq -- "$mapping" "$scratch/added-mappings.txt" || {
    echo "FAIL: the added v13 mappings do not include: $mapping" >&2
    exit 1
  }
done
SO_PRODUCER="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/structured_output/__init__.py"
SO_UTILS="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/structured_output/utils.py"
SO_WORKER="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/worker/gpu/structured_outputs.py"
WARMUP="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/worker/gpu/warmup.py"
digest_is "$SO_PRODUCER" '2401ab161b07e7f0b70a3ed0312473a2fe0aa3aba22559e58415aacd0405ebf2'
digest_is "$SO_UTILS" '7f1a9042f7c6f51bafa62275ff3637a2ade3a54716d891cd30da7358071b8286'
digest_is "$SO_WORKER" 'd290a2cb7c26385737c2d2be35ddd201ab2df806c3dd4062d4b68d053a4e9825'
digest_is "$WARMUP" '838f4e837303b304090513465d6291929964984ebd47931b1afb02105dd38d30'
# v12 content survives the v13 overlay byte-identically: the diff above proves
# it for every other file; these digests pin the v12 port sites inside v13.
SINGLE_TYPE="$scratch/v13/$CORE/single_type_kv_cache_manager.py"
MLA="$scratch/v13/upstream-core-port/upstream-g2/vllm/model_executor/layers/attention/mla_attention.py"
DCP="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/attention/ops/dcp.py"
GPU_WORKER="$scratch/v13/upstream-core-port/upstream-g2/vllm/v1/worker/gpu_worker.py"
digest_is "$SINGLE_TYPE" '917fd3d501cd98d8f9c85750ed2d3abd419bf9f8f558aa86e2dc3a00394f523e'
digest_is "$MLA" 'c9cf1e6869dbd47bb081e6a49ed9ed5723333e689c5f21ff3174927ef8d1e480'
digest_is "$DCP" '9c9d883633b43f901279b5daff5f310c2fe9f6fb13da368635f19ed2f9279ab0'
digest_is "$GPU_WORKER" '2ddbc92952dcf7e4be8f8128e6dd4c000b0422b58703fb2b27e21db4ffe5c704'
# r2.1 fixes remain: 0004 align cap bills the real footprint; legacy billing is
# an explicit opt-in; 0005 reserve aging; 0006 deferred frees drain.
KV_MANAGER="$scratch/v13/$CORE/kv_cache_manager.py"
SCHEDULER="$scratch/v13/$CORE/sched/scheduler.py"
contains "$SINGLE_TYPE" 'VLLM_MAMBA_ALIGN_CAP_LEGACY'
contains "$SINGLE_TYPE" 'self._align_cap_legacy'
contains "$KV_MANAGER" 'VLLM_MAMBA_STATE_PROTECT_AGE'
contains "$KV_MANAGER" '[MAMBA-RESERVE-AGE]'
contains "$SCHEDULER" '[DEFER-FREE-DRAIN]'
lacks "$SCHEDULER" "$R2_DRAIN_GATE"
lacks "$SCHEDULER" 'chunk_cap'
# v12 PR #710: SM120 disjoint-batch BMM, intact in v13.
contains "$MLA" 'def _bmm_with_disjoint_batches('
contains "$MLA" 'current_platform.is_device_capability_family(120)'
[ "$(grep -c '_bmm_with_disjoint_batches(' "$MLA")" = 3 ] || {
  echo 'FAIL: PR #710 helper must route both decode-path bmm sites plus its definition' >&2
  exit 1
}
lacks "$MLA" "$V111_DECODE_BMM"
lacks "$MLA" "$V111_V_UP_BMM"
contains "$DCP" 'cp_group.reduce_scatter(out.transpose(0, 1).contiguous(), dim=0)'
contains "$DCP" 'cp_group.reduce_scatter(out, dim=1)'
# v12 PR #718: Mamba null-gap cleanup; the base stop-at-first-null is preserved.
contains "$SINGLE_TYPE" '_num_retired_blocks'
contains "$SINGLE_TYPE" '[MAMBA-NULL-GAP]'
contains "$SINGLE_TYPE" 'if blocks[i].is_null:
                continue'
contains "$SINGLE_TYPE" 'if blocks[i] == self._null_block:
                break'
contains "$SINGLE_TYPE" 'self._num_retired_blocks.pop(request_id, None)'
# v12 PR #694: graph-memory double-count fix.
contains "$GPU_WORKER" '[GRAPH-MEMORY-ONCE]'
contains "$GPU_WORKER" 'self.peak_activation_memory = profile_result.transient_peak_headroom'
lacks "$GPU_WORKER" "$V111_DOUBLE_COUNT"
contains "$GPU_WORKER" '- cudagraph_memory_estimate_applied'
# PR #52477: GPU-count-driven grammar masks; the crash design is gone.
contains "$SO_WORKER" '[PR52477-PORT]'
contains "$SO_WORKER" 'assert grammar_bitmask.shape[0] == num_grammar_reqs * self.mask_stride'
contains "$SO_WORKER" 'input_batch.cu_num_logits'
contains "$SO_WORKER" 'grid = (num_grammar_reqs, triton.cdiv'
lacks "$SO_WORKER" "$CRASH_DESIGN_DEF"
# The fragile compaction assertion is gone as code: the header comment's
# line-broken "asserting num_active_drafts <=\nnum_source_drafts" form does
# not match the one-line assertion the old design shipped.
lacks "$SO_WORKER" 'assert num_active_drafts <= num_source_drafts'
contains "$SO_PRODUCER" '[PR52477-PORT]'
contains "$SO_PRODUCER" '[PR53046-PORT]'
contains "$SO_PRODUCER" 'post_reasoning_end_in_window'
contains "$SO_PRODUCER" 'grammar.validate_tokens([token])'
contains "$SO_PRODUCER" 'accepted = grammar.accept_tokens(req_id, [token])'
contains "$SO_UTILS" '[PR52477-PORT]'
contains "$WARMUP" '[PR52477-PORT]'
contains "$WARMUP" '[PR55455-PORT]'
contains "$WARMUP" 'model_runner.adaptive_verification = None'
contains "$WARMUP" '_warmup_kernels(model_runner, worker_execute_model, worker_sample_tokens)'
contains "$WARMUP" 'model_runner.adaptive_verification = adaptive_verification'

# --- build pins -------------------------------------------------------------
contains "$DOCKERFILE" 'FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$DOCKERFILE" 'ADD upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz /tmp/'
contains "$DOCKERFILE" 'ai.peterstorm.inference.upstream-core-port.release=v13'
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.commit=$COMMIT"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.source-port=$SOURCE_PORT"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.overlay-sha256=$ARCHIVE_SHA256"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.predecessor=v12-$COMMIT"
contains "$DOCKERFILE" 'ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b'
contains "$DOCKERFILE" 'RUN /opt/venv/bin/python /tmp/install-overlay.py'
contains "$DOCKERFILE" 'COPY upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz /opt/glm53/upstream-core-port-v13.tar.gz'

contains "$INSTALLER" 'EXPECTED_MAPPINGS = 104'
contains "$INSTALLER" 'EXPECTED_DESTINATIONS = 105'
contains "$INSTALLER" 'EXPECTED_REPLACEMENTS = 96'
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
contains "$INSTALLER" '("upstream-g2/vllm/v1/worker/gpu/structured_outputs.py", "[PR52477-PORT]")'
contains "$INSTALLER" '("upstream-g2/vllm/v1/structured_output/__init__.py", "[PR53046-PORT]")'
contains "$INSTALLER" '("upstream-g2/vllm/v1/worker/gpu/warmup.py", "[PR55455-PORT]")'
contains "$INSTALLER" 'py_compile.compile(str(destination), doraise=True)'
contains "$INSTALLER" 'V13 OVERLAY INSTALLED'

contains "$PULL" 'BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"'
contains "$PULL" 'BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"'
contains "$PULL" 'BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"'
contains "$PULL" 'DERIVED_TAG="peterstorm/vllm:glm53-v13-grammar-port"'
contains "$PULL" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$PULL" "UPSTREAM_PREDECESSOR=\"$COMMIT\""
contains "$PULL" "SOURCE_PORT=\"$SOURCE_PORT\""
contains "$PULL" "OVERLAY_SHA256=\"$ARCHIVE_SHA256\""
contains "$PULL" 'OVERLAY_DIR="$SCRIPT_DIR/glm53-v13-grammar-port"'
contains "$PULL" '[ "$release_label" = v13 ]'
contains "$PULL" '[ "$source_port_label" = "$SOURCE_PORT" ]'
contains "$PULL" '"52477 fixed-width invariant": (
        '
contains "$PULL" '"52477 crash design gone"'
contains "$PULL" '"53046 validate-before-accept"'
contains "$PULL" '"55455 warmup defers adaptive verification": (
        '
contains "$PULL" 'V13 IMAGE CONTENT PROOF'
contains "$PULL" 'class CountedBlocks(list):' # focused CPU regression test: no-rescan lineage
contains "$PULL" 'assert blocks.reads == 0, "cleanup rescanned already-retired history"'

# --- serve profile ----------------------------------------------------------
contains "$RUN" 'NAME="glm53-flash-exl3-k4-vllm-sm120-v13"'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v13"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v13}"'
contains "$RUN" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$RUN" "SOURCE_PORT=\"$SOURCE_PORT\""
contains "$RUN" '[ "$overlay_release" = v13 ]'
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
contains "$RUN" '--label ai.peterstorm.inference.upstream-core-port="legend-r2.1-$UPSTREAM_COMMIT+grammar-port"'
contains "$RUN" '--label ai.peterstorm.inference.source-port="$SOURCE_PORT"'
contains "$RUN" '--label ai.peterstorm.inference.capacity-evidence=must-be-recorded-from-each-v13-boot'
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
  echo 'FAIL: v13 must use built-in MTP3 without ReplaySSM or DFlash' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v13"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v13"'
contains "$SWITCH" 'RUN="$SCRIPT_DIR/run-glm53-flash-exl3-k4-vllm-sm120-v13.sh"'
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
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v13'
contains "$PI_README" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v12'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v13") |
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

echo 'PASS: GLM-5.3 v13 is v12 plus exactly the grammar redesign port (PR #52477 fixed-width stride replacing the _build_grammar_row_mapping crash, #53046 FSM validate-before-accept, #55455 warmup defer), byte-pinned, fail-closed, and promoted only after acceptance'
