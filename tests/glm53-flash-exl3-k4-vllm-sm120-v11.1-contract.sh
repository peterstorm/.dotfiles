#!/usr/bin/env bash
# Static release contract for the GLM-5.3 v11.1 upstream-core-port r2.1 candidate.
#
# v11.1 is v11 (legend r2) plus the single upstream commit that fixes r2's
# admission deadlock (running=0, waiting=N, KV usage 0% once a long session
# heads the waiting queue). The contract proves, without Docker or a GPU, that
# the vendored overlay IS that commit: byte-pinned archive, exactly three files
# changed against v11's archive, the three fix sites present, the r2 code they
# replace absent, and every serve/switch/build pin coherent with it.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM="$ROOT/scripts/inference/glm53"
PULL="$GLM/pull-glm53-flash-exl3-k4-vllm-sm120-v11.1-image.sh"
RUN="$GLM/run-glm53-flash-exl3-k4-vllm-sm120-v11.1.sh"
SWITCH="$GLM/switch-glm53-exl3-profile-v11.1.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
PI_README="$ROOT/pi/README.md"
OVERLAY="$GLM/glm53-v11.1-upstream-core-port"
DOCKERFILE="$OVERLAY/Dockerfile"
INSTALLER="$OVERLAY/install-overlay.py"
COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"
PREDECESSOR="e65b2012d4ead12c86bd03f7e435ebace3ed3ae2"
ARCHIVE="$OVERLAY/upstream-core-port-$COMMIT.tar.gz"
ARCHIVE_SHA256="91c370ce94e93ef73b09974a2b627cf6b26e8bd3f5a1d4a88022c56742db3c83"
V11_ARCHIVE="$GLM/glm53-v11-upstream-core-port/upstream-core-port-$PREDECESSOR.tar.gz"
V11_ARCHIVE_SHA256="c5cef15c27e3d638ba3a77dda522f877786de7c250d2ffb21e9373408cf48c26"
CORE="upstream-core-port/upstream-g1/vllm/v1/core"
# The exact line fix 0006 deletes; shipping it means shipping the wedge.
R2_DRAIN_GATE='if self.defer_block_free and scheduler_output.total_num_scheduled_tokens > 0:'

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

# --- the vendored overlay is r2.1 and nothing else -------------------------
digest_is "$ARCHIVE" "$ARCHIVE_SHA256"
digest_is "$V11_ARCHIVE" "$V11_ARCHIVE_SHA256"
if tar -tzf "$ARCHIVE" | grep -Eq '__pycache__|\.pyc$'; then
  echo 'FAIL: v11.1 overlay archive ships compiled artifacts' >&2
  exit 1
