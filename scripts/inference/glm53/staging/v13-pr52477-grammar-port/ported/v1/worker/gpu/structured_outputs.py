# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project
#
# [PR52477-PORT] GPU-count-driven grammar masks (fixed-width blocks).
# Hand-ported from vllm-project/vllm#52477 "Drive grammar masks from GPU logit
# counts" onto the GLM-5.3-flash legend lineage. Upstream #52477 patches a
# `self.mask_stride`/CPU-`mapping` base; this fork instead shipped the compacted
# `_build_grammar_row_mapping` design (asserting num_active_drafts <=
# num_source_drafts), which crashes when DSpark adaptive verification finalizes
# MORE active drafts on-device than the scheduler scheduled. This file
# re-implements the PR's TARGET design: every structured-output request owns a
# fixed-width mask block of `mask_stride` rows; the Triton kernel launches once
# per grammar request and reads the request's *actual* logit count from
# device-side `cu_num_logits`, applying only the active positions. No CPU-side
# compaction and no scheduled-draft count, so the stale hand-off can no longer
# trip an assertion (or, worse, silently mis-map a row).
import numpy as np
import torch

from vllm.triton_utils import tl, triton
from vllm.utils.math_utils import cdiv
from vllm.v1.worker.gpu.buffer_utils import async_copy_to_gpu
from vllm.v1.worker.gpu.input_batch import InputBatch


class StructuredOutputsWorker:
    def __init__(
        self,
        max_num_logits: int,
        vocab_size: int,
        device: torch.device,
        mask_stride: int,
        num_bonus_tokens: int = 1,
    ):
        # [PR52477-PORT] mask_stride is the per-request fixed block width
        # (== decode_query_len, threaded in by model_runner's FORK-COMPAT
        # shim). The producer serializes num_grammar_reqs * mask_stride rows.
        assert mask_stride >= 1
        self.mask_stride = mask_stride
        # Request-index scratch: one int32 per grammar request. num_grammar_reqs
        # <= max_num_reqs <= max_num_logits, so this buffer always fits.
        self.logits_indices = torch.zeros(
            max_num_logits, dtype=torch.int32, device=device
        )
        self.grammar_bitmask = torch.zeros(
            (max_num_logits, cdiv(vocab_size, 32)), dtype=torch.int32, device=device
        )
        self.device = device
        self.copy_stream = torch.cuda.Stream()
        self.num_bonus_tokens = num_bonus_tokens

    def apply_grammar_bitmask(
        self,
        logits: torch.Tensor,
        input_batch: InputBatch,
        grammar_req_ids: list[str],
        grammar_bitmask: np.ndarray,
        grammar_num_spec_tokens: list[int],
    ) -> None:
        # grammar_num_spec_tokens is kept for call-site signature compatibility
        # with the fork's model_runner; the GPU-driven design no longer needs
        # the scheduler's scheduled-draft counts.
        del grammar_num_spec_tokens

        if not grammar_req_ids:
            return

        num_grammar_reqs = len(grammar_req_ids)
        # [PR52477-PORT] Fixed-width invariant: the producer emits exactly
        # mask_stride rows per grammar request. This replaces the fragile
        # `num_active_drafts <= num_source_drafts` compaction assertion.
        assert grammar_bitmask.shape[0] == num_grammar_reqs * self.mask_stride

        # Asynchronously copy the (fixed-width) bitmask block to GPU.
        with torch.cuda.stream(self.copy_stream):
            bitmask = async_copy_to_gpu(
                grammar_bitmask, out=self.grammar_bitmask[: grammar_bitmask.shape[0]]
            )

        # The kernel resolves per-request logit offsets from the GPU's finalized
        # cu_num_logits, so the worker only needs each grammar request's batch
        # index — not a CPU-built position mapping.
        req_id_to_idx = {
            req_id: req_idx for req_idx, req_id in enumerate(input_batch.req_ids)
        }
        req_indices = [req_id_to_idx[req_id] for req_id in grammar_req_ids]

        # Asynchronously copy the request indices to GPU (reusing the scratch).
        with torch.cuda.stream(self.copy_stream):
            req_indices_tensor = torch.tensor(
                req_indices, dtype=torch.int32, device="cpu", pin_memory=True
            )
            req_indices_tensor = self.logits_indices[:num_grammar_reqs].copy_(
                req_indices_tensor, non_blocking=True
            )

        # Ensure all async copies are complete before launching the kernel.
        current_stream = torch.cuda.current_stream()
        current_stream.wait_stream(self.copy_stream)

        vocab_size = logits.shape[-1]
        BLOCK_SIZE = 8192
        # One program per grammar request (not per compacted mask row); the
        # kernel iterates the request's active positions internally.
        grid = (num_grammar_reqs, triton.cdiv(vocab_size, BLOCK_SIZE))
        _apply_grammar_bitmask_kernel[grid](
            logits,
            logits.stride(0),
            req_indices_tensor,
            input_batch.cu_num_logits,
            bitmask,
            bitmask.stride(0),
            vocab_size,
            MASK_STRIDE=self.mask_stride,
            BLOCK_SIZE=BLOCK_SIZE,
        )

        # Ensure the copy stream waits for the device tensors to finish being
        # used before it re-uses or deallocates them.
        self.copy_stream.wait_stream(current_stream)


# Adapted from
# https://github.com/mlc-ai/xgrammar/blob/main/python/xgrammar/kernels/apply_token_bitmask_inplace_triton.py
# [PR52477-PORT] GPU-count-driven variant: each program handles one grammar
# request and walks its fixed-width block, applying only positions that are
# active per the device-finalized cu_num_logits.
@triton.jit
def _apply_grammar_bitmask_kernel(
    logits_ptr,
    logits_stride,
    req_indices_ptr,
    cu_num_logits_ptr,
    bitmask_ptr,
    bitmask_stride,
    vocab_size,
    MASK_STRIDE: tl.constexpr,
    BLOCK_SIZE: tl.constexpr,
):
    grammar_idx = tl.program_id(0)
    req_idx = tl.load(req_indices_ptr + grammar_idx)
    logits_start_idx = tl.load(cu_num_logits_ptr + req_idx)
    num_req_logits = tl.load(cu_num_logits_ptr + req_idx + 1) - logits_start_idx

    block_id = tl.program_id(1)
    bitmask_offset = (block_id * BLOCK_SIZE) // 32 + tl.arange(0, BLOCK_SIZE // 32)
    block_offset = block_id * BLOCK_SIZE + tl.arange(0, BLOCK_SIZE)

    for position_idx in range(MASK_STRIDE):
        # Only positions the GPU actually finalized for this request are
        # constrained; extra fixed-width rows are skipped via the active mask.
        position_is_active = position_idx < num_req_logits
        bitmask_idx = grammar_idx * MASK_STRIDE + position_idx
        packed_bitmask = tl.load(
            bitmask_ptr + bitmask_idx * bitmask_stride + bitmask_offset,
            mask=position_is_active & (bitmask_offset < bitmask_stride),
            other=0,
        )
        # Unpack the bitmask.
        bitmask = ((packed_bitmask[:, None] >> (tl.arange(0, 32)[None, :])) & 1) == 0
        bitmask = bitmask.reshape(BLOCK_SIZE)

        # Apply the bitmask to the logits at this request's active position.
        logits_idx = logits_start_idx + position_idx
        tl.store(
            logits_ptr + logits_idx * logits_stride + block_offset,
            -float("inf"),
            mask=(position_is_active & bitmask & (block_offset < vocab_size)),
        )
