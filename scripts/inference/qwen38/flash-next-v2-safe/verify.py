#!/usr/bin/env python3
"""GPU and source qualification for the Qwen3.8 Flash-Next v2 image."""

from __future__ import annotations

import hashlib
import inspect
import json
import os
from pathlib import Path
from types import SimpleNamespace

import torch
import vllm
import vllm._custom_ops  # noqa: F401 - registers torch.ops._C
from vllm import envs
from vllm.model_executor.layers.mamba.ops.causal_conv1d import causal_conv1d_update
from vllm.model_executor.layers.mamba.ops.mamba_ssm import selective_state_update
from vllm.model_executor.models.registry import ModelRegistry
from vllm.models.qwen4_exp.nvidia import ple_layer
from vllm.models.qwen4_exp.nvidia.ops import qsa
from vllm.third_party.flash_linear_attention.ops import (
    fused_recurrent_gated_delta_rule,
    fused_sigmoid_gating_delta_rule_update,
)
from vllm.v1.attention.backends.gdn_attn import _build_mixed_token_indices_cpu
from vllm.v1.attention.backends.utils import NULL_BLOCK_ID

SOURCE_COMMIT = "e126687a9a828d513c01a07cd69f025f27d63280"
OVERLAY_COMMIT = "c0ac28980016af357df50359d301648352eebbf2"
EXPECTED_MODULES = {
    "qsa": (
        qsa,
        "5baec281455281510c0929e939f978e72ba39d77eaf4f97417c218052debeabf",
    ),
    "ple_layer": (
        ple_layer,
        "79ccc700f665d7b0a86f8c4b6de5837e5183ec699aa318da014755eacd47acc3",
    ),
}
TOPK = 512
COLUMNS = 65_536
TOPK_WORKSPACE_BYTES = 1_024 * 1_024


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def tensor_hash(tensor: torch.Tensor) -> str:
    return sha256_bytes(tensor.detach().cpu().contiguous().numpy().tobytes())


def run_persistent_topk(
    logits: torch.Tensor,
    lengths: torch.Tensor,
    output: torch.Tensor | None = None,
    workspace: torch.Tensor | None = None,
) -> torch.Tensor:
    if output is None:
        output = torch.empty(
            (logits.shape[0], TOPK), dtype=torch.int32, device=logits.device
        )
    if workspace is None:
        workspace = torch.empty(
            TOPK_WORKSPACE_BYTES, dtype=torch.uint8, device=logits.device
        )
    torch.ops._C.persistent_topk(
        logits,
        lengths,
        output,
        workspace,
        TOPK,
        logits.shape[1],
    )
    return output


def verify_source_and_capabilities() -> dict[str, str]:
    assert os.environ["VLLM_BUILD_COMMIT"] == OVERLAY_COMMIT
    assert envs.VLLM_PLE_CPU_OFFLOAD is True
    assert "Qwen4ExpForConditionalGeneration" in ModelRegistry.get_supported_archs()
    assert hasattr(ple_layer, "Qwen4ExpPinnedHostEmbedding")
    assert hasattr(ple_layer.Qwen4ExpNGramEmbedding, "start_prefetch")
    assert hasattr(qsa, "qsa_select_paged_tokens")

    module_hashes: dict[str, str] = {}
    for name, (module, expected) in EXPECTED_MODULES.items():
        path = Path(inspect.getfile(module))
        actual = sha256_file(path)
        assert actual == expected, (name, path, actual, expected)
        module_hashes[name] = actual

    package_root = Path(vllm.__file__).parent
    extensions = sorted(package_root.glob("_C*.so"))
    assert extensions, package_root
    extension_hash = sha256_file(extensions[0])
    assert extension_hash == (
        "c7d4513f12740b58f01b6903128227d02bda7f6c1d1491a50f4e38955824ea95"
    )
    module_hashes["extension"] = extension_hash
    return module_hashes


