#!/usr/bin/env bash
# Static release contract for the isolated GLM-5.3 v10 TP2/EP2/DCP2 candidate.
# shellcheck disable=SC2016
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PULL="$ROOT/scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v10-image.sh"
RUN="$ROOT/scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v10.sh"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-exl3-profile-v10.sh"
CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"
PI_MODELS="$ROOT/pi/models.json"
RUNBOOK="$ROOT/docs/runbooks/glm53-flash-exl3-k4-vllm-sm120-v10-runbook-2026-08-31.md"
OVERLAY="$ROOT/scripts/inference/glm53/glm53-v10-dcp2-safe"
DOCKERFILE="$OVERLAY/Dockerfile"
VERIFY="$OVERLAY/verify.py"
DCP_PATCH="$OVERLAY/glm53-v10-dcp2-mamba-geometry.patch"
MTP_PATCH="$OVERLAY/glm53-v10-mtp-position-zero.patch"
B12X_PATCH="$OVERLAY/glm53-v10-b12x-glm-next-fp8.patch"
FP8_SPEC_PATCH="$OVERLAY/glm53-v10-glm-next-fp8-spec.patch"
HYBRID_PAGE_PATCH="$OVERLAY/glm53-v10-hybrid-page-padding.patch"
B12X_PADDED_PAGE_PATCH="$OVERLAY/glm53-v10-b12x-padded-page.patch"
B12X_SOURCE="$OVERLAY/b12x-903667d36aee19320776019a31dd06d1e9255b6a.tar.gz"

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
contains "$PULL" 'sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553'
contains "$PULL" 'vllm-project/vllm#50287@3a91629d06826edb624323694c211831234a64a6'
contains "$PULL" 'local-inference-lab/vllm#539@4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7'
contains "$PULL" 'does not retain the exact v9 rootfs prefix'
contains "$PULL" 'docker run --rm -i --gpus all'
contains "$PULL" 'compiled_extension_sha256=$COMPILED_EXTENSION_SHA256'

[ "$(sha256sum "$DCP_PATCH" | cut -d' ' -f1)" = '7ebef333c9ef4f363136fb0f78a622edbf886e0b62bd2e87fba11b17164c705a' ] || {
  echo 'FAIL: v10 DCP geometry patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$MTP_PATCH" | cut -d' ' -f1)" = '0e723d2978ac6d42ce7963727638a80c984a6111cfbe304d507444005362d253' ] || {
  echo 'FAIL: v10 MTP position-zero patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$B12X_PATCH" | cut -d' ' -f1)" = '60bf08b17169dfe65105460790b371035b0109098dce69107edc868b3e70b4e4' ] || {
  echo 'FAIL: v10 B12X adapter patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$FP8_SPEC_PATCH" | cut -d' ' -f1)" = 'c2f4e4724da7c3f3306030a3ac1406a8d3e304301de92a753df4d56d574f3fbc' ] || {
  echo 'FAIL: v10 GLM_NEXT FP8 spec patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$HYBRID_PAGE_PATCH" | cut -d' ' -f1)" = 'c6098ffef5b662dd91820f14485642e8cb94662544e2f18a877ebfc5d6d0eec5' ] || {
  echo 'FAIL: v10 hybrid page padding patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$B12X_PADDED_PAGE_PATCH" | cut -d' ' -f1)" = 'fc6ae25924cca96c652044abd52166970e9f8057264daa6625e0ff1aa8ab84b8' ] || {
  echo 'FAIL: v10 B12X padded page patch digest differs' >&2
  exit 1
}
[ "$(sha256sum "$B12X_SOURCE" | cut -d' ' -f1)" = '4a9eafc91967d6e88169522c0db6e234025cc372e205ffa0f354d74e210dba57' ] || {
  echo 'FAIL: v10 B12X source snapshot digest differs' >&2
  exit 1
}
contains "$DCP_PATCH" 'if isinstance(spec, MambaSpec):'
contains "$DCP_PATCH" 'return 1'
contains "$DCP_PATCH" 'exceeds row capacity'
contains "$MTP_PATCH" 'Position zero contains a shifted live token during MTP first-pass.'
contains "$MTP_PATCH" 'Normalize live MTP embeddings and previous hidden states'
contains "$B12X_PATCH" 'VLLM_B12X_GLM_NOPE_FP8'
contains "$B12X_PATCH" 'ModelType.GLM_NEXT'
contains "$B12X_PATCH" 'self._kv_record_bytes = 528'
contains "$B12X_PATCH" 'model_type=self._b12x_model_type'
contains "$FP8_SPEC_PATCH" 'model_version = "glm_next_fp8"'
contains "$FP8_SPEC_PATCH" 'return self.storage_block_size * 528'
contains "$FP8_SPEC_PATCH" 'vllm_config.cache_config.block_size * 656'
contains "$HYBRID_PAGE_PATCH" 's.page_size_padded >= s.real_page_size_bytes'
contains "$B12X_PADDED_PAGE_PATCH" 'def _require_packed_paged_kv_cache('
contains "$B12X_PADDED_PAGE_PATCH" 'compile_glm_next_mla_cache_writer'
contains "$B12X_PADDED_PAGE_PATCH" '(self.block_size * 656, self._kv_record_bytes, 1)'
if grep '^+' "$MTP_PATCH" | grep -Fq 'positions.eq(0)'; then
  echo 'FAIL: v10 MTP patch still zeroes the live position-zero embedding' >&2
  exit 1
