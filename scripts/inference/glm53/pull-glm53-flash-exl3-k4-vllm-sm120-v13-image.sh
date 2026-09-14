#!/usr/bin/env bash
# Build and prove the GLM-5.3 v13 image: our pinned v84 base plus the legend
# upstream-core-port r2.1 overlay plus the four changes ported from the Spark
# TP2 source-locked image (2026-09-13 R2 update) plus the grammar redesign port
# and two upstream hardening fixes.
#
# v13 = v12 plus exactly:
#   PR vllm/vllm#52477 "grammar redesign" (fixed-width stride):
#     structured/guided decoding combined with MTP3 speculative decoding
#     crashes the engine in _build_grammar_row_mapping — the v11.1/v12 crash
#     loop. worker/gpu/structured_outputs.py is a full rewrite (GPU-count-
#     driven masks; the Triton kernel reads the request's actual logit count
#     from device-side cu_num_logits), the producer and the dormant consumer
#     are ported to the fixed-width stride, and the warmup bitmask is resized.
#   upstream vllm/vllm#53046 "FSM validate-before-accept" (producer): when a
#     reasoning model ends its think block mid-token-window, the token is
#     validated before acceptance so an invalid draft cannot corrupt the
#     grammar state. Confirmed missing from the fork base before porting.
#   upstream vllm/vllm#55455 "warmup defers adaptive verification": warmup
#     defers DSpark adaptive verification during warmup; body moved to
#     _warmup_kernels. Confirmed missing from the fork base before porting.
#
# The overlay differs from v12's in exactly four new overlay files and four
# manifest lines; everything else — base, manifest policy, install policy — is
# v12's with the pinned counts moved from 100/102/92/10 to 104/106/96/10.
set -euo pipefail

BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
DERIVED_TAG="peterstorm/vllm:glm53-v13-grammar-port"
UPSTREAM_REPO="https://github.com/legend/glm-5.3-flash-exl3-4bpw"
UPSTREAM_COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"
UPSTREAM_PREDECESSOR="832e6000120148f82c64acaecc56b6f96c27e6e2"
SOURCE_PORT="pr52477-grammar-port+pr53046-fsm-validate+pr55455-warmup-defer"
OVERLAY_SHA256="685f6966d72cc643a47a2291ca897f4f09ac3ba42e09bf8663dc5f5028db4ae6"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v13-image.identity}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-v13-grammar-port"
OVERLAY_ARCHIVE="$OVERLAY_DIR/upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz"

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "error: this image is prepared only for linux/amd64 SM120 hosts" >&2
  exit 1
}
for command in docker jq sha256sum; do
  command -v "$command" >/dev/null 2>&1 || {
    echo "error: $command is required to build and prove the image" >&2
    exit 1
  }
done

actual_overlay_sha256="$(sha256sum "$OVERLAY_ARCHIVE" | cut -d' ' -f1)"
[ "$actual_overlay_sha256" = "$OVERLAY_SHA256" ] || {
  echo "error: vendored upstream-core-port archive is $actual_overlay_sha256, expected $OVERLAY_SHA256" >&2
  exit 1
}

# The overlay archive is the only source of engine/kernel code in this build;
# the Dockerfile must consume exactly it and the pinned base.
grep -Fq "FROM $BASE_IMAGE" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v13 Dockerfile does not build on the pinned base image" >&2
  exit 1
}
grep -Fq "upstream-core-port-v13-pr52477-pr53046-pr55455.tar.gz" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v13 Dockerfile does not consume the pinned overlay archive" >&2
  exit 1
}
grep -Fq "upstream-core-port.predecessor=v12-$UPSTREAM_PREDECESSOR" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v13 Dockerfile does not record its v12 predecessor" >&2
  exit 1
}
grep -Fq "upstream-core-port.source-port=$SOURCE_PORT" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v13 Dockerfile does not record the ported source commits" >&2
  exit 1
}

docker pull "$BASE_IMAGE" >/dev/null
actual_base_id="$(docker image inspect "$BASE_IMAGE" --format '{{.Id}}')"
[ "$actual_base_id" = "$BASE_ID" ] || {
  echo "error: pinned base image config is $actual_base_id, expected $BASE_ID" >&2
  exit 1
}

# The build is CPU-only: archive extraction, a manifest-driven install whose
# replacement/addition counts are pinned, a check that the three r2.1 fix sites
# plus the four v12 port sites plus the three v13 port sites are present, and a
# byte-compile of every python destination. It fails closed on any manifest,
# count, marker, or compile drift.
docker build --tag "$DERIVED_TAG" "$OVERLAY_DIR"