fi
[ "$(tar -tzf "$ARCHIVE" | grep -vc '/$')" = 101 ] || {
  echo 'FAIL: v11.1 overlay archive must carry 101 files (98 unique manifest sources + 2 supplements + MANIFEST.txt)' >&2
  exit 1
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/r21" "$scratch/r2"
tar -xzf "$ARCHIVE" -C "$scratch/r21"
tar -xzf "$V11_ARCHIVE" -C "$scratch/r2"
# Exactly the three engine-core files differ from v11's overlay; the manifest
# and every kernel/model file are byte-identical, so v11's install counts hold.
changed="$(cd "$scratch" && { diff -rq r2/upstream-core-port r21/upstream-core-port || true; } | sed -E 's#^Files r2/upstream-core-port/(.*) and .*#\1#' | sort)"
expected_changed="$(printf '%s\n' \
  'upstream-g1/vllm/v1/core/kv_cache_manager.py' \
  'upstream-g1/vllm/v1/core/sched/scheduler.py' \
  'upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py')"
[ "$changed" = "$expected_changed" ] || {
  printf 'FAIL: r2.1 overlay must differ from r2 in exactly three core files; got:\n%s\n' "$changed" >&2
  exit 1
}
cmp -s "$scratch/r2/upstream-core-port/MANIFEST.txt" "$scratch/r21/upstream-core-port/MANIFEST.txt" || {
  echo 'FAIL: r2.1 MANIFEST.txt drifted from r2; the pinned install counts no longer hold' >&2
  exit 1
}
KV_MANAGER="$scratch/r21/$CORE/kv_cache_manager.py"
SINGLE_TYPE="$scratch/r21/$CORE/single_type_kv_cache_manager.py"
SCHEDULER="$scratch/r21/$CORE/sched/scheduler.py"
digest_is "$KV_MANAGER" 'bfbd40edab24f64c12474e27f305cbb5d0a02eff6cf7f88d6f59db7f103d0da9'
digest_is "$SINGLE_TYPE" '0878bab84f3ccbdb2c77b409535e867541b0b180e0c6d3a4ebf1d12a5083acf5'
digest_is "$SCHEDULER" '6b7095c0977f56246997326e22d5627b40fdabc70cc2542bcc5e8497ffb64fc5'
# 0004: align cap bills the real footprint; legacy billing is an explicit opt-in.
contains "$SINGLE_TYPE" 'VLLM_MAMBA_ALIGN_CAP_LEGACY'
contains "$SINGLE_TYPE" 'self._align_cap_legacy'
contains "$SINGLE_TYPE" 'self.num_speculative_blocks'
# 0005: a request blocked solely by the reserve ages out and is admitted.
contains "$KV_MANAGER" 'VLLM_MAMBA_STATE_PROTECT_AGE'
contains "$KV_MANAGER" '[MAMBA-RESERVE-AGE]'
contains "$KV_MANAGER" 'required_without_reserve'
contains "$KV_MANAGER" 'self._reserve_blocked.pop(request.request_id, None)'
# 0006: deferred frees drain on every update, including 0-token steps.
contains "$SCHEDULER" '[DEFER-FREE-DRAIN]'
lacks "$SCHEDULER" "$R2_DRAIN_GATE"
contains "$scratch/r2/$CORE/sched/scheduler.py" "$R2_DRAIN_GATE"
# r2.1 removes Fix B's decode-aware chunk cap; v11 carried it.
lacks "$SCHEDULER" 'chunk_cap'
contains "$scratch/r2/$CORE/sched/scheduler.py" 'chunk_cap'

# --- build pins -------------------------------------------------------------
contains "$DOCKERFILE" 'FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$DOCKERFILE" "ADD upstream-core-port-$COMMIT.tar.gz /tmp/"
contains "$DOCKERFILE" 'ai.peterstorm.inference.upstream-core-port.release=r2.1'
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.commit=$COMMIT"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.overlay-sha256=$ARCHIVE_SHA256"
contains "$DOCKERFILE" "ai.peterstorm.inference.upstream-core-port.predecessor=r2-$PREDECESSOR"
contains "$DOCKERFILE" 'ai.peterstorm.inference.kv-cache=fp8_ds_mla-glm-nope-528b'
contains "$DOCKERFILE" 'RUN /opt/venv/bin/python /tmp/install-overlay.py'
contains "$DOCKERFILE" "COPY upstream-core-port-$COMMIT.tar.gz /opt/glm53/upstream-core-port-r2.1.tar.gz"

contains "$INSTALLER" 'EXPECTED_MAPPINGS = 99'
contains "$INSTALLER" 'EXPECTED_DESTINATIONS = 101'
contains "$INSTALLER" 'EXPECTED_REPLACEMENTS = 91'
contains "$INSTALLER" 'EXPECTED_ADDITIONS = 10'
contains "$INSTALLER" '"r7/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py"'
contains "$INSTALLER" '"r7/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py"'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/kv_cache_manager.py", "VLLM_MAMBA_STATE_PROTECT_AGE")'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py", "VLLM_MAMBA_ALIGN_CAP_LEGACY")'
contains "$INSTALLER" '("upstream-g1/vllm/v1/core/sched/scheduler.py", "[DEFER-FREE-DRAIN]")'
contains "$INSTALLER" 'py_compile.compile(str(destination), doraise=True)'
contains "$INSTALLER" 'V11.1 OVERLAY INSTALLED'