fi

contains "$DOCKERFILE" 'FROM peterstorm/vllm:glm53-v9-fast-safe'
contains "$DOCKERFILE" 'ai.peterstorm.inference.base-image="sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2"'
contains "$DOCKERFILE" 'ai.peterstorm.inference.mamba-dcp-layout="replicated-full-position-table"'
contains "$DOCKERFILE" 'ai.peterstorm.inference.block-table-overflow="fail-closed"'
contains "$DOCKERFILE" 'local-inference-lab/vllm#539@4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7-adapted'
contains "$DOCKERFILE" 'ai.peterstorm.inference.b12x-attention-commit="903667d36aee19320776019a31dd06d1e9255b6a"'
contains "$DOCKERFILE" 'ai.peterstorm.inference.b12x-moe-lineage="v9-byte-exact-36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8"'
contains "$DOCKERFILE" '2097654986b70e80698cdd4bb69bafcfa136b57361074bba4741b09ec3e3d010'
contains "$DOCKERFILE" 'ai.peterstorm.inference.glm-next-fp8-abi="explicit-model-type-528-byte-record"'
contains "$DOCKERFILE" 'ai.peterstorm.inference.glm-next-fp8-spec="logical-528-physical-656-hybrid-page"'
contains "$DOCKERFILE" 'ai.peterstorm.inference.b12x-padded-page="packed-stride-writer-precompile"'
contains "$DOCKERFILE" 'd9dc3eda5024866711aa352036d0edd87772943eabdc3ce4e3a8b0ad9bf96641'
contains "$DOCKERFILE" 'patch --batch --fuzz=0'
contains "$DOCKERFILE" 'd89c89ea3c76132d5f7c1a7675d6cb577ffb56c3087bb45133b65ed626461e7f'
contains "$DOCKERFILE" '433190de4bdb5db55f4464b511e4953fe7e22bab9d9b73cc884cc25ffc83c7af'

contains "$VERIFY" 'b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415'
contains "$VERIFY" 'assert "B12X_MLA_SPARSE" in AttentionBackendEnum.__members__'
contains "$VERIFY" 'verify_b12x_glm_next_fp8()'
contains "$VERIFY" 'sparse_mla.ModelType.GLM_NEXT'
contains "$VERIFY" 'GLM_NEXT_STRIDE = (GLM_NEXT_PAGE_STRIDE, GLM_NEXT_RECORD_BYTES, 1)'
contains "$VERIFY" 'assert tuple(kv_cache.stride()) == GLM_NEXT_STRIDE'
contains "$VERIFY" 'sparse_mla.compile_glm_next_mla_cache_writer'
contains "$VERIFY" 'with torch.cuda.graph(graph):'
contains "$VERIFY" 'ops.cp_gather_cache('
contains "$VERIFY" '("decode", sparse_mla.run_decode), ("extend", sparse_mla.run_extend)'
contains "$VERIFY" 'get_kv_cache_dcp_shard_count(mamba, 2) == 1'
contains "$VERIFY" 'get_kv_cache_dcp_shard_count(attention, 2) == 2'
contains "$VERIFY" 'oversized block-table writes must fail closed'
contains "$VERIFY" 'verify_mtp_position_zero_embedding()'
contains "$VERIFY" 'torch.count_nonzero(output[0, :width]).item() == width'
contains "$VERIFY" 'expected_values = torch.topk'
contains "$VERIFY" 'columns, visible, regression_topk = 806_736, 4_096, 512'
contains "$VERIFY" 'assert persistent_ms < torch_ms'
contains "$VERIFY" 'output.data_ptr() == original_address'
contains "$VERIFY" 'batch_memcpy(src_ptrs, dst_ptrs, sizes)'

