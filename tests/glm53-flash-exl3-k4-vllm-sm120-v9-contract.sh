#!/usr/bin/env bash
# Static release contract for the graph-enabled GLM-5.3 v9 fast/safe candidate.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v9-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v9.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v9.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-exl3-k4-vllm-sm120-v9-runbook-2026-08-31.md"
OVERLAY="$ROOT/scripts/inference/glm53/glm53-v9-fast-safe"
DOCKERFILE="$OVERLAY/Dockerfile"
VERIFY="$OVERLAY/verify.py"
STATE_PATCH="$OVERLAY/glm53-v9-state-graph-safety.patch"
TOPK_PATCH="$OVERLAY/glm53-v9-fast-persistent-topk.patch"

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || { echo "FAIL: $file lacks $text" >&2; exit 1; }
}

for file in "$PULL" "$RUN" "$SWITCH" "$VERIFY"; do
  [ -x "$file" ] || { echo "FAIL: not executable: $file" >&2; exit 1; }
done
for file in "$PULL" "$RUN" "$SWITCH"; do bash -n "$file"; done
jq -e . "$PI_MODELS" >/dev/null

contains "$PULL" 'sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2'
contains "$PULL" 'sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$PULL" 'sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578'
contains "$PULL" 'vllm-project/vllm#50729@a02cfccbc6187344325e364f09f6d8c33c4b253b'
contains "$PULL" 'vllm-project/vllm#54296@191f82d710493c9a02077d976d8cf0403ab8c96a'
contains "$PULL" 'vllm-project/vllm#52149@b8f88c1a29f54dcc42f1b163db523bf362e845e3'
contains "$PULL" 'does not retain the exact base rootfs prefix'
contains "$PULL" 'docker run --rm -i --gpus all'
contains "$PULL" 'compiled_extension_sha256=$COMPILED_EXTENSION_SHA256'

[ "$(sha256sum "$STATE_PATCH" | cut -d' ' -f1)" = '4ecec3de89f52125fc5884e4924ed5fb326bb1d9e6a97fc04a005147e22ea528' ] || {
  echo 'FAIL: v9 state/graph patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$TOPK_PATCH" | cut -d' ' -f1)" = '8baae7bea9cb85cf72dfc86702187b0227ff585fcb81dbdc8b30747195c24395' ] || {
  echo 'FAIL: v9 fast top-k patch digest differs' >&2
  exit 1
}
contains "$STATE_PATCH" 'is_left_overlap = dst_ptr < src_ptr and dst_ptr + size > src_ptr'
contains "$STATE_PATCH" 'in_range = block_indices < block_table_stride'
contains "$STATE_PATCH" '& (block_indices < block_table_stride)'
contains "$STATE_PATCH" 'out = slot_mapping'
if grep '^+' "$STATE_PATCH" | grep -Fq 'slot_mapping.clone()'; then
  echo 'FAIL: v9 state patch captures a transient KPool slot tensor' >&2
  exit 1
fi
contains "$TOPK_PATCH" 'exact_topk_rescan'
contains "$TOPK_PATCH" 'collect_pivot_matches_deterministically'
contains "$TOPK_PATCH" 'stable rank'
contains "$TOPK_PATCH" 'COARSE_BITS = 11'
contains "$TOPK_PATCH" '#include <cub/block/block_scan.cuh>'

contains "$DOCKERFILE" 'FROM verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140'
contains "$DOCKERFILE" 'patch --batch --fuzz=0'
contains "$DOCKERFILE" 'cmake --build /tmp/vllm-cmake --target _C_stable_libtorch -j 2'
contains "$VERIFY" 'b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415'
contains "$DOCKERFILE" 'd6b447486d8186625e5b7ac196c3d04c5e6f016232d6511df68c3515ac71d078'

contains "$VERIFY" 'expected_values = torch.topk'
contains "$VERIFY" 'equal_width = 8_192'
contains "$VERIFY" 'columns, visible, regression_topk = 806_736, 4_096, 512'
contains "$VERIFY" 'assert persistent_ms < torch_ms'
contains "$VERIFY" 'output.data_ptr() == original_address'
contains "$VERIFY" 'torch.tensor([28, -1, -1]'
contains "$VERIFY" 'batch_memcpy(src_ptrs, dst_ptrs, sizes)'

contains "$RUN" 'IMAGE="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9"'
contains "$RUN" 'NAME="glm53-flash-exl3-k4-vllm-sm120-v9"'
contains "$RUN" 'MAX_MODEL_LEN="${MAX_MODEL_LEN:-359000}"'
contains "$RUN" 'MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-2048}"'
contains "$RUN" 'MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"'
contains "$RUN" 'GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.986}"'
contains "$RUN" '-e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0'
contains "$RUN" '--restart no'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--decode-context-parallel-size 1'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" '--attention-backend FLASHINFER_MLA_SPARSE_SM120'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"greedy"}'\'''
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$RUN" 'ai.peterstorm.inference.graph-mode=cudagraph-dcp1-candidate'
contains "$RUN" 'ai.peterstorm.inference.exact-sparse-topk=pr52149-overflow-radix-deterministic-ties'
if grep -Fq -- '--enforce-eager' "$RUN"; then
  echo 'FAIL: v9 graph candidate still forces eager execution' >&2
  exit 1
fi
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v9"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'IDLE GATE: no running or waiting requests across three samples'
contains "$SWITCH" 'Available KV cache memory:'
contains "$SWITCH" 'GPU KV cache size:'
contains "$SWITCH" 'UNPROMOTED: restart=no retained pending equivalence and soak gates'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
if grep -Fq 'docker update --restart=unless-stopped' "$SWITCH"; then
  echo 'FAIL: unqualified v9 switcher promotes restart policy' >&2
  exit 1
fi
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v9'
contains "$RUNBOOK" '82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9") |
  .input == ["text", "image"] and
  .contextWindow == 359000 and
  .defaultThinkingLevel == "max"
' "$PI_MODELS" >/dev/null

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
assert_invalid_preflight 'MAX_NUM_SEQS must be an integer in [1, 4]' MAX_NUM_SEQS=5
assert_invalid_preflight 'fixes GPU_MEMORY_UTILIZATION at 0.986' GPU_MEMORY_UTILIZATION=0.987

echo 'PASS: GLM-5.3 v9 is immutable, graph-enabled, restart-safe, vision/MTP/PFC preserving, overflow-exact, tie-deterministic, state-overlap-safe, and slot-bounded'