derived_id="$(docker image inspect "$DERIVED_TAG" --format '{{.Id}}')"
overlay_label="$(docker image inspect "$DERIVED_TAG" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.overlay-sha256"}}')"
[ "$overlay_label" = "$OVERLAY_SHA256" ] || {
  echo "error: built image records overlay $overlay_label, expected $OVERLAY_SHA256" >&2
  exit 1
}
release_label="$(docker image inspect "$DERIVED_TAG" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.release"}}')"
[ "$release_label" = v13 ] || {
  echo "error: built image records release ${release_label:-<missing>}, expected v13" >&2
  exit 1
}
source_port_label="$(docker image inspect "$DERIVED_TAG" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.source-port"}}')"
[ "$source_port_label" = "$SOURCE_PORT" ] || {
  echo "error: built image records source-port ${source_port_label:-<missing>}, expected $SOURCE_PORT" >&2
  exit 1
}

# Prove the served tree carries the r2 work, the r2.1 deadlock fix, the four
# v12 port sites AND the three v13 port sites, that the code each fix replaces
# is gone, and — with a focused CPU test — that the ported Mamba cleanup still
# crosses null gaps, is idempotent, does not rescan history, and defers to the
# base stop-at-first-null behavior outside align mode.
docker run --rm --entrypoint /opt/venv/bin/python "$DERIVED_TAG" - <<'PY'
import pathlib
import sys

root = pathlib.Path("/opt/infernal-invocation")
core = root / "vllm/vllm/v1/core"
sparse = (root / "vllm/vllm/v1/attention/backends/mla/b12x_mla_sparse.py").read_text()
kernel = (root / "b12x/b12x/attention/_shared/mla/kernel.py").read_text()
interface = (root / "vllm/vllm/v1/kv_cache_interface.py").read_text()
kv_manager = (core / "kv_cache_manager.py").read_text()
single_type = (core / "single_type_kv_cache_manager.py").read_text()
scheduler = (core / "sched/scheduler.py").read_text()
gpu_worker = (root / "vllm/vllm/v1/worker/gpu_worker.py").read_text()
mla = (root / "vllm/model_executor/layers/attention/mla_attention.py").read_text()
dcp = (root / "vllm/vllm/v1/attention/ops/dcp.py").read_text()
so_worker = (root / "vllm/vllm/v1/worker/gpu/structured_outputs.py").read_text()
so_producer = (root / "vllm/vllm/v1/structured_output/__init__.py").read_text()
so_utils = (root / "vllm/vllm/v1/structured_output/utils.py").read_text()
warmup = (root / "vllm/vllm/v1/worker/gpu/warmup.py").read_text()