contains "$RUN" 'IMAGE="sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553"'
contains "$RUN" 'SERVED_MODEL="glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10"'
contains "$RUN" 'NAME="glm53-flash-exl3-k4-vllm-sm120-v10"'
contains "$RUN" 'CACHE_HOST="${CACHE_HOST:-/models/vllm-cache/glm53-flash-exl3-k4-sm120-v10}"'
contains "$RUN" '--restart no'
contains "$RUN" '--tensor-parallel-size 2'
contains "$RUN" '--decode-context-parallel-size 2'
contains "$RUN" '--dcp-comm-backend ag_rs'
contains "$RUN" '--enable-expert-parallel'
contains "$RUN" '--enable-prefix-caching'
contains "$RUN" '--kv-cache-dtype fp8_ds_mla'
contains "$RUN" 'KV_CACHE_MEMORY_BYTES="${KV_CACHE_MEMORY_BYTES:-3758096384}"'
contains "$RUN" '--kv-cache-memory-bytes "$KV_CACHE_MEMORY_BYTES"'
contains "$RUN" 'ai.peterstorm.inference.runtime-headroom=dcp2-prefill-all-gather-safe'
contains "$RUN" '--attention-backend B12X_MLA_SPARSE'
contains "$RUN" '-e VLLM_B12X_GLM_NOPE_FP8=1'
contains "$RUN" '-e VLLM_DCP_GLOBAL_TOPK=1'
contains "$RUN" '-e VLLM_DCP_TOPK_OWNER_MERGE=1'
contains "$RUN" '-e VLLM_B12X_DCP_TOPK_OWNER_EXCHANGE=1'
contains "$RUN" '-e VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0'
contains "$RUN" '"cudagraph_capture_sizes":[1,2,3,4,8,12,16]'
contains "$RUN" '--speculative-config '\''{"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"greedy"}'\'''
contains "$RUN" '--chat-template /opt/glm53/chat_template.multimodal.jinja'
contains "$RUN" '--limit-mm-per-prompt '\''{"image":4,"video":0}'\'''
contains "$RUN" 'ai.peterstorm.inference.graph-mode=cudagraph-dcp2-mtp3-dense-shapes-candidate'
if grep -Fq -- '--enforce-eager' "$RUN"; then
  echo 'FAIL: v10 graph candidate still forces eager execution' >&2
  exit 1
fi
if grep -Fq -- '--api-key' "$RUN"; then
  echo 'FAIL: API key must not appear in process arguments' >&2
  exit 1
fi
if grep -Eiq 'replayssm|method[=:].*dflash' "$RUN"; then
  echo 'FAIL: v10 must use built-in MTP3 without ReplaySSM or DFlash' >&2
  exit 1
fi

contains "$SWITCH" 'TARGET="glm53-flash-exl3-k4-vllm-sm120-v10"'
contains "$SWITCH" 'length == 1 and .[0].id == $expected'
contains "$SWITCH" 'IDLE GATE: no running or waiting requests across three samples'
contains "$SWITCH" 'Configured KV cache memory:'
contains "$SWITCH" 'ai.peterstorm.inference.kv-cache-memory-bytes-per-gpu'
contains "$SWITCH" 'GPU KV cache size:'
contains "$SWITCH" 'UNPROMOTED: restart=no retained pending equivalence and soak gates'
contains "$SWITCH" 'restore_profiles "${previous[@]}"'
if grep -Fq 'docker update --restart=unless-stopped' "$SWITCH"; then
  echo 'FAIL: unqualified v10 switcher promotes restart policy' >&2
  exit 1
fi
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v9'
contains "$CATALOG" 'glm53-flash-exl3-k4-vllm-sm120-v10'
contains "$RUNBOOK" 'ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553'

jq -e '
  .providers["desktop-vllm"].models[] |
  select(.id == "glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v10") |
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
assert_invalid_preflight 'fixes KV_CACHE_MEMORY_BYTES at 3758096384' KV_CACHE_MEMORY_BYTES=3758096385

echo 'PASS: GLM-5.3 v10 is immutable, v9-derived, DCP2/B12X/ag-rs isolated, MTP-position-correct, recurrent-table-safe, graph-shape-complete, and restart-safe'