def verify_mixed_partition() -> None:
    cases = (
        ([False, True], [1, 3], [0], [1, 2, 3]),
        ([True, False, True], [2, 0, 1], [], [0, 1, 2]),
        ([False, True, False], [2, 1, 2], [0, 1, 3, 4], [2]),
    )
    for masks, lengths, expected_non_spec, expected_spec in cases:
        non_spec, spec = _build_mixed_token_indices_cpu(
            torch.tensor(masks, dtype=torch.bool),
            torch.tensor(lengths, dtype=torch.int32),
            sum(lengths),
            len(expected_non_spec),
        )
        assert non_spec.tolist() == expected_non_spec
        assert spec.tolist() == expected_spec
        assert sorted(non_spec.tolist() + spec.tolist()) == list(range(sum(lengths)))

    invalid = (
        ([False], [-1], -1, 0),
        ([False, True], [1], 1, 1),
        ([False], [1], 2, 1),
        ([False, True], [1, 1], 2, 2),
    )
    for masks, lengths, actual_tokens, non_spec_tokens in invalid:
        try:
            _build_mixed_token_indices_cpu(
                torch.tensor(masks, dtype=torch.bool),
                torch.tensor(lengths, dtype=torch.int32),
                actual_tokens,
                non_spec_tokens,
            )
        except ValueError:
            pass
        else:
            raise AssertionError((masks, lengths, actual_tokens, non_spec_tokens))


def verify_exact_topk() -> dict[str, str]:
    generator = torch.Generator(device="cpu").manual_seed(3_805)
    hashes: dict[str, str] = {}
    for rows in (1, 32, 64, 192, 512):
        logits = torch.rand(rows, COLUMNS, generator=generator, dtype=torch.float32).cuda()
        lengths = torch.full((rows,), COLUMNS, dtype=torch.int32, device="cuda")
        expected_values = torch.topk(logits, TOPK, dim=1).values.sort(dim=1).values
        observed_hashes = set()
        for _ in range(5):
            indices = run_persistent_topk(logits, lengths)
            assert torch.all((indices >= 0) & (indices < COLUMNS))
            values = torch.gather(logits, 1, indices.long()).sort(dim=1).values
            torch.testing.assert_close(values, expected_values, rtol=0, atol=0)
            # The persistent collector does not promise rank order for
            # distinct scores. Repeatability is the selected set; QSA applies
            # its own ascending canonical order before order-sensitive use.
            observed_hashes.add(tensor_hash(indices.sort(dim=1).values))
        assert len(observed_hashes) == 1
        hashes[f"rows_{rows}"] = observed_hashes.pop()

    tied = torch.ones((32, COLUMNS), dtype=torch.float32, device="cuda")
    tied_lengths = torch.full((32,), COLUMNS, dtype=torch.int32, device="cuda")
    expected_ties = torch.arange(TOPK, dtype=torch.int32, device="cuda").expand(32, -1)
    for _ in range(20):
        torch.testing.assert_close(
            run_persistent_topk(tied, tied_lengths).sort(dim=1).values,
            expected_ties,
            rtol=0,
            atol=0,
        )

    overflow = torch.full((1, COLUMNS), float("inf"), device="cuda")
    visible = 4_096
    overflow[0, :visible] = torch.arange(
        COLUMNS, COLUMNS - visible, -1, dtype=torch.float32, device="cuda"
    )
    overflow_lengths = torch.tensor([visible], dtype=torch.int32, device="cuda")
    expected_overflow = torch.arange(TOPK, dtype=torch.int32, device="cuda")
    for _ in range(20):
        torch.testing.assert_close(
            run_persistent_topk(overflow, overflow_lengths)[0].sort().values,
            expected_overflow,
            rtol=0,
            atol=0,
        )

    static_logits = torch.rand(32, COLUMNS, device="cuda")
    static_lengths = torch.full((32,), COLUMNS, dtype=torch.int32, device="cuda")
    static_output = torch.empty((32, TOPK), dtype=torch.int32, device="cuda")
    static_workspace = torch.empty(
        TOPK_WORKSPACE_BYTES, dtype=torch.uint8, device="cuda"
    )
    run_persistent_topk(
        static_logits, static_lengths, static_output, static_workspace
    )
    torch.cuda.synchronize()
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        run_persistent_topk(
            static_logits, static_lengths, static_output, static_workspace
        )
    graph_hashes = set()
    for _ in range(20):
        graph.replay()
        torch.cuda.synchronize()
        graph_hashes.add(tensor_hash(static_output.sort(dim=1).values))
    assert len(graph_hashes) == 1
    hashes["cuda_graph"] = graph_hashes.pop()
    return hashes