contains "$PULL" 'BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"'
contains "$PULL" 'BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"'
contains "$PULL" 'BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"'
contains "$PULL" 'DERIVED_TAG="peterstorm/vllm:glm53-v11.1-upstream-core-port-r2.1"'
contains "$PULL" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$PULL" "UPSTREAM_PREDECESSOR=\"$PREDECESSOR\""
contains "$PULL" "OVERLAY_SHA256=\"$ARCHIVE_SHA256\""
contains "$PULL" 'OVERLAY_DIR="$SCRIPT_DIR/glm53-v11.1-upstream-core-port"'
contains "$PULL" '[ "$release_label" = r2.1 ]'
contains "$PULL" "\"0004 align-cap billing mode switch\": 'VLLM_MAMBA_ALIGN_CAP_LEGACY' in single_type"
contains "$PULL" "\"0005 reserve aging knob\": 'VLLM_MAMBA_STATE_PROTECT_AGE' in kv_manager"
contains "$PULL" "\"0006 unconditional drain\": '[DEFER-FREE-DRAIN]' in scheduler"
contains "$PULL" "$R2_DRAIN_GATE"
contains "$PULL" "\"Fix B chunk cap removed\": 'chunk_cap' not in scheduler"
contains "$PULL" 'V11.1 IMAGE CONTENT PROOF'

# --- serve profile ----------------------------------------------------------
contains "$RUN" 'NAME="glm53-flash-exl3-k4-vllm-sm120-v11.1"'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v11.1}"'
contains "$RUN" "UPSTREAM_COMMIT=\"$COMMIT\""
contains "$RUN" '[ "$overlay_release" = r2.1 ]'
contains "$RUN" '[ "$overlay_commit" = "$UPSTREAM_COMMIT" ]'
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
contains "$RUN" 'MAMBA_STATE_PROTECT="${MAMBA_STATE_PROTECT:-16}"'
contains "$RUN" 'MAMBA_STATE_PROTECT_AGE="${MAMBA_STATE_PROTECT_AGE:-128}"'
contains "$RUN" '-e VLLM_MAMBA_STATE_PROTECT="$MAMBA_STATE_PROTECT"'
contains "$RUN" '-e VLLM_MAMBA_STATE_PROTECT_AGE="$MAMBA_STATE_PROTECT_AGE"'
contains "$RUN" '--label ai.peterstorm.inference.mamba-state-protect-age="$MAMBA_STATE_PROTECT_AGE"'
contains "$RUN" '--label ai.peterstorm.inference.upstream-core-port="legend-r2.1-$UPSTREAM_COMMIT"'
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
  echo 'FAIL: v11.1 must use built-in MTP3 without ReplaySSM or DFlash' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v11.1"'
contains "$SWITCH" 'EXPECTED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1"'
contains "$SWITCH" 'RUN="$SCRIPT_DIR/run-glm53-flash-exl3-k4-vllm-sm120-v11.1.sh"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'IDLE GATE: no running or waiting requests across three samples'
contains "$SWITCH" 'GPU KV cache size:'
contains "$SWITCH" 'mamba_state_protect_age=%s'
contains "$SWITCH" 'UNPROMOTED: restart=no retained pending equivalence and soak gates'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
lacks "$SWITCH" 'docker update --restart=unless-stopped'

contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v10'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v11'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v11.1'
contains "$PI_README" 'desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1") |
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

echo 'PASS: GLM-5.3 v11.1 is v11 plus exactly upstream r2.1 (admission deadlock fix 0004/0005/0006, Fix B cap removed), byte-pinned, fail-closed, unlaunchable until its image id is recorded'
