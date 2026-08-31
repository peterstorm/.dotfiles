#!/opt/venv/bin/python
"""GPU qualification probes for the immutable GLM-5.3 v9 overlay."""

from __future__ import annotations

import hashlib
import json
import time
from pathlib import Path

import torch
import vllm._custom_ops  # noqa: F401 - registers torch.ops._C
from vllm.model_executor.models.registry import ModelRegistry
from vllm.v1.attention.backends.mla.indexer import compute_kpool_tail_slot_mapping
from vllm.v1.attention.backends.registry import AttentionBackendEnum
from vllm.v1.worker.gpu.block_table import BlockTables
from vllm.v1.worker.mamba_utils import batch_memcpy

ROOT = Path("/opt/infernal-invocation/vllm")
EXPECTED_SOURCE = {
    "vllm/v1/worker/mamba_utils.py": "e0e8140d3b004509ef2345a5f4929f88d14b3fef7446c5bbfdb39c34fe500108",
    "vllm/v1/worker/block_table.py": "4ad1e13f0c0f271e1a2a24675454e200b7469c136def742b796b8530357a90ae",
    "vllm/v1/worker/gpu/block_table.py": "32cfe59bffd1944c3145ff002e47f77c4d9aa859ff0a4a47f780be987ece8c82",
    "vllm/v1/attention/backends/mla/indexer.py": "6a2fe647b54f7d8007550d12d7f42237b8b127bf24603dfc216f3989ff7715cd",
    "csrc/libtorch_stable/persistent_topk.cuh": "ad1fde7a145c57442d856be2d37d33912109bb007c574b5ad6d42cc1a1176e49",
    "csrc/libtorch_stable/topk_histogram_4096.cuh": "d6b447486d8186625e5b7ac196c3d04c5e6f016232d6511df68c3515ac71d078",
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
    for relative, expected in EXPECTED_SOURCE.items():
        actual = sha256(ROOT / relative)
        assert actual == expected, (relative, actual, expected)
    extension = ROOT / "vllm/_C_stable_libtorch.abi3.so"
    assert sha256(extension) == "b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415"
    assert "Glm5NextForConditionalGeneration" in ModelRegistry.get_supported_archs()
    assert "TORCH_SDPA" in AttentionBackendEnum.__members__
    assert "FLASHINFER_MLA_SPARSE_SM120" in AttentionBackendEnum.__members__
    provenance = json.loads(Path("/opt/glm53/PROVENANCE.json").read_text())
    assert provenance["release"] == "r19-sm120-tp2-ep2-dcp2-v84-dflash2"


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
    timings = verify_exact_topk()
    verify_overlap_copy()
    verify_slot_bounds_and_kpool_address()
    print(json.dumps({"status": "PASS", **timings}, sort_keys=True))


if __name__ == "__main__":
    main()