def make_qsa_inputs(rows: int) -> tuple[torch.Tensor, ...]:
    head_dim = 64
    page_size = 16
    pages = COLUMNS // page_size
    q = torch.randn(rows, 4, head_dim, device="cuda", dtype=torch.bfloat16)
    cache = torch.randn(
        pages, page_size, 1, head_dim, device="cuda", dtype=torch.bfloat16
    )
    page_table = torch.arange(pages, dtype=torch.int32, device="cuda").unsqueeze(0)
    token_to_req = torch.zeros(rows, dtype=torch.int32, device="cuda")
    sequence_lengths = torch.tensor([COLUMNS * 4], dtype=torch.int32, device="cuda")
    query_positions = torch.full(
        (rows,), COLUMNS * 4 - 1, dtype=torch.int32, device="cuda"
    )
    return (
        q,
        cache,
        page_table,
        token_to_req,
        query_positions,
        sequence_lengths,
    )


def qsa_reference_blocks(inputs: tuple[torch.Tensor, ...]) -> torch.Tensor:
    q_tensor, cache, page_table, token_to_req, query_positions, sequence_lengths = (
        inputs
    )
    logits, visible = qsa.qsa_mqa_paged(
        q_tensor,
        cache,
        page_table,
        token_to_req,
        query_positions,
        sequence_lengths,
        compress_ratio=4,
    )
    assert torch.all(visible == COLUMNS)
    return torch.topk(logits, TOPK, dim=1).indices.sort(dim=1).values.to(torch.int32)


def selected_qsa_blocks(selected_tokens: torch.Tensor) -> torch.Tensor:
    groups = selected_tokens[:, : TOPK * 4].reshape(selected_tokens.shape[0], TOPK, 4)
    offsets = torch.arange(4, dtype=torch.int32, device="cuda")
    assert torch.all(groups >= 0)
    assert torch.all(groups % 4 == offsets)
    blocks = groups[:, :, 0] // 4
    assert torch.all(blocks[:, 1:] >= blocks[:, :-1])
    return blocks


def run_qsa(inputs: tuple[torch.Tensor, ...], out: torch.Tensor | None = None) -> torch.Tensor:
    return qsa.qsa_select_paged_tokens(
        *inputs,
        token_topk=TOPK * 4,
        compress_ratio=4,
        out=out,
    )


def verify_qsa() -> dict[str, str]:
    torch.manual_seed(3_808)
    hashes: dict[str, str] = {}
    for rows in (1, 32, 64, 192, 512):
        inputs = make_qsa_inputs(rows)
        expected_blocks = qsa_reference_blocks(inputs)
        actual = run_qsa(inputs)
        torch.testing.assert_close(
            selected_qsa_blocks(actual), expected_blocks, rtol=0, atol=0
        )
        hashes[f"rows_{rows}"] = tensor_hash(actual)
        del inputs, expected_blocks, actual

    tied_inputs = list(make_qsa_inputs(32))
    tied_inputs[0].zero_()
    tied = run_qsa(tuple(tied_inputs))
    expected_tied_blocks = torch.arange(
        TOPK, dtype=torch.int32, device="cuda"
    ).expand(32, -1)
    torch.testing.assert_close(
        selected_qsa_blocks(tied), expected_tied_blocks, rtol=0, atol=0
    )
    tie_hashes = {tensor_hash(run_qsa(tuple(tied_inputs))) for _ in range(10)}
    assert len(tie_hashes) == 1
    hashes["ties"] = tie_hashes.pop()

    graph_inputs = make_qsa_inputs(32)
    graph_output = torch.empty(
        (32, TOPK * 4 + 3), dtype=torch.int32, device="cuda"
    )
    run_qsa(graph_inputs, graph_output)
    torch.cuda.synchronize()
    graph = torch.cuda.CUDAGraph()
    with torch.cuda.graph(graph):
        run_qsa(graph_inputs, graph_output)
    graph_hashes = set()
    for _ in range(10):
        graph.replay()
        torch.cuda.synchronize()
        graph_hashes.add(tensor_hash(graph_output))
    assert len(graph_hashes) == 1
    hashes["cuda_graph"] = graph_hashes.pop()
    return hashes


