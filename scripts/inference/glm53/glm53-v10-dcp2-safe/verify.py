#!/opt/venv/bin/python
"""GPU qualification probes for the immutable GLM-5.3 v10 DCP2 overlay."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import torch
import vllm._custom_ops as ops
from b12x.attention import sparse_mla
from vllm.model_executor.models.registry import ModelRegistry
from vllm.models.glm5next.nvidia.ops.fused_eh_norm import fused_eh_norm
from vllm.v1.attention.backends.mla.b12x_mla_sparse import B12xMLASparseBackend
from vllm.v1.attention.backends.mla.indexer import compute_kpool_tail_slot_mapping
from vllm.v1.attention.backends.registry import AttentionBackendEnum
from vllm.v1.kv_cache_interface import (
    FullAttentionSpec,
    MLAAttentionSpec,
    MambaSpec,
    get_kv_cache_dcp_shard_count,
)
from vllm.v1.worker.gpu.block_table import BlockTables
from vllm.v1.worker.mamba_utils import batch_memcpy

ROOT = Path("/opt/infernal-invocation/vllm")
B12X_ROOT = Path("/opt/infernal-invocation/b12x")
GLM_NEXT_BLOCK_SIZE = 64
GLM_NEXT_RECORD_BYTES = 528
GLM_NEXT_PHYSICAL_BYTES_PER_TOKEN = 656
GLM_NEXT_PAGE_STRIDE = GLM_NEXT_BLOCK_SIZE * GLM_NEXT_PHYSICAL_BYTES_PER_TOKEN
GLM_NEXT_STRIDE = (GLM_NEXT_PAGE_STRIDE, GLM_NEXT_RECORD_BYTES, 1)
EXPECTED_SOURCE = {
    "vllm/v1/worker/mamba_utils.py": "e0e8140d3b004509ef2345a5f4929f88d14b3fef7446c5bbfdb39c34fe500108",
    "vllm/v1/worker/block_table.py": "4ad1e13f0c0f271e1a2a24675454e200b7469c136def742b796b8530357a90ae",
    "vllm/v1/kv_cache_interface.py": "42353dcb13f9bc6d6416e5500eb638fa2e8c4b0382843536dd6181e470915a09",
    "vllm/model_executor/layers/attention/mla_attention.py": "87626b13538580e5552c613ae2f6d1a19628bcdf5836dd60df94906a1559d78a",
    "vllm/v1/worker/gpu/block_table.py": "edc3fef19c94d22850f1dbef27566ba41f720c0187743355e24436c475bbf232",
    "vllm/v1/core/kv_cache_utils.py": "bbd2f6549cc18af4148bd722cb25d9ccb7da8c571a233c6d181b28121710623e",
    "vllm/models/glm5next/nvidia/ops/fused_eh_norm.py": "433190de4bdb5db55f4464b511e4953fe7e22bab9d9b73cc884cc25ffc83c7af",
    "vllm/models/glm5next/nvidia/mtp.py": "eee15d090d7fbe40fd249ce2726056f2cc42a6ed7a228685f4d928296cc32c7a",
    "vllm/v1/attention/backends/mla/b12x_mla_sparse.py": "d9dc3eda5024866711aa352036d0edd87772943eabdc3ce4e3a8b0ad9bf96641",
    "vllm/v1/attention/backends/mla/indexer.py": "6a2fe647b54f7d8007550d12d7f42237b8b127bf24603dfc216f3989ff7715cd",
    "csrc/libtorch_stable/persistent_topk.cuh": "ad1fde7a145c57442d856be2d37d33912109bb007c574b5ad6d42cc1a1176e49",
    "csrc/libtorch_stable/topk_histogram_4096.cuh": "d6b447486d8186625e5b7ac196c3d04c5e6f016232d6511df68c3515ac71d078",
}
EXPECTED_B12X_SOURCE = {
    "b12x/attention/sparse_mla/__init__.py": "a10e95fbf8f9abbaaaf9dafcd3a9d4dfe13cdef1360c22888823ee937510f658",
    "b12x/attention/sparse_mla/api.py": "7fa27daa41a2c791444b77406bf2f3a231dfb96f29864551013407ec4a91613b",
    "b12x/attention/_shared/mla/traits.py": "5a0f2f5ba15c25569fa081c28f35d8d24662f9f0d206ae7447b914ac65617508",
    "b12x/attention/_shared/mla/kv_cache.py": "394ee7728987037b78e51dd46f8f397e5287cca72f6361b30cc580ca49f7acb7",
}


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


TOPK_WORKSPACE: torch.Tensor | None = None


def persistent_topk(logits: torch.Tensor, lengths: torch.Tensor, topk: int) -> torch.Tensor:
    global TOPK_WORKSPACE
    output = torch.empty((logits.shape[0], topk), dtype=torch.int32, device="cuda")
    if TOPK_WORKSPACE is None:
        TOPK_WORKSPACE = torch.empty(
            (1_024 * 1_024,), dtype=torch.uint8, device=logits.device
        )
    workspace = TOPK_WORKSPACE
    torch.ops._C.persistent_topk(
        logits, lengths, output, workspace, topk, logits.shape[1]
    )
    return output


def synchronize() -> None:
    torch.cuda.synchronize()


def median_ms(operation, repeats: int = 11) -> float:
    for _ in range(3):
        operation()
    synchronize()
    samples: list[float] = []
    for _ in range(repeats):
        start = time.perf_counter()
        operation()
        synchronize()
        samples.append((time.perf_counter() - start) * 1000)
    return sorted(samples)[len(samples) // 2]


def verify_source_and_capabilities() -> None:
    for root, expected_sources in (
        (ROOT, EXPECTED_SOURCE),
        (B12X_ROOT, EXPECTED_B12X_SOURCE),
    ):
        for relative, expected in expected_sources.items():
            actual = sha256(root / relative)
            assert actual == expected, (relative, actual, expected)
    extension = ROOT / "vllm/_C_stable_libtorch.abi3.so"
    assert sha256(extension) == "b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415"
    assert "Glm5NextForConditionalGeneration" in ModelRegistry.get_supported_archs()
    assert "TORCH_SDPA" in AttentionBackendEnum.__members__
    assert "FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__
    assert "B12X_MLA_SPARSE" in AttentionBackendEnum.__members__
    assert hasattr(sparse_mla, "ModelType")
    assert hasattr(sparse_mla, "concat_and_cache_glm_next_mla")
    assert B12xMLASparseBackend.get_kv_cache_shape(
        2, GLM_NEXT_BLOCK_SIZE, 1, 512, "fp8_ds_mla"
    ) == (2, GLM_NEXT_BLOCK_SIZE, GLM_NEXT_RECORD_BYTES)
    glm_next_spec = MLAAttentionSpec(
        block_size=GLM_NEXT_BLOCK_SIZE,
        num_kv_heads=1,
        head_size=512,
        dtype=torch.uint8,
        cache_dtype_str="fp8_ds_mla",
        model_version="glm_next_fp8",
        page_size_padded=GLM_NEXT_PAGE_STRIDE,
    )
    assert (
        glm_next_spec.real_page_size_bytes
        == GLM_NEXT_BLOCK_SIZE * GLM_NEXT_RECORD_BYTES
    )
    assert glm_next_spec.page_size_bytes == GLM_NEXT_PAGE_STRIDE
    provenance = json.loads(Path("/opt/glm53/PROVENANCE.json").read_text())
    assert provenance["release"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2"


def verify_b12x_glm_next_fp8() -> None:
    device = torch.device("cuda")
    model_type = int(sparse_mla.ModelType.GLM_NEXT)
    num_pages = 2
    storage = torch.full(
        (num_pages * GLM_NEXT_PAGE_STRIDE,),
        0xA5,
        dtype=torch.uint8,
        device=device,
    )
    kv_cache = torch.as_strided(
        storage,
        (num_pages, GLM_NEXT_BLOCK_SIZE, GLM_NEXT_RECORD_BYTES),
        GLM_NEXT_STRIDE,
    )
    kv_cache.zero_()
    assert tuple(kv_cache.stride()) == GLM_NEXT_STRIDE
    assert not kv_cache.is_contiguous()

    slots = torch.tensor([0, 63, 64, 127, -1, 128], dtype=torch.int64, device=device)
    base = torch.linspace(-1.0, 1.0, 512, dtype=torch.bfloat16, device=device)
    kv_c = torch.stack([base + index / 16 for index in range(len(slots))])
    sparse_mla.compile_glm_next_mla_cache_writer(kv_c, kv_cache, slots)
    sparse_mla.concat_and_cache_glm_next_mla(kv_c, kv_cache, slots)
    synchronize()
    for slot in (0, 63, 64, 127):
        assert torch.count_nonzero(
            kv_cache[
                slot // GLM_NEXT_BLOCK_SIZE, slot % GLM_NEXT_BLOCK_SIZE
            ]
        ).item() > 0
    storage_pages = storage.view(num_pages, GLM_NEXT_PAGE_STRIDE)
    semantic_page_bytes = GLM_NEXT_BLOCK_SIZE * GLM_NEXT_RECORD_BYTES
    assert torch.all(storage_pages[:, semantic_page_bytes:] == 0xA5)

    capture_source = torch.ones((1, 512), dtype=torch.bfloat16, device=device)
    capture_slot = torch.tensor([1], dtype=torch.int64, device=device)
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        sparse_mla.concat_and_cache_glm_next_mla(
            capture_source, kv_cache, capture_slot
        )
    graph.replay()
    synchronize()
    assert torch.count_nonzero(kv_cache[0, 1]).item() > 0
    assert torch.all(storage_pages[:, semantic_page_bytes:] == 0xA5)

    gathered = torch.empty(
        (num_pages * GLM_NEXT_BLOCK_SIZE, GLM_NEXT_RECORD_BYTES),
        dtype=torch.uint8,
        device=device,
    )
    ops.cp_gather_cache(
        src_cache=kv_cache,
        dst=gathered,
        block_table=torch.tensor([[0, 1]], dtype=torch.int32, device=device),
        cu_seq_lens=torch.tensor([0, 128], dtype=torch.int32, device=device),
        batch_size=1,
    )
    synchronize()
    torch.testing.assert_close(gathered[0], kv_cache[0, 0], rtol=0, atol=0)
    torch.testing.assert_close(gathered[64], kv_cache[1, 0], rtol=0, atol=0)

    width = 2_051
    query = torch.ones((1, 8, 512), dtype=torch.bfloat16, device=device)
    selected_indices = torch.full((1, width), -1, dtype=torch.int32, device=device)
    selected_indices[0, 0] = 64
    cache_seqlens = torch.tensor([65], dtype=torch.int32, device=device)
    active_counts = torch.tensor([1], dtype=torch.int32, device=device)
    for mode, runner in (("decode", sparse_mla.run_decode), ("extend", sparse_mla.run_extend)):
        plan = sparse_mla.plan(
            sparse_mla.Caps(
                device=device,
                num_q_heads=8,
                max_q_rows=1,
                max_width=width,
                dtype=torch.bfloat16,
                kv_dtype=torch.uint8,
                head_dim=512,
                v_head_dim=512,
                model_type=model_type,
                mode=mode,
                max_batch=1,
                max_chunks_per_row=33,
                page_size=GLM_NEXT_BLOCK_SIZE,
            )
        )
        scratch = torch.empty((plan.layout.nbytes,), dtype=torch.uint8, device=device)
        binding = plan.bind(
            scratch=scratch,
            q=query,
            selected_indices=selected_indices,
            cache_seqlens_int32=cache_seqlens,
            nsa_cache_seqlens_int32=active_counts,
        )
        output = runner(
            binding=binding,
            kv_cache=kv_cache,
            sm_scale=256**-0.5,
            v_head_dim=512,
        )
        synchronize()
        assert output.shape == (1, 8, 512)
        assert torch.isfinite(output).all()


def verify_exact_topk() -> dict[str, float]:
    generator = torch.Generator(device="cpu").manual_seed(53)
    rows, width, topk = 33, 32_769, 2_048
    crowded = (1.0 + torch.rand(rows, width, generator=generator) * 0.01).cuda()
    lengths = torch.full((rows,), width, dtype=torch.int32, device="cuda")
    expected_values = torch.topk(crowded, topk, dim=1).values.sort(dim=1).values
    for _ in range(10):
        indices = persistent_topk(crowded, lengths, topk)
        assert torch.all((indices >= 0) & (indices < width))
        selected = torch.gather(crowded, 1, indices.long()).sort(dim=1).values
        torch.testing.assert_close(selected, expected_values, rtol=0, atol=0)

    equal_width = 8_192
    equal = torch.ones((8, equal_width), dtype=torch.float32, device="cuda")
    equal_lengths = torch.full((8,), equal_width, dtype=torch.int32, device="cuda")
    expected_indices = torch.arange(topk, dtype=torch.int32, device="cuda").expand(8, -1)
    for _ in range(50):
        torch.testing.assert_close(
            persistent_topk(equal, equal_lengths, topk), expected_indices, rtol=0, atol=0
        )

    columns, visible, regression_topk = 806_736, 4_096, 512
    regression = torch.full((1, columns), float("inf"), device="cuda")
    regression[0, :visible] = torch.arange(
        columns, columns - visible, -1, dtype=torch.float32, device="cuda"
    )
    regression_lengths = torch.tensor([visible], dtype=torch.int32, device="cuda")
    regression_expected = torch.arange(regression_topk, dtype=torch.int32, device="cuda")
    for _ in range(20):
        torch.testing.assert_close(
            persistent_topk(regression, regression_lengths, regression_topk)[0],
            regression_expected,
            rtol=0,
            atol=0,
        )

    persistent_ms = median_ms(lambda: persistent_topk(crowded, lengths, topk))
    torch_ms = median_ms(lambda: torch.topk(crowded, topk, dim=1, sorted=True))
    assert persistent_ms < torch_ms, (persistent_ms, torch_ms)
    return {"persistent_topk_ms": persistent_ms, "torch_topk_ms": torch_ms}


def verify_overlap_copy() -> None:
    batch, row_bytes, shift = 128, 32 * 1_024, 16
    pattern = (torch.arange(row_bytes, dtype=torch.int32, device="cuda") % 251).to(
        torch.uint8
    )
    state = pattern.expand(batch, -1).clone()
    snapshot = state.clone()
    expected = snapshot.clone()
    expected[:, : row_bytes - shift].copy_(snapshot[:, shift:])
    row_offsets = torch.arange(batch, dtype=torch.int64, device="cuda") * state.stride(0)
    dst_ptrs = (row_offsets + state.data_ptr()).to(torch.uint64)
    src_ptrs = (row_offsets + state.data_ptr() + shift).to(torch.uint64)
    sizes = torch.full((batch,), row_bytes - shift, dtype=torch.int32, device="cuda")
    for _ in range(20):
        state.copy_(snapshot)
        batch_memcpy(src_ptrs, dst_ptrs, sizes)
        synchronize()
        torch.testing.assert_close(state, expected, rtol=0, atol=0)


def verify_mtp_position_zero_embedding() -> None:
    width = 128
    embedding = torch.linspace(
        0.25, 1.25, width, dtype=torch.bfloat16, device="cuda"
    ).expand(2, -1).clone()
    previous_hidden = torch.linspace(
        -1.0, 1.0, width, dtype=torch.bfloat16, device="cuda"
    ).expand(2, -1).clone()
    enorm_weight = torch.ones(width, dtype=torch.bfloat16, device="cuda")
    hnorm_weight = torch.ones(width, dtype=torch.bfloat16, device="cuda")
    output = fused_eh_norm(
        embedding,
        previous_hidden,
        enorm_weight,
        hnorm_weight,
        1e-6,
    )
    synchronize()
    assert torch.count_nonzero(output[0, :width]).item() == width
    torch.testing.assert_close(output[0], output[1], rtol=0, atol=0)


def verify_dcp_geometry_and_overflow() -> None:
    mamba = MambaSpec(
        block_size=16,
        shapes=((1,),),
        dtypes=(torch.float16,),
        mamba_cache_mode="align",
    )
    attention = FullAttentionSpec(
        block_size=16,
        num_kv_heads=1,
        head_size=16,
        dtype=torch.float16,
    )
    assert get_kv_cache_dcp_shard_count(mamba, 2) == 1
    assert get_kv_cache_dcp_shard_count(mamba, 4) == 1
    assert get_kv_cache_dcp_shard_count(attention, 2) == 2

    tables = BlockTables(
        block_sizes=[4],
        max_num_reqs=1,
        max_num_batched_tokens=1,
        max_num_blocks_per_group=[1],
        device=torch.device("cuda"),
        kernel_block_sizes=[4],
    )
    try:
        tables.append_block_ids(0, ([7, 8],), overwrite=True)
    except RuntimeError as error:
        assert "exceeds row capacity (2 > 1)" in str(error)
    else:
        raise AssertionError("oversized block-table writes must fail closed")


def verify_slot_bounds_and_kpool_address() -> None:
    tables = BlockTables(
        block_sizes=[4],
        max_num_reqs=1,
        max_num_batched_tokens=3,
        max_num_blocks_per_group=[1],
        device=torch.device("cuda"),
        kernel_block_sizes=[4],
    )
    tables.append_block_ids(0, ([7],), overwrite=True)
    tables.apply_staged_writes()
    mappings = tables.compute_slot_mappings(
        idx_mapping=torch.tensor([0], dtype=torch.int32, device="cuda"),
        query_start_loc=torch.tensor([0, 3], dtype=torch.int32, device="cuda"),
        positions=torch.tensor([0, 4, 8], dtype=torch.int64, device="cuda"),
        num_tokens_padded=3,
    )
    synchronize()
    torch.testing.assert_close(
        mappings[0], torch.tensor([28, -1, -1], dtype=torch.int64, device="cuda")
    )

    slot_buffer = torch.full((8,), -1, dtype=torch.int64, device="cuda")
    original_address = slot_buffer.data_ptr()
    block_table = torch.tensor([[5], [9]], dtype=torch.int32, device="cuda")
    output = compute_kpool_tail_slot_mapping(
        slot_buffer,
        block_table,
        torch.tensor([0, 3, 6], dtype=torch.int32, device="cuda"),
        torch.tensor([8, 9, 10, 11, 12, 13], dtype=torch.int64, device="cuda"),
        6,
        2,
        4,
    )
    assert output.data_ptr() == original_address
    torch.testing.assert_close(
        output,
        torch.tensor([20, 21, 22, 39, 36, 37, -1, -1], dtype=torch.int64, device="cuda"),
    )


def main() -> None:
    assert torch.cuda.is_available()
    assert torch.cuda.get_device_capability() == (12, 0)
    verify_source_and_capabilities()
    verify_b12x_glm_next_fp8()
    timings = verify_exact_topk()
    verify_overlap_copy()
    verify_mtp_position_zero_embedding()
    verify_dcp_geometry_and_overflow()
    verify_slot_bounds_and_kpool_address()
    print(json.dumps({"status": "PASS", **timings}, sort_keys=True))


if __name__ == "__main__":
    main()
