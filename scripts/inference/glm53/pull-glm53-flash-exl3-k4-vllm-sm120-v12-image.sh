#!/usr/bin/env bash
# Build and prove the GLM-5.3 v12 image: our pinned v84 base plus the legend
# upstream-core-port r2.1 overlay plus the four changes ported from the Spark
# TP2 source-locked image (2026-09-13 R2 update).
#
# v12 = v11.1 (legend r2.1, commit 832e6000) plus exactly:
#   PR vllm/vllm#710 SM120/121 disjoint-batch BMM (mla_attention contiguous
#     operands + dcp head-major reduce-scatter; inert off SM120),
#   PR vllm/vllm#718 Mamba recurrent-state cleanup across null gaps (backward
#     walk skips nulls + retirement high-water mark; non-align defers to base),
#   PR vllm/vllm#694 graph-memory double-count fix (activation-only profile
#     peak; identical behavior with VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0),
#   CUBLAS_WORKSPACE_CONFIG=:4096:1 (launcher setting, set by the run script).
# The upstream patches are made against 7f4aecc6 and do not apply to the legend
# r2.1 overlay files, so the port is by hand; everything else — base, manifest
# policy, install policy — is v11.1's with the gpu_worker.py file and one
# manifest line added.
set -euo pipefail

BASE_INDEX="sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692"
BASE_IMAGE="verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140"
BASE_ID="sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578"
DERIVED_TAG="peterstorm/vllm:glm53-v12-upstream-core-port"
UPSTREAM_REPO="https://github.com/legend/glm-5.3-flash-exl3-4bpw"
UPSTREAM_COMMIT="832e6000120148f82c64acaecc56b6f96c27e6e2"
UPSTREAM_PREDECESSOR="832e6000120148f82c64acaecc56b6f96c27e6e2"
SOURCE_PORT="pr710-sm120-disjoint-bmm+pr718-mamba-null-gap+pr694-graph-memory-once+cublas-4mib"
OVERLAY_SHA256="f36de6931717fa114476a518513fa2a1f2f307c50f9a64cdee1d6666b42cf553"
MODEL_REV="5ab363a8dcf6405955fd5f99671e01a1c9fb124b"
IDENTITY_FILE="${IDENTITY_FILE:-$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v12-image.identity}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OVERLAY_DIR="$SCRIPT_DIR/glm53-v12-upstream-core-port"
OVERLAY_ARCHIVE="$OVERLAY_DIR/upstream-core-port-v12-pr710-pr718-pr694.tar.gz"

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
  echo "error: the v12 Dockerfile does not build on the pinned base image" >&2
  exit 1
}
grep -Fq "upstream-core-port-v12-pr710-pr718-pr694.tar.gz" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v12 Dockerfile does not consume the pinned overlay archive" >&2
  exit 1
}
grep -Fq "upstream-core-port.predecessor=r2.1-$UPSTREAM_PREDECESSOR" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v12 Dockerfile does not record its r2.1 predecessor" >&2
  exit 1
}
grep -Fq "upstream-core-port.source-port=$SOURCE_PORT" "$OVERLAY_DIR/Dockerfile" || {
  echo "error: the v12 Dockerfile does not record the ported source commits" >&2
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
# plus the four v12 port sites are present, and a byte-compile of every python
# destination. It fails closed on any manifest, count, marker, or compile drift.
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
[ "$release_label" = v12 ] || {
  echo "error: built image records release ${release_label:-<missing>}, expected v12" >&2
  exit 1
}
source_port_label="$(docker image inspect "$DERIVED_TAG" \
  --format '{{index .Config.Labels "ai.peterstorm.inference.upstream-core-port.source-port"}}')"
[ "$source_port_label" = "$SOURCE_PORT" ] || {
  echo "error: built image records source-port ${source_port_label:-<missing>}, expected $SOURCE_PORT" >&2
  exit 1
}

# Prove the served tree carries the r2 work, the r2.1 deadlock fix AND the four
# v12 port sites, that the code each fix replaces is gone, and — with a focused
# CPU test — that the ported Mamba cleanup crosses null gaps, is idempotent,
# does not rescan history, and defers to the base stop-at-first-null behavior
# outside align mode.
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
mla = (root / "vllm/vllm/model_executor/layers/attention/mla_attention.py").read_text()
dcp = (root / "vllm/vllm/v1/attention/ops/dcp.py").read_text()

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
}
for name, ok in checks.items():
    print(f"{'PASS' if ok else 'FAIL'}: {name}")
if not all(checks.values()):
    sys.exit(1)

# Focused CPU test for the ported PR #718 cleanup: the null-gap walk must cross
# null gaps (retire the state below the gap), be idempotent, not rescan
# history, and defer to the base stop-at-first-null behavior outside align.
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

print("V12 IMAGE CONTENT PROOF: r2.1 overlay + the four ported fixes are live in the served tree")
PY

install -d -m 700 "$(dirname "$IDENTITY_FILE")"
identity_tmp="$(mktemp "$(dirname "$IDENTITY_FILE")/.v12-identity.XXXXXX")"
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

printf 'GLM-5.3 v12 image built: %s\n' "$derived_id"
printf 'identity receipt: %s\n' "$IDENTITY_FILE"
printf 'Record this image id as IMAGE_CONFIG in run-glm53-flash-exl3-k4-vllm-sm120-v12.sh before serving;\n'
printf 'the serve script refuses to launch while the id is unrecorded.\n'