checks = {
    # r2 content, unchanged from the v11 proof.
    "native FP8 KV gate": 'VLLM_B12X_FP8_KV' in sparse,
    "528B NoPE record": '_GLM_NOPE_FP8_KV_RECORD_BYTES = 528' in sparse,
    "FP8 gate reaches the cache interface": 'VLLM_B12X_FP8_KV' in interface,
    "b12x record-walk view stride": 'view.stride(' in kernel or 'stride(0)' in kernel,
    "new upstream dcp ops module": (root / "vllm/vllm/v1/attention/ops/dcp.py").is_file(),
    "new kv cache layout module": (root / "vllm/vllm/v1/kv_cache_layout.py").is_file(),
    "multimodal chat template": pathlib.Path("/opt/glm53/chat_template.multimodal.jinja").is_file(),
    # r2.1 fix 0004: align cap bills the real footprint, legacy billing is opt-in.
    "0004 align-cap billing mode switch": 'VLLM_MAMBA_ALIGN_CAP_LEGACY' in single_type,
    "0004 real-footprint billing": 'self._align_cap_legacy' in single_type,
    # r2.1 fix 0005: reserve aging escape.
    "0005 reserve aging knob": 'VLLM_MAMBA_STATE_PROTECT_AGE' in kv_manager,
    "0005 reserve-blocked streak": '_reserve_blocked' in kv_manager,
    # r2.1 fix 0006: deferred frees drain on every update.
    "0006 unconditional drain": '[DEFER-FREE-DRAIN]' in scheduler,
    "0006 gated drain removed": (
        'if self.defer_block_free and scheduler_output.total_num_scheduled_tokens > 0:'
        not in scheduler
    ),
    # r2.1 removes Fix B's decode-aware chunk cap; its absence is part of the shape.
    "Fix B chunk cap removed": 'chunk_cap' not in scheduler,
    # v12 PR #710: SM120 disjoint-batch BMM.
    "710 mla contiguous-operand helper": '_bmm_with_disjoint_batches' in mla,
    "710 helper routes both decode bmm sites": mla.count('_bmm_with_disjoint_batches(') == 3,
    "710 raw decode bmm gone": 'torch.bmm(mqa_q_nope, W_UK_T, out=mqa_ql_nope)' not in mla,
    "710 raw v_up bmm gone": 'torch.bmm(x, self.W_UV, out=out.transpose(0, 1))' not in mla,
    "710 dcp head-major reduce-scatter": (
        'cp_group.reduce_scatter(out.transpose(0, 1).contiguous(), dim=0)' in dcp
    ),
    "710 dcp original branch preserved": 'cp_group.reduce_scatter(out, dim=1)' in dcp,
    # v12 PR #718: Mamba null-gap cleanup.
    "718 retirement high-water mark": '_num_retired_blocks' in single_type,
    "718 null-gap walk skips nulls": (
        'if blocks[i].is_null:\n                continue' in single_type
    ),
    "718 base stop-at-first-null preserved": (
        'if blocks[i] == self._null_block:\n                break' in single_type
    ),
    "718 cursor drained on free": (
        'self._num_retired_blocks.pop(request_id, None)' in single_type
    ),
    # v12 PR #694: graph-memory double-count fix.
    "694 activation-only profile peak": (
        'self.peak_activation_memory = profile_result.transient_peak_headroom' in gpu_worker
    ),
    "694 old double-count line gone": (
        'profile_result.transient_peak_headroom + cudagraph_memory_estimate_applied'
        not in gpu_worker
    ),
    "694 estimate still billed at admission": (
        '- cudagraph_memory_estimate_applied' in gpu_worker
    ),
    # v13 PR #52477: GPU-count-driven grammar masks (fixed-width stride).
    "52477 port marker in worker": '[PR52477-PORT]' in so_worker,
    "52477 fixed-width invariant": (
        'assert grammar_bitmask.shape[0] == num_grammar_reqs * self.mask_stride' in so_worker
    ),
    "52477 GPU-driven kernel reads device counts": 'input_batch.cu_num_logits' in so_worker,
    "52477 one program per grammar request": (
        'grid = (num_grammar_reqs, triton.cdiv' in so_worker
    ),
    "52477 crash design gone": '\ndef _build_grammar_row_mapping' not in so_worker,
    "52477 producer ported to the stride": '[PR52477-PORT]' in so_producer,
    "52477 dormant consumer ported to the stride": '[PR52477-PORT]' in so_utils,
    "52477 warmup bitmask resized": '[PR52477-PORT]' in warmup,
    # v13 upstream #53046: FSM validate-before-accept.
    "53046 mid-window marker": 'post_reasoning_end_in_window' in so_producer,
    "53046 validate-before-accept": 'grammar.validate_tokens([token])' in so_producer,
    "53046 non-mid-window accept preserved": (
        'accepted = grammar.accept_tokens(req_id, [token])' in so_producer
    ),
    # v13 upstream #55455: warmup defers adaptive verification.
    "55455 warmup defers adaptive verification": (
        'model_runner.adaptive_verification = None' in warmup
    ),
    "55455 body moved to _warmup_kernels": (
        '_warmup_kernels(model_runner, worker_execute_model, worker_sample_tokens)' in warmup
    ),
    "55455 manager restored after warmup": (
        'model_runner.adaptive_verification = adaptive_verification' in warmup
    ),
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    sys.exit(1)

# Focused CPU regression test for the ported PR #718 cleanup, carried from the
# v12 proof: the null-gap walk must cross null gaps (retire the state below the
# gap), be idempotent, not rescan history, and defer to the base
# stop-at-first-null behavior outside align.
import torch

from vllm.v1.core.block_pool import BlockPool
from vllm.v1.core.single_type_kv_cache_manager import MambaManager
from vllm.v1.kv_cache_interface import MambaSpec

align_spec = MambaSpec(
    block_size=4,
    shapes=((1, 1),),
    dtypes=(torch.float32,),
    mamba_cache_mode="align",
)
pool = BlockPool(num_gpu_blocks=8, enable_caching=False, hash_block_size=4)
manager = MambaManager(
    align_spec,
    block_pool=pool,
    enable_caching=False,
    kv_cache_group_id=0,
    scheduler_block_size=4,
)
old, committed, in_flight = pool.get_new_blocks(3)
manager.req_to_blocks["r"] = [old, pool.null_block, committed, in_flight]

# The state at token 12 and the following in-flight state must survive; the
# retired state below the null gap must be freed exactly once.
for _ in range(2):
    manager.remove_skipped_blocks("r", processed_computed_tokens=12)
    assert manager.req_to_blocks["r"] == [
        pool.null_block,
        pool.null_block,
        committed,
        in_flight,
    ], "null-gap cleanup stranded or double-freed blocks"
    assert old.ref_cnt == 0, "retired state was not freed"
    assert committed.ref_cnt == in_flight.ref_cnt == 1
    assert pool.get_num_free_blocks() == 5, "free-block count drifted"

manager.free("r")
manager.req_to_blocks["r"] = pool.get_new_blocks(2)
manager.remove_skipped_blocks("r", processed_computed_tokens=5)
assert manager.req_to_blocks["r"][0].is_null
assert manager.req_to_blocks["r"][1].ref_cnt == 1
assert pool.get_num_free_blocks() == 6

# No rescan of history: repeat calls over an already-cleaned table read no
# blocks (the _num_retired_blocks high-water mark) and never advance past it.
class CountedBlocks(list):
    reads = 0

    def __getitem__(self, index):
        self.reads += 1
        return super().__getitem__(index)


manager2 = MambaManager(
    align_spec,
    block_pool=BlockPool(num_gpu_blocks=8, enable_caching=False, hash_block_size=4),
    enable_caching=False,
    kv_cache_group_id=0,
    scheduler_block_size=4,
)
manager2.remove_skipped_blocks("r2", 16000)
blocks = CountedBlocks([manager2.block_pool.null_block] * 1000)
stale, live = manager2.block_pool.get_new_blocks(2)
blocks[10], blocks[999] = stale, live
manager2.req_to_blocks["r2"] = blocks
manager2.remove_skipped_blocks("r2", 16000)
assert stale.ref_cnt == 0, "stale state beyond the null gap was stranded"
assert live.ref_cnt == 1, "in-flight state at the table tail was freed"
blocks.reads = 0
for _ in range(100):
    manager2.remove_skipped_blocks("r2", 16000)
    manager2.remove_skipped_blocks("r2", 15999)
assert blocks.reads == 0, "cleanup rescanned already-retired history"
manager2.free("r2")
assert manager2.block_pool.get_num_free_blocks() == 7

# Non-align defer: the base stop-at-first-null behavior is preserved exactly.
manager3 = MambaManager(
    MambaSpec(
        block_size=4,
        shapes=((1, 1),),
        dtypes=(torch.float32,),
        mamba_cache_mode="none",
    ),
    block_pool=BlockPool(num_gpu_blocks=8, enable_caching=False, hash_block_size=4),
    enable_caching=False,
    kv_cache_group_id=0,
    scheduler_block_size=4,
)
old3, committed3, in_flight3 = manager3.block_pool.get_new_blocks(3)
manager3.req_to_blocks["r3"] = [old3, manager3.block_pool.null_block, committed3, in_flight3]
manager3.remove_skipped_blocks("r3", processed_computed_tokens=12)
assert old3.ref_cnt == 1, "non-align defer altered the base stop-at-first-null behavior"
assert committed3.ref_cnt == in_flight3.ref_cnt == 1
manager3.free("r3")
assert manager3.block_pool.get_num_free_blocks() == 7

print("V13 IMAGE CONTENT PROOF: r2.1 overlay + four v12 ports + the grammar redesign are live in the served tree")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.v13-identity.XXXXXX")"
{
  printf 'base_index=%s\n' "$BASE_INDEX"
  printf 'base_image=%s\n' "$BASE_IMAGE"
  printf 'base_id=%s\n' "$BASE_ID"
  printf 'derived_tag=%s\n' "$DERIVED_TAG"
  printf 'derived_id=%s\n' "$derived_id"
  printf 'upstream_repo=%s\n' "$UPSTREAM_REPO"
  printf 'upstream_commit=%s\n' "$UPSTREAM_COMMIT"
  printf 'upstream_predecessor=%s\n' "$UPSTREAM_PREDECESSOR"
  printf 'source_port=%s\n' "$SOURCE_PORT"
  printf 'overlay_sha256=%s\n' "$OVERLAY_SHA256"
  printf 'model_rev=%s\n' "$MODEL_REV"
} >"$identity_tmp"
chmod 600 "$identity_tmp"
mv -f "$identity_tmp" "$IDENTITY_FILE"

printf 'GLM-5.3 v13 image built: %s\n' "$derived_id"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'Record this image id as IMAGE_CONFIG in run-glm53-flash-exl3-k4-vllm-sm120-v13.sh before serving;\n'
printf 'the serve script refuses to launch while the id is unrecorded.\n'