def verify_state_bounds() -> None:
    batch, dim, seqlen, width = 1, 64, 3, 4
    x = torch.randn(batch, dim, seqlen, device="cuda")
    weight = torch.randn(dim, width, device="cuda")
    for accepted_count in (0, seqlen + 1):
        state = torch.randn(3, dim, width - 1 + seqlen - 1, device="cuda")
        before = state.clone()
        result = causal_conv1d_update(
            x,
            state,
            weight,
            conv_state_indices=torch.tensor([1], dtype=torch.int32, device="cuda"),
            num_accepted_tokens=torch.tensor(
                [accepted_count], dtype=torch.int32, device="cuda"
            ),
            out=torch.full_like(x, torch.nan),
        )
        torch.testing.assert_close(result, torch.zeros_like(result))
        torch.testing.assert_close(state, before)

    dstate = 16
    state = torch.randn(12, dim, dstate, device="cuda")
    before = state.clone()
    indices_storage = torch.full(
        (3, seqlen), NULL_BLOCK_ID, dtype=torch.int32, device="cuda"
    )
    indices_storage[1, 0] = 1
    indices_storage[2, 0] = 2
    output = torch.full((seqlen, dim), torch.nan, device="cuda")
    selective_state_update(
        state,
        torch.randn(seqlen, dim, device="cuda"),
        torch.randn(seqlen, dim, device="cuda"),
        -torch.rand(dim, dstate, device="cuda") - 1,
        torch.randn(seqlen, dstate, device="cuda"),
        torch.randn(seqlen, dstate, device="cuda"),
        D=torch.randn(dim, device="cuda"),
        dt_bias=torch.rand(dim, device="cuda") - 4,
        dt_softplus=True,
        state_batch_indices=indices_storage[1:2],
        dst_state_batch_indices=torch.tensor(
            [[3, 4, 5]], dtype=torch.int32, device="cuda"
        ),
        out=output,
        num_accepted_tokens=torch.tensor(
            [seqlen + 1], dtype=torch.int32, device="cuda"
        ),
        cu_seqlens=torch.tensor([0, seqlen], dtype=torch.int32, device="cuda"),
    )
    torch.testing.assert_close(output, torch.zeros_like(output))
    torch.testing.assert_close(state, before)

    tokens, k_heads, v_heads, head_dim = 4, 2, 4, 16
    query = torch.rand(1, tokens, k_heads, head_dim, device="cuda")
    key = torch.rand_like(query)
    value = torch.rand(1, tokens, v_heads, head_dim, device="cuda")
    state_indices = torch.arange(
        1, tokens + 1, dtype=torch.int32, device="cuda"
    ).view(1, tokens)
    cu_seqlens = torch.tensor([0, tokens], dtype=torch.int32, device="cuda")
    for accepted_count in (0, tokens + 1):
        accepted = torch.tensor([accepted_count], dtype=torch.int32, device="cuda")
        initial = torch.rand(
            tokens + 1, v_heads, head_dim, head_dim, device="cuda"
        )
        recurrent_state = initial.clone()
        recurrent_out, recurrent_state = fused_recurrent_gated_delta_rule(
            q=query,
            k=key,
            v=value,
            g=torch.rand(1, tokens, v_heads, device="cuda"),
            beta=torch.rand(1, tokens, v_heads, device="cuda"),
            initial_state=recurrent_state,
            inplace_final_state=True,
            ssm_state_indices=state_indices,
            cu_seqlens=cu_seqlens,
            num_accepted_tokens=accepted,
        )
        sigmoid_state = initial.clone()
        sigmoid_out, sigmoid_state = fused_sigmoid_gating_delta_rule_update(
            A_log=torch.rand(v_heads, device="cuda"),
            a=torch.rand(tokens, v_heads, device="cuda"),
            b=torch.rand(tokens, v_heads, device="cuda"),
            dt_bias=torch.rand(v_heads, device="cuda"),
            q=query,
            k=key,
            v=value,
            initial_state=sigmoid_state,
            inplace_final_state=True,
            ssm_state_indices=state_indices,
            cu_seqlens=cu_seqlens,
            num_accepted_tokens=accepted,
        )
        torch.testing.assert_close(recurrent_out, torch.zeros_like(recurrent_out))
        torch.testing.assert_close(sigmoid_out, torch.zeros_like(sigmoid_out))
        torch.testing.assert_close(recurrent_state, initial)
        torch.testing.assert_close(sigmoid_state, initial)

    ple = ple_layer.Qwen4ExpPLELayer.__new__(ple_layer.Qwen4ExpPLELayer)
    torch.nn.Module.__init__(ple)
    ple.conv_state_len = 6
    ple.short_conv_dilation = 2
    ple_weights = torch.tensor(
        [[0.25, -0.5, 0.75, 1.0]], device="cuda"
    )
    ple_inputs = torch.tensor(
        [[10.0], [20.0], [30.0], [40.0]], device="cuda"
    )
    for invalid_state_index in (-1, 2):
        decode_state = torch.zeros(2, 1, 6, device="cuda")
        decode_before = decode_state.clone()
        decode_output = ple._short_conv_dilated_decode_batched(
            ple_inputs[:1],
            decode_state,
            ple_weights,
            torch.tensor([invalid_state_index], device="cuda"),
            None,
        )
        torch.testing.assert_close(decode_output, torch.zeros_like(decode_output))
        torch.testing.assert_close(decode_state, decode_before)

        prefill_state = torch.zeros(2, 1, 6, device="cuda")
        prefill_before = prefill_state.clone()
        prefill_output = ple._short_conv_dilated_prefill_batched(
            ple_inputs[:2],
            SimpleNamespace(
                non_spec_query_start_loc=torch.tensor([0, 2], device="cuda"),
                has_initial_states_p=torch.tensor([True], device="cuda"),
                max_prefill_query_len=2,
            ),
            prefill_state,
            ple_weights,
            torch.tensor([invalid_state_index], device="cuda"),
            num_prefills=1,
            num_decode_tokens=0,
            num_prefill_tokens=2,
        )
        torch.testing.assert_close(prefill_output, torch.zeros_like(prefill_output))
        torch.testing.assert_close(prefill_state, prefill_before)

    for state_index, accepted_count in ((1, 0), (1, 5), (-1, 1), (2, 1)):
        ple_state = torch.zeros(2, 1, 9, device="cuda")
        ple_state[1] = torch.arange(1, 10, device="cuda").reshape(1, 9)
        ple_state_before = ple_state.clone()
        ple_output = ple._short_conv_dilated_spec_batched(
            ple_inputs,
            ple_state,
            ple_weights,
            torch.tensor([state_index], device="cuda"),
            torch.tensor([0, 4], device="cuda"),
            torch.tensor([accepted_count], device="cuda"),
            spec_query_len=4,
        )
        torch.testing.assert_close(ple_output, torch.zeros_like(ple_output))
        torch.testing.assert_close(ple_state, ple_state_before)


def main() -> None:
    assert SOURCE_COMMIT == "e126687a9a828d513c01a07cd69f025f27d63280"
    assert torch.cuda.is_available()
    assert torch.cuda.get_device_capability() == (12, 0)
    source_hashes = verify_source_and_capabilities()
    verify_mixed_partition()
    topk_hashes = verify_exact_topk()
    qsa_hashes = verify_qsa()
    verify_state_bounds()
    torch.cuda.synchronize()
    print(
        json.dumps(
            {
                "status": "PASS",
                "source": source_hashes,
                "topk": topk_hashes,
                "qsa": qsa_hashes,
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
