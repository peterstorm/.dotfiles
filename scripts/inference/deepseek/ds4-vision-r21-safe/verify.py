#!/usr/bin/env python3
"""Static, checkpoint, and pure-contract verification for the DS4 Vision overlay."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace

import torch

SOURCE_ROOT = Path("/opt/infernal-invocation/vllm")
FINAL_MANIFEST = Path("/tmp/ds4-vision/final-source-sha256.txt")
MODEL_REVISION = "86f746b36186f0e567729a5c06a8c918caba82a9"
CONFIG_SHA256 = "6cd841bdd6702f5e2ac34671bc78047ed80817102465525ae2a41c502abbcd75"
INDEX_SHA256 = "507977e3d3818865264e68c0fdab139aa7f3929d0d0cf693dacc47428da56395"
TOKENIZER_CONFIG_SHA256 = (
    "6ac8c8dc065ed118161d02dd532749ae3f52c243deac27872134fae2f50d8547"
)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _verify_source_manifest() -> None:
    for line in FINAL_MANIFEST.read_text().splitlines():
        expected, relative = line.split(maxsplit=1)
        actual = _sha256(SOURCE_ROOT / relative)
        assert actual == expected, f"source hash mismatch: {relative}"


def _verify_registry_and_config() -> None:
    from vllm.model_executor.models.registry import (
        _MULTIMODAL_MODELS,
        _TEXT_GENERATION_MODELS,
    )
    from vllm.models.deepseek_v4 import DeepseekV4ForCausalLM
    from vllm.transformers_utils.configs.deepseek_v4 import DeepseekV4Config

    assert "DeepseekV4ForCausalLM" not in _TEXT_GENERATION_MODELS
    assert _MULTIMODAL_MODELS["DeepseekV4ForCausalLM"] == (
        "vllm.models.deepseek_v4",
        "DeepseekV4ForCausalLM",
    )
    assert DeepseekV4ForCausalLM.supports_multimodal
    assert DeepseekV4ForCausalLM.requires_raw_input_tokens

    text = DeepseekV4Config()
    assert text.vision_n_layers is None
    vision = DeepseekV4Config(vision_n_layers=32)
    assert (
        vision.vision_dim,
        vision.vision_n_heads,
        vision.vision_inter_dim,
        vision.vision_patch_size,
        vision.vision_downsample_ratio,
        vision.vision_max_n_token,
    ) == (1024, 16, 2816, 14, 3, 384)


def _verify_layout_routing_and_lse() -> None:
    from vllm.models.deepseek_v4.image_processing import (
        IMAGE,
        IMAGE_END,
        IMAGE_START,
        build_image_block,
    )
    from vllm.models.deepseek_v4.routing import (
        sanitize_synthetic_image_token_ids,
        vision_aware_topk,
    )
    from vllm.models.deepseek_v4.vision_swa import (
        build_image_partition_indices,
        merge_attention_partitions,
    )

    for start in (0, 1, 3, 17, 129):
        token_types, permutation = build_image_block(9, 13, start)
        assert token_types.numel() <= 384
        assert (token_types == IMAGE_START).sum().item() == 1
        assert (token_types == IMAGE_END).sum().item() == 1
        assert permutation.numel() == 9 * 13
        assert torch.equal(torch.sort(permutation).values, torch.arange(9 * 13))

    torch.manual_seed(7)
    rows, experts, topk, vocab_size = 12, 32, 6, 100
    logits = torch.randn(rows, experts)
    input_ids = torch.tensor([1, 2, 100, 101, 102, 103, 104, 9, 10, 11, 12, 13])
    text_bias = torch.randn(experts)
    vision_bias = torch.randn(experts)
    hash_table = torch.randint(0, experts, (vocab_size, topk), dtype=torch.int32)
    for hashed in (False, True):
        weights, indices = vision_aware_topk(
            gating_output=logits,
            input_ids=input_ids,
            vocab_size=vocab_size,
            topk=topk,
            scoring_func="sqrtsoftplus",
            text_bias=text_bias,
            vision_bias=vision_bias,
            hash_indices_table=hash_table if hashed else None,
            renormalize=True,
            routed_scaling_factor=1.5,
        )
        assert weights.shape == indices.shape == (rows, topk)
        assert indices.dtype == torch.int32
        assert torch.allclose(weights.sum(-1), torch.full((rows,), 1.5))
    safe = sanitize_synthetic_image_token_ids(input_ids, vocab_size)
    assert safe[2:7].eq(0).all()

    token_ids = torch.tensor([7, 101, 101, 100, 102, 103, 102, 104, 9, 10])
    positions = torch.arange(token_ids.numel())
    query_starts = torch.tensor([0, token_ids.numel()], dtype=torch.int32)
    block_table = torch.tensor([[5, 2, 8]], dtype=torch.int32)
    image_indices = torch.empty((token_ids.numel(), 1, 16), dtype=torch.int32)
    image_lens = torch.empty(token_ids.numel(), dtype=torch.int32)
    assert build_image_partition_indices(
        input_ids=token_ids,
        positions=positions,
        query_start_loc_cpu=query_starts,
        block_table=block_table,
        block_size=4,
        num_decodes=0,
        num_decode_tokens=0,
        window_size=4,
        max_image_tokens=8,
        output_indices=image_indices,
        output_lens=image_lens,
        vocab_size=vocab_size,
    )

    normal_logits = torch.randn(4, 3, 5)
    image_logits = torch.randn(4, 3, 7)
    normal_values = torch.randn(4, 3, 5, 6)
    image_values = torch.randn(4, 3, 7, 6)
    normal_output = (
        torch.softmax(normal_logits, -1).unsqueeze(-1) * normal_values
    ).sum(-2)
    image_output = (
        torch.softmax(image_logits, -1).unsqueeze(-1) * image_values
    ).sum(-2)
    merged = merge_attention_partitions(
        normal_output,
        torch.logsumexp(normal_logits, -1),
        image_output,
        torch.logsumexp(image_logits, -1),
    )
    combined_logits = torch.cat((normal_logits, image_logits), -1)
    combined_values = torch.cat((normal_values, image_values), -2)
    reference = (
        torch.softmax(combined_logits, -1).unsqueeze(-1) * combined_values
    ).sum(-2)
    assert torch.allclose(merged, reference, atol=1e-6)


def _verify_scheduler_atomicity() -> None:
    from vllm.multimodal.inputs import PlaceholderRange
    from vllm.v1.core.sched.scheduler import Scheduler

    class KVManager:
        def truncate_computed_blocks(self, blocks, count):
            return (blocks, count)

    class EncoderManager:
        def __init__(self, cached: bool):
            self.cached = cached
            self.cache_checks = 0

        def check_and_update_cache(self, request, index):
            self.cache_checks += 1
            return self.cached

        def can_allocate(self, *args):
            return True

    feature = SimpleNamespace(
        mm_position=PlaceholderRange(offset=64, length=200), identifier="image"
    )
    request = SimpleNamespace(mm_features=[feature], has_encoder_inputs=True)
    scheduler = Scheduler.__new__(Scheduler)
    scheduler.block_size = 64
    scheduler.kv_cache_manager = KVManager()
    blocks, count, shared = scheduler._repair_partial_multimodal_prefix_hit(
        request, "blocks", 128, 192
    )
    assert (blocks, count, shared) == (("blocks", 64), 64, 64)

    scheduler.scheduler_config = SimpleNamespace(disable_chunked_mm_input=True)
    scheduler.is_encoder_decoder = False
    scheduler.ec_connector = None
    scheduler.encoder_cache_manager = EncoderManager(cached=True)
    result = scheduler._try_schedule_encoder_inputs(request, 0, 128, 1000)
    assert result[1] == 64
    assert scheduler.encoder_cache_manager.cache_checks == 0


def verify_static() -> None:
    _verify_source_manifest()
    _verify_registry_and_config()
    _verify_layout_routing_and_lse()
    _verify_scheduler_atomicity()


def verify_checkpoint(checkpoint: Path) -> None:
    expected_hashes = {
        "config.json": CONFIG_SHA256,
        "model.safetensors.index.json": INDEX_SHA256,
        "tokenizer_config.json": TOKENIZER_CONFIG_SHA256,
    }
    for relative, expected in expected_hashes.items():
        assert _sha256(checkpoint / relative) == expected, relative

    config = json.loads((checkpoint / "config.json").read_text())
    expected_config = {
        "vision_n_layers": 32,
        "vision_dim": 1024,
        "vision_n_heads": 16,
        "vision_inter_dim": 2816,
        "vision_patch_size": 14,
        "vision_downsample_ratio": 3,
        "vision_max_n_token": 384,
        "vision_min_pixels": 147456,
        "vision_max_wh_ratio": 8,
        "rms_norm_eps": 1e-20,
    }
    for key, expected in expected_config.items():
        assert config[key] == expected, key

    weight_map = json.loads(
        (checkpoint / "model.safetensors.index.json").read_text()
    )["weight_map"]
    required = {
        "vision.patch_embed.proj.weight",
        "vision.patch_embed.proj.bias",
        "vision.norm.weight",
        "aligner.w1.weight",
        "aligner.w1.bias",
        "aligner.w2.weight",
        "aligner.w2.bias",
        "image_start",
        "image_pad",
        "image_newline",
        "image_end",
    }
    for layer in range(32):
        required.update(
            {
                f"vision.blocks.{layer}.norm1.weight",
                f"vision.blocks.{layer}.attn.wqkv.weight",
                f"vision.blocks.{layer}.attn.wqkv.bias",
                f"vision.blocks.{layer}.attn.wo.weight",
                f"vision.blocks.{layer}.attn.wo.bias",
                f"vision.blocks.{layer}.norm2.weight",
                f"vision.blocks.{layer}.mlp.w1.weight",
                f"vision.blocks.{layer}.mlp.w2.weight",
            }
        )
    for layer in range(43):
        required.add(f"layers.{layer}.ffn.gate.bias")
        required.add(f"layers.{layer}.ffn.gate.bias_vl")
    for layer in range(3):
        required.add(f"mtp.{layer}.ffn.gate.bias")
        required.add(f"mtp.{layer}.ffn.gate.bias_vl")
    missing = required - weight_map.keys()
    assert not missing, f"checkpoint is missing {sorted(missing)[:8]}"
    shards = sorted(checkpoint.glob("model-*-of-00048.safetensors"))
    assert len(shards) == 48
    assert all(path.stat().st_size > 0 for path in shards)

    marker = checkpoint / ".deepseek-v4-flash-vision-exp.revision"
    if marker.exists():
        assert marker.read_text().strip() == MODEL_REVISION


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--static", action="store_true")
    parser.add_argument("--checkpoint", type=Path)
    args = parser.parse_args()
    if args.static:
        verify_static()
    if args.checkpoint:
        verify_checkpoint(args.checkpoint)
    if not args.static and args.checkpoint is None:
        parser.error("select --static and/or --checkpoint")
    print("DeepSeek V4 Flash Vision r21 overlay verification: PASS")


if __name__ == "__main__":
    main()
