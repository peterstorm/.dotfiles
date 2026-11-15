#!/usr/bin/env python3
"""Unit checks for glm53-uncensored-convert.py: the pure plan, the fold, slab CSF, the shard layout,
build, verify, the claim that converting the converter's first output (v1) gives the bytes
converting the download gives, and that a current output is a fixed point (converting it again,
or converting the first v2 output with its draft layer unfolded, gives the same bytes).

Runs on a synthetic dealignai-shaped source and a v16-shaped base in a temp directory. The
quantizer port is a deterministic fake that records its calls; where torch is importable (the
serving image) the production adapter is exercised on a real BF16 tensor and slab CSF is checked
against ignition's reference decoder as well. Needs numpy (the build encodes CSF with it).
Mutations for verify are made on scratch copies of the built output -- never on live files.

    docker run --rm --user 1000:1000 --entrypoint /opt/flare/.venv/bin/python3 -v "$PWD":/work \\
        peterstorm/glm53-hyperflare:ac9136b-cu131 -I /work/tests/glm53-uncensored-convert-unit.py
    nix-shell -p 'python3.withPackages (p: [ p.numpy ])' --run 'python3 -I tests/glm53-uncensored-convert-unit.py'
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import math
import shutil
import struct
import sys
import tempfile
from pathlib import Path

import numpy as np

MODULE_PATH = Path(__file__).resolve().parent.parent / "scripts/inference/glm53/glm53-uncensored-convert.py"
spec = importlib.util.spec_from_file_location("uncensored_convert", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod  # dataclasses resolve postponed annotations through sys.modules
spec.loader.exec_module(mod)

CHECKS = 0
L = "model.language_model.layers"


def check(condition: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(f"check {CHECKS} FAILED: {label}")


def check_raises(label: str, operation, needle: str = "") -> None:
    global CHECKS
    try:
        operation()
    except Exception as error:  # noqa: BLE001 - any refusal counts, the message is checked
        CHECKS += 1
        if needle and needle not in str(error):
            raise AssertionError(f"check {CHECKS} FAILED: {label}: raised {error!r}, expected {needle!r}")
        return
    raise AssertionError(f"check {CHECKS + 1} FAILED (no raise): {label}")


def payload(name: str, size: int) -> bytes:
    """Deterministic bytes, distinct per tensor name, so a misplaced copy is detectable."""
    seed = sum(name.encode())
    return bytes((seed + i * 31) % 256 for i in range(size))


def tensor(name: str, dtype: str, shape: list[int], data: bytes | None = None) -> tuple:
    return (name, dtype, shape, payload(name, mod.nbytes(dtype, shape)) if data is None else data)


def f32(name: str, value: float) -> tuple:
    return tensor(name, "F32", [], struct.pack("<f", value))


def write_safetensors(path: Path, tensors, metadata: dict | None = None) -> None:
    header: dict = {}
    if metadata:
        header["__metadata__"] = metadata
    offset = 0
    for name, dtype, shape, data in tensors:
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [offset, offset + len(data)]}
        offset += len(data)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as handle:
        handle.write(mod.dense.serialize_header(header))
        for *_, data in tensors:
            handle.write(data)


def write_checkpoint(root: Path, shards: dict[str, list], config: dict, metadata: dict | None = None) -> None:
    weight_map = {}
    for shard, tensors in shards.items():
        write_safetensors(root / shard, tensors, metadata)
        weight_map.update({name: shard for name, *_ in tensors})
    total = sum(len(data) for tensors in shards.values() for *_, data in tensors)
    (root / mod.INDEX).write_text(json.dumps({"metadata": {"total_size": total}, "weight_map": weight_map}))
    (root / "config.json").write_text(json.dumps(config))


def tensors_of(root: Path, shard: str) -> list[tuple]:
    """A shard's tensors in header order, as write_safetensors takes them."""
    _, header = mod.dense.read_header(root / shard)
    return [(name, meta["dtype"], meta["shape"], mod.read_tensor(root, shard, name))
            for name, meta in header.items() if name != "__metadata__"]


# --- fixture -------------------------------------------------------------------------

ARCH = {"architectures": ["GlmForCausalLM"], "text_config": {"num_hidden_layers": 3, "hidden_size": 64},
        "vision_config": {"depth": 1}}
KDA = f"{L}.0.self_attn"
MLA = f"{L}.1.self_attn"
CSF_LAYER = f"{L}.1.mlp.experts"
W4A16_LAYER = f"{L}.2.mlp.experts"
VISION_SOURCE_SHARD = "model-00004-of-00005.safetensors"
UNTOUCHED_SHARD = "model-00005-of-00005.safetensors"
MX8 = {"quant_algo": "MXFP8", "weight_block_size": [1, 32]}
V16_LAYERS = {
    f"{KDA}.q_proj": MX8, f"{KDA}.k_proj": MX8, f"{KDA}.v_proj": MX8, f"{KDA}.o_proj": MX8,
    f"{MLA}.q_b_proj": {"quant_algo": "FP8_PB_WO", "weight_block_size": [128, 128]},
    "lm_head": {"quant_algo": "MXFP8", "group_size": 32},
    CSF_LAYER: {"quant_algo": "NVFP4", "group_size": 16, "weight_scale_encoding": "csf_32x2_v1"},
    W4A16_LAYER: {"quant_algo": "W4A16_NVFP4", "group_size": 16},
    "model.visual.blocks.0.attn.qkv": {"quant_algo": "NVFP4", "group_size": 16},
}
V16_QC = {"exclude_modules": [], "quant_algo": "MIXED_PRECISION", "quant_method": "modelopt",
          "quantized_layers": V16_LAYERS}
SOURCE_QC = {"quant_method": "modelopt", "quant_algo": "NVFP4", "ignore": ["lm_head"]}

#: (gate, up, down) globals per compressed expert: up halved (c = 1.5), gate halved twice (c = 0.25),
#: equal globals, and a ratio the down global absorbs without a power of two (c = 0.75).
GLOBALS = {0: (3.0, 2.0, 0.5), 1: (1.0, 4.0, 0.5), 2: (2.0, 2.0, 0.5), 3: (3.0, 4.0, 0.25)}
V16_INPUTS = {"gate_proj": 0.0078125, "up_proj": 0.0078125, "down_proj": 0.03125}
CSF_ROWS, CSF_PACKED = 64, 32          # weight [64, 32] packs 64 FP4 columns: four E4M3 scales a row


def scale_plane(seed: int, rows: int = CSF_ROWS, columns: int = 2 * CSF_PACKED // 16) -> bytes:
    """Normal-range E4M3 bytes (exactly halvable) spread so some rows need exceptions."""
    return bytes(0x60 if (row + column + seed) % 11 == 0 else 0x30 + (row * 7 + column * 3 + seed) % 12
                 for row in range(rows) for column in range(columns))


def csf_experts_source() -> list:
    out = []
    for number, globals_ in GLOBALS.items():
        for index, projection in enumerate(mod.PROJECTIONS):
            prefix = f"{CSF_LAYER}.{number}.{projection}"
            out += [tensor(f"{prefix}.weight", "U8", [CSF_ROWS, CSF_PACKED]),
                    tensor(f"{prefix}.weight_scale", "F8_E4M3", [CSF_ROWS, 4], scale_plane(number * 3 + index)),
                    f32(f"{prefix}.weight_scale_2", globals_[index])]
    return out


def csf_experts_base() -> list:
    out = []
    for number in GLOBALS:
        for projection in mod.PROJECTIONS:
            prefix = f"{CSF_LAYER}.{number}.{projection}"
            out += [tensor(f"{prefix}.weight", "U8", [CSF_ROWS, CSF_PACKED]),
                    tensor(f"{prefix}.weight_scale.csf32_bases", "U8", [CSF_ROWS]),
                    f32(f"{prefix}.weight_scale_2", 1.0), f32(f"{prefix}.input_scale", V16_INPUTS[projection])]
    return out


#: (gate, up, down) globals per draft-layer (W4A16) expert: up halved (c = 1.5), and globals already shared.
DRAFT_GLOBALS = {0: (3.0, 2.0, 0.5), 1: (2.0, 2.0, 0.25)}
DRAFT_ROWS = 32                        # weight [32, 16] packs 32 FP4 columns: two E4M3 scales a row


def plain_experts(layer: str) -> list:
    """The draft layer's experts as released (and as v16 holds them): plain planes, no input scales."""
    out = []
    for number, globals_ in DRAFT_GLOBALS.items():
        for index, projection in enumerate(mod.PROJECTIONS):
            prefix = f"{layer}.{number}.{projection}"
            out += [tensor(f"{prefix}.weight", "U8", [DRAFT_ROWS, 16]),
                    tensor(f"{prefix}.weight_scale", "F8_E4M3", [DRAFT_ROWS, 2],
                           scale_plane(50 + number * 3 + index, DRAFT_ROWS, 2)),
                    f32(f"{prefix}.weight_scale_2", globals_[index])]
    return out


INPUT_SCALES = "model-input-scales.safetensors"  # dealignai's side file: all 1.0, outside the index


def source_vision(extra: bool = False) -> list:
    tensors = [tensor("model.visual.blocks.0.attn.qkv.weight", "BF16", [32, 16]),
               tensor("model.visual.patch_embed.weight", "BF16", [4, 4])]
    return tensors + ([tensor("model.visual.extra.weight", "BF16", [4, 4])] if extra else [])


def fp8_pair(prefix: str, shape: list[int], scale_dtype: str, scale_shape: list[int]) -> list:
    return [tensor(f"{prefix}.weight", "F8_E4M3", shape), tensor(f"{prefix}.weight_scale", scale_dtype, scale_shape)]


def build_fixture(root: Path) -> tuple[Path, Path]:
    source, base = root / "source", root / "base"
    write_checkpoint(base, {
        "base-attn.safetensors": [
            *fp8_pair(f"{KDA}.q_proj", [64, 64], "U8", [64, 2]), *fp8_pair(f"{KDA}.k_proj", [64, 64], "U8", [64, 2]),
            *fp8_pair(f"{KDA}.v_proj", [64, 64], "U8", [64, 2]), tensor(f"{KDA}.f_a_proj.weight", "BF16", [8, 64]),
            *fp8_pair(f"{KDA}.o_proj", [64, 64], "U8", [64, 2]),
            *fp8_pair(f"{MLA}.q_b_proj", [128, 128], "F32", [1, 1, 1, 1]),
            *fp8_pair("lm_head", [16, 64], "U8", [16, 2]),
        ],
        "base-experts.safetensors": csf_experts_base() + plain_experts(W4A16_LAYER),
        "tensors/visual.safetensors": [
            tensor("model.visual.blocks.0.attn.qkv.weight", "U8", [32, 8]),
            tensor("model.visual.blocks.0.attn.qkv.weight_scale", "F8_E4M3", [32, 1]),
            tensor("model.visual.blocks.0.attn.qkv.weight_scale_2", "F32", []),
            tensor("model.visual.blocks.0.attn.qkv.input_scale", "F32", []),
            tensor("model.visual.patch_embed.weight", "BF16", [4, 4]),
        ],
    }, ARCH | {"quantization_config": V16_QC})
    (base / "chat_template.jinja").write_text("{%- set clear_thinking = false -%}{{ messages }}")

    write_checkpoint(source, {
        "model-00001-of-00005.safetensors": [
            tensor(f"{KDA}.q_proj.weight", "BF16", [64, 64]), tensor(f"{KDA}.k_proj.weight", "BF16", [64, 64]),
            tensor(f"{KDA}.v_proj.weight", "BF16", [64, 64]), tensor(f"{KDA}.f_a_proj.weight", "BF16", [8, 64]),
            tensor(f"{KDA}.o_proj.weight", "BF16", [64, 64]),
        ],
        "model-00002-of-00005.safetensors": [tensor(f"{MLA}.q_b_proj.weight", "BF16", [128, 128])]
        + csf_experts_source() + plain_experts(W4A16_LAYER),
        "model-00003-of-00005.safetensors": [tensor("lm_head.weight", "BF16", [16, 64])],
        VISION_SOURCE_SHARD: source_vision(),
        UNTOUCHED_SHARD: [tensor("model.language_model.embed_tokens.weight", "BF16", [16, 64]),
                          tensor("model.language_model.norm.weight", "BF16", [64])],
    }, ARCH | {"quantization_config": SOURCE_QC}, metadata={"format": "pt"})
    write_safetensors(source / INPUT_SCALES, [f32(f"{CSF_LAYER}.{n}.{p}.input_scale", 1.0)
                                              for n in GLOBALS for p in mod.PROJECTIONS])
    (source / "tokenizer.json").write_text('{"model": "bpe"}')
    (source / "chat_template.jinja").write_text("{%- set clear_thinking = true -%}{{ messages }}")
    (source / "README.md").write_text("card")
    (source / ".download-complete").write_text("dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 abc\n")
    (source / ".cache").mkdir()
    return source, base


class FakeQuantizer:
    """Deterministic port double: values are the right length, scales fill v16's grid."""

    def __init__(self):
        self.calls = []

    def __call__(self, data: bytes, shape: tuple, storage: str):
        self.calls.append((len(data), tuple(shape), storage))
        rows, columns = shape
        grid = mod.hybrid.expected_scale_shape(mod.hybrid.Storage(storage), shape)
        scale_bytes = math.prod(grid) * (1 if storage == "mx8" else 4)
        return data[: rows * columns], bytes([storage == "mx8"] * scale_bytes), (0.02, 0.5)


def quiet(operation):
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        return operation()


# --- pure core -----------------------------------------------------------------------

def test_pure() -> None:
    check(mod.config_mismatches({"a": 1, "q": {"x": 1}, "quantization_config": 1},
                                {"a": 1, "q": {"x": 2}, "quantization_config": 2}) == ["q.x"],
          "config_mismatches: nested keys named by path, quantization_config ignored")
    check(mod.config_mismatches({"a": 1}, {"a": 1, "b": 2}) == ["b"], "config_mismatches: a missing key differs")
    check(mod.side_files(["tokenizer.json", "config.json", mod.INDEX, "a.safetensors", ".download-complete",
                          "chat_template.jinja", mod.RECEIPT, "README.md", INPUT_SCALES]) == ["README.md", "tokenizer.json"],
          "side_files: tensors (the input-scale side file too), index, config, receipt, dot files and v16-pinned "
          "files stay behind")
    check(mod.unscaled(["a.weight", "a.weight_scale", "a.weight_scale_2", "a.input_scale", "b.bias"])
          == {"a.weight", "b.bias"}, "unscaled: a format's scale tensors are not the tensor set")
    check(mod.expert_layer_of(f"{CSF_LAYER}.7.up_proj.weight") == CSF_LAYER
          and mod.expert_layer_of(f"{L}.1.mlp.shared_experts.up_proj.weight") is None,
          "expert_layer_of: routed experts only, never the shared expert")

    bf16 = {"dtype": "BF16", "shape": [64, 64]}
    mx8 = mod.plan_requant("p", "s", bf16, {"dtype": "F8_E4M3", "shape": [64, 64]},
                           {"dtype": "U8", "shape": [64, 2]})
    check((mx8.storage, mx8.scale_dtype, mx8.scale_shape, mx8.scale) == ("mx8", "U8", (64, 2), "p.weight_scale"),
          "plan_requant: MXFP8 with v16's U8 E8M0 grid")
    block = mod.plan_requant("p", "s", {"dtype": "BF16", "shape": [256, 128]},
                             {"dtype": "F8_E4M3", "shape": [256, 128]}, {"dtype": "F32", "shape": [2, 1, 1, 1]})
    check((block.storage, block.scale_shape) == ("block8", (2, 1, 1, 1)), "plan_requant: block FP8 on 128x128")
    check_raises("plan_requant: an FP8 source is not dealignai's BF16", lambda: mod.plan_requant(
        "p", "s", {"dtype": "F8_E4M3", "shape": [64, 64]}, {"dtype": "F8_E4M3", "shape": [64, 64]},
        {"dtype": "U8", "shape": [64, 2]}), "expected 2-D BF16")
    check_raises("plan_requant: shapes must agree", lambda: mod.plan_requant(
        "p", "s", bf16, {"dtype": "F8_E4M3", "shape": [64, 32]}, {"dtype": "U8", "shape": [64, 1]}), "in v16")
    check_raises("plan_requant: v16 storing BF16 leaves nothing to match", lambda: mod.plan_requant(
        "p", "s", bf16, {"dtype": "BF16", "shape": [64, 64]}, None), "nothing to match")
    check_raises("plan_requant: an FP8 weight without a scale", lambda: mod.plan_requant(
        "p", "s", bf16, {"dtype": "F8_E4M3", "shape": [64, 64]}, None), "without a scale")
    check_raises("plan_requant: a scale grid the writer would not produce", lambda: mod.plan_requant(
        "p", "s", bf16, {"dtype": "F8_E4M3", "shape": [64, 64]}, {"dtype": "U8", "shape": [32, 2]}), "scale grid")
    check_raises("plan_requant: an unaligned width", lambda: mod.plan_requant(
        "p", "s", {"dtype": "BF16", "shape": [64, 48]}, {"dtype": "F8_E4M3", "shape": [64, 48]},
        {"dtype": "U8", "shape": [64, 2]}), "32-aligned")
    check_raises("plan_requant: v16 storing a dense projection as FP4 is not a format this writes",
                 lambda: mod.plan_requant("p", "s", bf16, {"dtype": "U8", "shape": [64, 64]},
                                          {"dtype": "F8_E4M3", "shape": [64, 4]}), "stored as U8")

    fp8, grid = {"dtype": "F8_E4M3", "shape": [64, 64]}, {"dtype": "U8", "shape": [64, 2]}
    check(isinstance(mod.plan_dense("p", "s", bf16, None, fp8, grid), mod.Requant),
          "plan_dense: dealignai's BF16 is re-encoded")
    check(mod.plan_dense("p", "s", fp8, grid, fp8, grid) == mod.Encoded("p"),
          "plan_dense: a projection already in v16's storage is copied (the converter's own output)")
    check_raises("plan_dense: FP8 on another scale grid is neither", lambda: mod.plan_dense(
        "p", "s", fp8, {"dtype": "U8", "shape": [64, 1]}, fp8, grid), "neither BF16")
    check_raises("plan_dense: FP8 without its scale is neither", lambda: mod.plan_dense(
        "p", "s", fp8, None, fp8, grid), "neither BF16")
    check_raises("plan_dense: an F32 projection is neither", lambda: mod.plan_dense(
        "p", "s", {"dtype": "F32", "shape": [64, 64]}, None, fp8, grid), "neither BF16")

    names = {f"{CSF_LAYER}.0.gate_proj.weight", f"{CSF_LAYER}.0.gate_proj.weight_scale",
             f"{W4A16_LAYER}.0.gate_proj.weight", f"{L}.0.self_attn.q_proj.weight",
             f"{L}.1.mlp.shared_experts.up_proj.weight"}
    decls = mod.expert_declarations(V16_LAYERS, names)
    check(decls == {CSF_LAYER: mod.CSF_DECLARATION, W4A16_LAYER: V16_LAYERS[W4A16_LAYER]},
          "expert_declarations: compressed NVFP4 (slab) where v16 compresses, v16's W4A16 where it does not")
    decls[CSF_LAYER]["group_size"] = 32
    check(mod.CSF_DECLARATION["group_size"] == 16
          and mod.expert_declarations(V16_LAYERS, names)[CSF_LAYER] == mod.CSF_DECLARATION,
          "expert_declarations: each layer gets its own copy of the declaration")
    check(mod.expert_declarations({**V16_LAYERS, CSF_LAYER: {**V16_LAYERS[CSF_LAYER], "weight_scale_encoding": "csf"}},
                                  names)[CSF_LAYER] == mod.CSF_DECLARATION,
          "expert_declarations: a base already in the slab encoding stays compressed")
    check_raises("expert_declarations: a layer v16 does not declare",
                 lambda: mod.expert_declarations({}, names), "declares no routed-expert format")
    check_raises("expert_declarations: a v16 format other than NVFP4 group 16",
                 lambda: mod.expert_declarations({**V16_LAYERS, CSF_LAYER: {"quant_algo": "MXFP8"}}, names),
                 "expected compressed NVFP4")
    check_raises("expert_declarations: plain NVFP4 (FP4 activations) is not how v16 runs experts",
                 lambda: mod.expert_declarations({**V16_LAYERS, CSF_LAYER: {"quant_algo": "NVFP4", "group_size": 16}},
                                                 names), "expected compressed NVFP4")

    check(mod.routed_experts([f"{CSF_LAYER}.10.gate_proj.weight", f"{CSF_LAYER}.2.gate_proj.weight",
                              f"{CSF_LAYER}.2.up_proj.weight", f"{W4A16_LAYER}.0.gate_proj.weight"], [CSF_LAYER])
          == [f"{CSF_LAYER}.2", f"{CSF_LAYER}.10"], "routed_experts: the given layers' experts in numeric order")

    def expert_meta(rows=64, packed=32, scale=None):
        source = {}
        for projection in mod.PROJECTIONS:
            prefix = f"e.{projection}"
            source[f"{prefix}.weight"] = {"dtype": "U8", "shape": [rows, packed]}
            source[f"{prefix}.weight_scale"] = scale or {"dtype": "F8_E4M3", "shape": [rows, 2 * packed // 16]}
            source[f"{prefix}.weight_scale_2"] = {"dtype": "F32", "shape": []}
        base = {f"e.{projection}.input_scale": {"dtype": "F32", "shape": [1]} for projection in mod.PROJECTIONS}
        return source, base

    source_meta, base_meta = expert_meta()
    mod.check_csf_expert("e", source_meta, base_meta)
    check(True, "check_csf_expert: a well-formed expert parses")
    check_raises("check_csf_expert: a scale plane that does not match the packed weight",
                 lambda: mod.check_csf_expert("e", *expert_meta(scale={"dtype": "F8_E4M3", "shape": [64, 2]})),
                 "expected E4M3")
    check_raises("check_csf_expert: rows outside whole 32-row blocks",
                 lambda: mod.check_csf_expert("e", *expert_meta(rows=48)), "slab CSF")
    check_raises("check_csf_expert: an odd scale-column count",
                 lambda: mod.check_csf_expert("e", *expert_meta(packed=8)), "slab CSF")
    check_raises("check_csf_expert: v16 lacks an input scale",
                 lambda: mod.check_csf_expert("e", source_meta, {}), "v16 e.gate_proj.input_scale")
    check_raises("check_csf_expert: a source carrying its own input scales",
                 lambda: mod.check_csf_expert("e", {**source_meta, "e.down_proj.input_scale": {"dtype": "F32",
                                                                                              "shape": []}}, base_meta),
                 "writes v16's")
    check_raises("check_csf_expert: a missing global", lambda: mod.check_csf_expert(
        "e", {k: v for k, v in source_meta.items() if k != "e.up_proj.weight_scale_2"}, base_meta), "one FP32 value")

    def kept_meta(fixed_shape=(4, 48), exceptions=None, inputs=True):
        """An expert as this tool writes it: codes, the CSF pair, a global and an input scale."""
        meta = {}
        for projection in mod.PROJECTIONS:
            prefix = f"e.{projection}"
            meta[f"{prefix}.weight"] = {"dtype": "U8", "shape": [64, 32]}
            meta[f"{prefix}.weight_scale.{mod.CSF_FIXED}"] = {"dtype": "U8", "shape": list(fixed_shape)}
            meta[f"{prefix}.weight_scale.{mod.CSF_EXCEPTIONS}"] = exceptions or {"dtype": "U32", "shape": [0]}
            meta[f"{prefix}.weight_scale_2"] = {"dtype": "F32", "shape": []}
            if inputs:
                meta[f"{prefix}.input_scale"] = {"dtype": "F32", "shape": []}
        return meta

    mod.check_kept_expert("e", kept_meta())
    check(True, "check_kept_expert: an expert in this tool's compressed form parses")
    check_raises("check_kept_expert: a fixed stream of another plane's geometry",
                 lambda: mod.check_kept_expert("e", kept_meta(fixed_shape=(4, 40))), "expected U8 [4, 48]")
    check_raises("check_kept_expert: a two-dimensional exception stream",
                 lambda: mod.check_kept_expert("e", kept_meta(exceptions={"dtype": "U32", "shape": [1, 1]})),
                 "1-D U32")
    check_raises("check_kept_expert: no input scales (this tool always writes them)",
                 lambda: mod.check_kept_expert("e", kept_meta(inputs=False)), "e.gate_proj.input_scale")
    mod.check_plain_expert("e", source_meta)
    check(True, "check_plain_expert: a released expert without v16's input scales parses (the W4A16 layer)")

    def layer(compressed, *metas, converted=False):
        merged = {f"{n}.{key[2:]}": value for n, meta in enumerate(metas) for key, value in meta.items()}
        experts = [str(n) for n in range(len(metas))]
        base = {f"{n}.{p}.input_scale": {"dtype": "F32", "shape": []} for n in experts for p in mod.PROJECTIONS}
        return mod.expert_layer("L", compressed, experts, merged, base, converted)

    check(layer(True, source_meta, source_meta) == mod.ExpertLayer("L", mod.ENCODE, 2),
          "expert_layer: released experts in a layer v16 compresses are encoded")
    check(layer(True, kept_meta(), converted=True) == mod.ExpertLayer("L", mod.KEEP, 1),
          "expert_layer: this tool's compressed experts are kept")
    check(layer(False, source_meta) == mod.ExpertLayer("L", mod.FOLD, 1),
          "expert_layer: released experts in a layer v16 keeps plain are folded in place")
    check_raises("expert_layer: kept experts from a source without this tool's receipt",
                 lambda: layer(True, kept_meta()), "nothing vouches")
    check_raises("expert_layer: a half-converted layer",
                 lambda: layer(True, source_meta, kept_meta(), converted=True), "mixes ['encode', 'keep']")
    check_raises("expert_layer: compressed scales where v16 keeps them plain",
                 lambda: layer(False, kept_meta(), converted=True), "keeps this layer's scales plain")
    check_raises("expert_layer: a declared layer the source holds no experts of",
                 lambda: mod.expert_layer("L", True, [], {}, {}, False), "holds none")
    check_raises("ExpertLayer: a work the conversion does not know",
                 lambda: mod.ExpertLayer("L", "copy", 1), "not a layer's work")

    qc = mod.quantization_config(V16_QC, {"b": {"x": 1}, "a": {"y": 2}})
    check(qc["quantized_layers"] == {"a": {"y": 2}, "b": {"x": 1}} and qc["exclude_modules"] == []
          and qc["quant_algo"] == "MIXED_PRECISION" and V16_QC["quantized_layers"] is V16_LAYERS
          and list(qc) == list(V16_QC), "quantization_config: v16's block, only the declarations replaced")
    check_raises("quantization_config: a base that is not MIXED_PRECISION",
                 lambda: mod.quantization_config(SOURCE_QC, {}), "MIXED_PRECISION")

    header = {"__metadata__": {"format": "pt"},
              "a": {"dtype": "BF16", "shape": [2, 2], "data_offsets": [0, 8]},
              "w.weight": {"dtype": "BF16", "shape": [64, 64], "data_offsets": [8, 8200]},
              "v": {"dtype": "BF16", "shape": [1], "data_offsets": [8200, 8202]},
              "z": {"dtype": "F32", "shape": [], "data_offsets": [8202, 8206]}}
    replacement = [mod.Slot("w.weight", "F8_E4M3", (64, 64), "values"), mod.Slot("w.weight_scale", "U8", (64, 2), "values")]
    slots = mod.shard_slots(header, {"w.weight": replacement}, {"v"})
    check([(s.name, s.origin) for s in slots] == [("a", "copy"), ("w.weight", "values"),
                                                   ("w.weight_scale", "values"), ("z", "copy")],
          "shard_slots: order kept, dropped tensor gone, a replaced tensor's slots in its place")
    check((slots[3].begin, slots[3].end) == (8202, 8206), "shard_slots: a copy keeps its source span")
    placed = mod.layout(slots, header["__metadata__"])
    check(placed["__metadata__"] == {"format": "pt"}
          and [placed[s.name]["data_offsets"] for s in slots] == [[0, 8], [8, 4104], [4104, 4232], [4232, 4236]]
          and placed["w.weight"]["dtype"] == "F8_E4M3" and placed["w.weight_scale"]["shape"] == [64, 2],
          "layout: back to back, F8 values one byte each, the grid's scale bytes")
    check(mod.layout([]) == {}, "layout: an empty shard has an empty header")
    empty = mod.layout([mod.Slot("x", "U32", (0,), "values"), mod.Slot("y", "U8", (4,), "values")])
    check(empty["x"]["data_offsets"] == [0, 0] and empty["y"]["data_offsets"] == [0, 4],
          "layout: an empty exception stream takes no bytes")
    check_raises("layout: a copy span that disagrees with its dtype and shape",
                 lambda: mod.layout([mod.Slot("a", "BF16", (2, 2), "copy", 0, 6)]), "is not 8 bytes")
    check_raises("nbytes: an unknown dtype", lambda: mod.nbytes("F4", [2]), "unsupported dtype")
    check(mod.nbytes("U32", [3]) == 12 and mod.nbytes("U16", [3]) == 6, "nbytes: the CSF stream dtypes")


# --- E4M3 and the fold -------------------------------------------------------------------

def test_e4m3_and_fold() -> None:
    check((mod.e4m3_value(0x38), mod.e4m3_value(0x7E), mod.e4m3_value(0x08), mod.e4m3_value(0x01))
          == (1.0, 448.0, 2.0 ** -6, 2.0 ** -9), "e4m3_value: one, the maximum, the smallest normal and subnormal")
    check(math.isnan(mod.e4m3_value(0x7F)) and math.isnan(mod.e4m3_value(0xFF))
          and math.copysign(1.0, mod.e4m3_value(0x80)) == -1.0 and mod.e4m3_value(0xB8) == -1.0,
          "e4m3_value: the two NaNs, negative zero, the sign bit")
    check(sum(not math.isnan(mod.e4m3_value(b)) for b in range(256)) == 254, "e4m3_value: 254 finite encodings")
    half = mod.shift_table(-1)
    check((half[0x38], half[0x08], half[0x02], half[0x00], half[0x80]) == (0x30, 0x04, 0x01, 0x00, 0x80),
          "shift_table: halving one, a normal into the subnormals, a subnormal, both zeros")
    check(half[0x01] == -1 and half[0x03] == -1, "shift_table: a subnormal's lost bit has no exact half")
    check(mod.shift_table(1)[0x7E] == -1 and half[0x7F] == -1, "shift_table: overflow past 448 and NaN have no image")
    check(all(t == (-1 if math.isnan(mod.e4m3_value(b)) else b) for b, t in enumerate(mod.shift_table(0))),
          "shift_table: power 0 is the identity on every finite byte")
    exact = all(t == -1 or mod.e4m3_value(t) == mod.e4m3_value(b) * 2.0 ** k
                for k in range(-4, 5) for b, t in enumerate(mod.shift_table(k)))
    check(exact, "shift_table: every mapped byte holds exactly value * 2**power, for powers -4..4")
    check(all((mod.shift_table(k)[b] == -1) == (math.isnan(v := mod.e4m3_value(b)) or abs(v * 2.0 ** k) > 448
                                                 or not any(mod.e4m3_value(c) == v * 2.0 ** k for c in range(256)))
              for k in (-2, -1, 1, 2) for b in range(256)),
          "shift_table: refuses exactly the bytes E4M3 cannot move")

    for number, (gate, up, down) in GLOBALS.items():
        fold = mod.fold_expert(gate, up, down)
        expected = {0: ("up_proj", -1, 0.75), 1: ("gate_proj", -2, 1.0), 2: (None, 0, 1.0), 3: (None, 0, 0.75)}[number]
        check((fold.halved, fold.shift, fold.ratio) == expected, f"fold_expert: fixture expert {number} is {expected}")
    fold = mod.fold_expert(1.0, 4.0, 0.5)
    check(fold.global13 == 4.0 and fold.weight_global("gate_proj") == fold.weight_global("up_proj") == 4.0
          and fold.block_shift("gate_proj") == -2 and fold.block_shift("up_proj") == 0,
          "fold_expert: a gate halved twice carries a global four times its own")
    fold = mod.fold_expert(3.0, 2.0, 0.5)
    check(fold.global13 == 3.0 and fold.global2 == mod._f32(0.5 / 0.75)
          and fold.down_input(0.03125) == mod._f32(0.03125 * 0.75) and fold.weight_global("down_proj") == fold.global2,
          "fold_expert: down's global and input scale carry the ratio")

    grid = [mod._f32(v) for v in (1e-4, 0.0371, 0.1, 0.33, 0.5, 0.75, 1.0, 1.5, 2.0, 3.6, 7.0, 1234.5)]
    for gate in grid:
        for up in grid:
            fold = mod.fold_expert(gate, up, 0.7)
            gate_factor = fold.global13 * 2.0 ** fold.block_shift("gate_proj") / gate
            up_factor = fold.global13 * 2.0 ** fold.block_shift("up_proj") / up
            if not (0.5 < fold.ratio <= 1.0 and gate_factor == 1.0 and abs(up_factor / fold.ratio - 1) < 1e-12
                    and fold.shift <= 0 and (fold.shift == 0) == (fold.halved is None)
                    and abs(fold.global2 * fold.ratio / 0.7 - 1) < 1e-6
                    and abs(fold.down_input(0.01) / fold.ratio / 0.01 - 1) < 1e-6):
                check(False, f"fold_expert: gate {gate}, up {up} -> {fold}")
            # Idempotence: the folded expert's globals (one gate/up value, down's) fold to themselves.
            again = mod.fold_expert(fold.global13, fold.global13, fold.global2)
            if (again.global13, again.global2, again.ratio, again.halved, again.shift) \
                    != (fold.global13, fold.global2, 1.0, None, 0) or again.down_input(0.01) != mod._f32(0.01):
                check(False, f"fold_expert: refolding gate {gate}, up {up} moved {again}")
    check(True, "fold_expert: over a grid of globals, gate exact, up times a ratio in (0.5, 1], down compensates, "
                "only halvings")
    check(True, "fold_expert: folding a fold's globals is the identity (a converted expert converts to itself)")
    for bad in (0.0, -1.0, math.inf, math.nan):
        check_raises(f"fold_expert: refuses a global of {bad}", lambda bad=bad: mod.fold_expert(bad, 1.0, 1.0),
                     "positive and finite")
        check_raises(f"Fold.down_input: refuses an input scale of {bad}",
                     lambda bad=bad: mod.fold_expert(1.0, 1.0, 1.0).down_input(bad), "positive and finite")


# --- slab CSF ------------------------------------------------------------------------------

def test_csf() -> None:
    rng = np.random.default_rng(5)
    for rows, columns, spread in ((32, 2, 4), (64, 128, 24), (2048, 256, 40), (4096, 128, 3)):
        plane = (rng.integers(0, spread, (rows, columns)) + rng.integers(0, 200, (rows, 1))).astype(np.uint8)
        fixed, exceptions = mod.encode_csf_slab(plane)
        check(fixed.shape == (rows // 16, 16 + 8 * columns) and fixed.dtype == np.uint8
              and exceptions.dtype == np.uint32 and np.array_equal(mod.decode_csf_slab(fixed, exceptions, rows, columns),
                                                                   plane),
              f"encode_csf_slab: a [{rows}, {columns}] plane (spread {spread}) round-trips exactly")
        positions = exceptions & 0xFFFFFF
        check(bool((np.diff(positions.astype(np.int64)) > 0).all()) and bool(
            (plane.ravel()[positions] == (exceptions >> 24)).all()),
              f"encode_csf_slab: [{rows}, {columns}] exceptions in position order, each holding its byte")
    check(mod.encode_csf_slab(np.full((32, 2), 7, np.uint8))[1].size == 0, "encode_csf_slab: a narrow row needs none")

    plane = np.zeros((32, 2), np.uint8)
    plane[0] = (0x10, 0x30)
    plane[1] = (0xFA, 0xFA)
    fixed, exceptions = mod.encode_csf_slab(plane)
    check(fixed[0, 0] == 1 and fixed[0, 16] == 15, "encode_csf_slab: the lowest base covering the most bytes")
    check(fixed[0, 1] == 235 and fixed[0, 17] == 0xFF, "encode_csf_slab: a base never passes 240 (a byte above it "
                                                       "takes code 15 from base 235)")
    check(list(exceptions) == [1 | (0x30 << 24)], "encode_csf_slab: one record, position 1, the byte in the top 8 bits")
    check(fixed[1, 0] == 0 and not fixed[1, 1:].any() and fixed.shape == (2, 32),
          "encode_csf_slab: sixteen bases then sixteen rows of packed codes per slab")
    odd = np.zeros((32, 2), np.uint8)
    odd[3] = (1, 2)
    check(mod.encode_csf_slab(odd)[0][0, 16 + 3] == 0x21, "encode_csf_slab: the even column in the low nibble")

    for bad, needle in ((np.zeros((48, 2), np.uint8), "slab CSF"), (np.zeros((32, 3), np.uint8), "slab CSF"),
                        (np.zeros((8192, 4096), np.uint8), "slab CSF"), (np.zeros((32, 2), np.int16), "uint8")):
        check_raises(f"encode_csf_slab: refuses {bad.dtype}{bad.shape}", lambda bad=bad: mod.encode_csf_slab(bad), needle)
    fixed, exceptions = mod.encode_csf_slab(plane)
    check_raises("decode_csf_slab: a fixed stream of the wrong shape",
                 lambda: mod.decode_csf_slab(fixed[:, :-1], exceptions, 32, 2), "expected uint8")
    check_raises("decode_csf_slab: an int32 exception stream",
                 lambda: mod.decode_csf_slab(fixed, exceptions.astype(np.int32), 32, 2), "uint32")
    two = np.array([5 | (9 << 24), 3 | (9 << 24)], np.uint32)
    check_raises("decode_csf_slab: unsorted positions", lambda: mod.decode_csf_slab(fixed, two, 32, 2), "sorted")
    check_raises("decode_csf_slab: a position past the plane",
                 lambda: mod.decode_csf_slab(fixed, np.array([64], np.uint32), 32, 2), "inside the plane")
    overflow = fixed.copy()
    overflow[0, 0], overflow[0, 16] = 250, 0xFF
    check_raises("decode_csf_slab: a base plus code past a byte",
                 lambda: mod.decode_csf_slab(overflow, exceptions, 32, 2), "exceeds a byte")

    halvable = np.array([[0x38, 0x08], [0x00, 0x40]] * 16, np.uint8)
    check(mod.shifted_scales(halvable, 0) is halvable and mod.shifted_scales(halvable, -1).tolist()[0] == [0x30, 0x04],
          "shifted_scales: power 0 returns the plane, -1 halves it exactly")
    check_raises("shifted_scales: names how many bytes cannot move",
                 lambda: mod.shifted_scales(np.array([[0x01, 0x7E]] * 32, np.uint8), 1, "p"),
                 "p: 32 block scales cannot move by 2**1")

    try:
        import torch
        from ignition.reference.qwen38_quant import decode_csf_slab_scales
    except ImportError:
        print("  (ignition not importable here: slab CSF is checked against its reference decoder in the image)")
        return
    for rows, columns in ((2048, 256), (4096, 128)):
        plane = (rng.integers(0, 30, (rows, columns)) + rng.integers(40, 120, (rows, 1))).astype(np.uint8)
        fixed, exceptions = mod.encode_csf_slab(plane)
        decoded = decode_csf_slab_scales(torch.from_numpy(fixed), torch.from_numpy(exceptions.astype(np.int64))
                                         .to(torch.uint32), rows=rows, columns=columns)
        check(np.array_equal(decoded.numpy(), plane),
              f"encode_csf_slab: ignition's reference decoder reads the [{rows}, {columns}] encoding back exactly")


# --- the plan --------------------------------------------------------------------------

REQUANT_PREFIXES = ["lm_head", f"{KDA}.k_proj", f"{KDA}.o_proj", f"{KDA}.q_proj", f"{KDA}.v_proj", f"{MLA}.q_b_proj"]


def test_plan(source: Path, base: Path) -> None:
    plan = mod.plan_from_disk(source, base)
    check([r.prefix for r in plan.requants] == REQUANT_PREFIXES,
          "plan: every dense projection v16 declares is re-encoded, nothing else")
    check([r.storage for r in plan.requants] == ["mx8"] * 5 + ["block8"], "plan: each in v16's storage")
    check(plan.encoded == () and plan.expert_layers == (mod.ExpertLayer(CSF_LAYER, mod.ENCODE, len(GLOBALS)),
                                                        mod.ExpertLayer(W4A16_LAYER, mod.FOLD, len(DRAFT_GLOBALS))),
          "plan: nothing already encoded; the compressed layer is encoded, the draft layer folded in place")
    check(plan.layers(mod.ENCODE) == (CSF_LAYER,) and plan.layers(mod.KEEP) == ()
          and plan.expert_count(mod.FOLD) == len(DRAFT_GLOBALS), "plan: layers and counts by work")
    check(plan.rewrite == ("model-00001-of-00005.safetensors", "model-00002-of-00005.safetensors",
                           "model-00003-of-00005.safetensors", VISION_SOURCE_SHARD), "plan: the untouched shard is reflinked")
    check(plan.emptied == (VISION_SOURCE_SHARD,), "plan: the vision-only shard is not written")
    check(len(plan.vision) == 5 and plan.drop_vision == 2
          and all(shard == "tensors/visual.safetensors" for _, shard in plan.vision),
          "plan: v16's five vision tensors replace the source's two")
    layers = plan.quantization_config["quantized_layers"]
    check(set(layers) == set(V16_LAYERS), "plan: v16's declarations, every one")
    check(layers[CSF_LAYER] == mod.CSF_DECLARATION and layers[W4A16_LAYER] == V16_LAYERS[W4A16_LAYER],
          "plan: compressed experts in the slab encoding, the draft layer's as v16 has them")
    check(all(layers[p] == V16_LAYERS[p] for p in REQUANT_PREFIXES + ["model.visual.blocks.0.attn.qkv"]),
          "plan: dense and vision declarations exactly as v16 writes them")
    as_json = plan.as_json()
    check(json.loads(json.dumps(as_json)) == as_json and as_json["requants"][0]["scale_shape"] == [16, 2],
          "plan: as_json is plain JSON, comparable with a reviewed plan file")


def test_plan_refusals(root: Path, source: Path, base: Path) -> None:
    def mutated(label, mutate, needle):
        scratch = root / "mutant"
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.copytree(source, scratch / "source")
        shutil.copytree(base, scratch / "base")
        mutate(scratch / "source", scratch / "base")
        check_raises(f"plan refuses: {label}", lambda: mod.plan_from_disk(scratch / "source", scratch / "base"), needle)

    def edit_config(path, change):
        config = json.loads(path.read_text())
        change(config)
        path.write_text(json.dumps(config))

    def declare(base_dir, prefix, declaration):
        edit_config(base_dir / "config.json",
                    lambda c: c["quantization_config"]["quantized_layers"].update({prefix: declaration}))

    def extra_vision(source_dir: Path) -> None:
        write_safetensors(source_dir / VISION_SOURCE_SHARD, source_vision(extra=True))
        index = json.loads((source_dir / mod.INDEX).read_text())
        index["weight_map"]["model.visual.extra.weight"] = VISION_SOURCE_SHARD
        (source_dir / mod.INDEX).write_text(json.dumps(index))

    mutated("an architecture that differs from v16",
            lambda s, b: edit_config(s / "config.json", lambda c: c["text_config"].update(hidden_size=128)),
            "text_config.hidden_size")
    mutated("a base that is not MIXED_PRECISION",
            lambda s, b: edit_config(b / "config.json", lambda c: c["quantization_config"].update(quant_algo="NVFP4")),
            "MIXED_PRECISION")
    mutated("a dense projection v16 declares that the source lacks",
            lambda s, b: declare(b, f"{KDA}.g_proj", MX8), "missing from the source")
    mutated("a v16 declaration over a projection v16 keeps in BF16",
            lambda s, b: declare(b, f"{KDA}.f_a_proj", MX8), "nothing to match")
    mutated("an expert layer v16 does not have",
            lambda s, b: edit_config(b / "config.json",
                                     lambda c: c["quantization_config"]["quantized_layers"].pop(W4A16_LAYER)),
            "declares no routed-expert format")
    mutated("a compressed layer whose experts v16 gives no input scales",
            lambda s, b: declare(b, W4A16_LAYER, V16_LAYERS[CSF_LAYER]), "input_scale")
    mutated("vision towers that differ", lambda s, b: extra_vision(s), "vision towers")


# --- build and verify ------------------------------------------------------------------

def patch_tensor(root: Path, shard: str, name: str, data: bytes) -> None:
    length, header = mod.dense.read_header(root / shard)
    begin, end = header[name]["data_offsets"]
    if len(data) != end - begin:
        raise ValueError("patch size")
    with (root / shard).open("r+b") as handle:
        handle.seek(8 + length + begin)
        handle.write(data)


def test_build_and_verify(root: Path, source: Path, base: Path) -> Path:
    plan_path = root / "plan.json"
    check(quiet(lambda: mod.main(["plan", "--source", str(source), "--base", str(base), "--out", str(plan_path)])) == 0,
          "main plan: exit 0")
    check(json.loads(plan_path.read_text()) == mod.plan_from_disk(source, base).as_json(), "main plan: writes the plan")

    stale = root / "stale.json"
    stale.write_text(json.dumps({**json.loads(plan_path.read_text()), "drop_vision": 99}))
    check_raises("build: a plan the checkpoints no longer produce",
                 lambda: mod.build(source, base, root / "never", stale, FakeQuantizer()), "re-plan")
    check(not (root / "never").exists(), "build: a stale plan writes nothing")
    (root / "occupied").mkdir()
    check_raises("build: an existing output directory",
                 lambda: mod.build(source, base, root / "occupied", plan_path, FakeQuantizer()), "overwrite")

    # A block scale the fold cannot move exactly is found only while writing: the build leaves nothing.
    unmovable = root / "unmovable"
    shutil.copytree(source, unmovable)
    up_plane = f"{CSF_LAYER}.0.up_proj.weight_scale"            # expert 0 halves up (c = 1.5)
    patch_tensor(unmovable, "model-00002-of-00005.safetensors", up_plane,
                 bytes([0x01]) + scale_plane(1)[1:])               # the smallest subnormal has no exact half
    unmovable_plan = root / "unmovable-plan.json"
    unmovable_plan.write_text(json.dumps(mod.plan_from_disk(unmovable, base).as_json()))
    check_raises("build: a block scale the fold cannot halve exactly",
                 lambda: mod.build(unmovable, base, root / "half", unmovable_plan, FakeQuantizer()),
                 f"{up_plane}: 1 block scales cannot move by 2**-1")
    check(not (root / "half").exists() and not mod.staging_dir(root / "half").exists(),
          "build: a refusal while writing leaves neither the output nor its staging directory")

    # A staging directory a killed run left behind is discarded, not refused.
    out, quantize = root / "out", FakeQuantizer()
    mod.staging_dir(out).mkdir()
    (mod.staging_dir(out) / "model-00001-of-00005.safetensors").write_bytes(b"torn")
    receipt = mod.build(source, base, out, plan_path, quantize)
    check(not mod.staging_dir(out).exists() and (out / mod.RECEIPT).is_file(),
          "build: publishes the output by renaming its staging directory, a killed run's leftovers discarded")
    check(sorted(quantize.calls) == sorted([(8192, (64, 64), "mx8")] * 4 + [(2048, (16, 64), "mx8"),
                                                                            (32768, (128, 128), "block8")]),
          "build: the port re-encodes each target once, from its BF16 bytes")
    check(set(receipt["requant_metrics"]) == set(REQUANT_PREFIXES)
          and receipt["requant_metrics"][f"{MLA}.q_b_proj"] == {"storage": "block8", "rel_error": 0.02,
                                                                "max_abs_error": 0.5},
          "build: the receipt records every re-encoding's error")
    check(receipt["source_marker"] == "dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 abc" and receipt["source_receipt"] is None
          and receipt["shards_rewritten"] == 3 and json.loads((out / mod.RECEIPT).read_text()) == receipt,
          "build: the receipt names the download and counts")
    experts = receipt["experts"]["encoded"]
    check(experts["experts"] == 4 and experts["halved"] == {"None": 2, "up_proj": 1, "gate_proj": 1}
          and experts["unchanged_globals"] == 1 and (experts["ratio_min"], experts["ratio_max"]) == (0.75, 1.0)
          and experts["plain_bytes"] == 4 * 3 * CSF_ROWS * 4 and experts["exceptions"] > 0,
          "build: the receipt counts the encoded experts' folds, the ratios and the CSF streams")
    draft = receipt["experts"]["folded_plain"]
    check(draft["experts"] == 2 and draft["halved"] == {"None": 1, "up_proj": 1, "gate_proj": 0}
          and draft["unchanged_globals"] == 1 and receipt["experts"]["kept"] == 0,
          "build: the receipt counts the draft layer's folds, and no kept experts")

    index = json.loads((out / mod.INDEX).read_text())
    check(set(index["weight_map"].values()) == {"model-00001-of-00005.safetensors", "model-00002-of-00005.safetensors",
                                                "model-00003-of-00005.safetensors", UNTOUCHED_SHARD, mod.VISION_SHARD},
          "build: the index names the kept shards and v16's vision")
    check(receipt["total_size"] == index["metadata"]["total_size"], "build: the receipt's size is the index's")
    check(not (out / VISION_SOURCE_SHARD).exists(), "build: the emptied shard is not written")
    _, attn = mod.dense.read_header(out / "model-00001-of-00005.safetensors")
    check(list(attn) == ["__metadata__", f"{KDA}.q_proj.weight", f"{KDA}.q_proj.weight_scale",
                         f"{KDA}.k_proj.weight", f"{KDA}.k_proj.weight_scale", f"{KDA}.v_proj.weight",
                         f"{KDA}.v_proj.weight_scale", f"{KDA}.f_a_proj.weight", f"{KDA}.o_proj.weight",
                         f"{KDA}.o_proj.weight_scale"]
          and attn["__metadata__"] == {"format": "pt"} and attn[f"{KDA}.o_proj.weight"]["dtype"] == "F8_E4M3"
          and attn[f"{KDA}.q_proj.weight_scale"] == {"dtype": "U8", "shape": [64, 2], "data_offsets": [4096, 4224]},
          "build: re-encoded weights with their scales in place, metadata kept")
    check(mod.read_tensor(out, "model-00001-of-00005.safetensors", f"{KDA}.f_a_proj.weight")
          == mod.read_tensor(source, "model-00001-of-00005.safetensors", f"{KDA}.f_a_proj.weight"),
          "build: an untouched tensor in a rewritten shard keeps its bytes")

    _, experts_header = mod.dense.read_header(out / "model-00002-of-00005.safetensors")
    first = f"{CSF_LAYER}.0.gate_proj"
    check([n for n in experts_header if n.startswith(first + ".")]
          == [f"{first}.weight", f"{first}.weight_scale.{mod.CSF_FIXED}", f"{first}.weight_scale.{mod.CSF_EXCEPTIONS}",
              f"{first}.weight_scale_2", f"{first}.input_scale"]
          and experts_header[f"{first}.weight_scale.{mod.CSF_FIXED}"]["shape"] == [CSF_ROWS // 16, 16 + 8 * 4]
          and experts_header[f"{first}.weight_scale.{mod.CSF_EXCEPTIONS}"]["dtype"] == "U32",
          "build: a compressed projection is its codes, the CSF pair, the folded global and v16's input scale")
    for number, (gate, up, down) in GLOBALS.items():
        fold = mod.fold_expert(gate, up, down)
        for projection in mod.PROJECTIONS:
            prefix = f"{CSF_LAYER}.{number}.{projection}"
            plane = mod.read_plane(source, json.loads((source / mod.INDEX).read_text())["weight_map"],
                                   f"{prefix}.weight_scale")
            fixed = mod.read_plane(out, index["weight_map"], f"{prefix}.weight_scale.{mod.CSF_FIXED}")
            exceptions = np.frombuffer(mod.read_tensor(out, "model-00002-of-00005.safetensors",
                                                       f"{prefix}.weight_scale.{mod.CSF_EXCEPTIONS}"), np.uint32)
            decoded = mod.decode_csf_slab(fixed, exceptions, *plane.shape)
            check(np.array_equal(decoded, mod.shifted_scales(plane, fold.block_shift(projection)))
                  and (fold.block_shift(projection) != 0 or np.array_equal(decoded, plane)),
                  f"build: expert {number} {projection} scales decode to the source's, moved by its fold")
            stored = struct.unpack("<f", mod.read_tensor(out, "model-00002-of-00005.safetensors",
                                                          f"{prefix}.weight_scale_2"))[0]
            given = struct.unpack("<f", mod.read_tensor(out, "model-00002-of-00005.safetensors",
                                                         f"{prefix}.input_scale"))[0]
            check(stored == fold.weight_global(projection)
                  and given == (fold.down_input(V16_INPUTS["down_proj"]) if projection == "down_proj"
                                else mod._f32(V16_INPUTS[projection])),
                  f"build: expert {number} {projection} global and input scale are the fold's")
        # The dequantized product the kernel computes: gate exact, up times the ratio, down's global undoing it.
        planes = {p: mod.e4m3_value(mod.decode_csf_slab(
            mod.read_plane(out, index["weight_map"], f"{CSF_LAYER}.{number}.{p}.weight_scale.{mod.CSF_FIXED}"),
            np.frombuffer(mod.read_tensor(out, "model-00002-of-00005.safetensors",
                                          f"{CSF_LAYER}.{number}.{p}.weight_scale.{mod.CSF_EXCEPTIONS}"), np.uint32),
            CSF_ROWS, 4)[0, 0]) for p in mod.PROJECTIONS}
        source_planes = {p: mod.e4m3_value(scale_plane(number * 3 + i)[0]) for i, p in enumerate(mod.PROJECTIONS)}
        check(planes["gate_proj"] * fold.global13 == source_planes["gate_proj"] * gate
              and abs(planes["up_proj"] * fold.global13 / (source_planes["up_proj"] * up) - fold.ratio) < 1e-12
              and abs(planes["down_proj"] * fold.global2 * fold.ratio / (source_planes["down_proj"] * down) - 1) < 1e-6,
              f"build: expert {number}'s effective scales: gate exact, up scaled by c', down compensated")
    check(not any(n.startswith(f"{W4A16_LAYER}.") and n.endswith(".input_scale") for n in index["weight_map"]),
          "build: the plain W4A16 layer gains no input scales")
    shard = "model-00002-of-00005.safetensors"
    for number, (gate, up, down) in DRAFT_GLOBALS.items():
        fold = mod.fold_expert(gate, up, down)
        globals_ = {p: struct.unpack("<f", mod.read_tensor(out, shard, f"{W4A16_LAYER}.{number}.{p}.weight_scale_2"))[0]
                    for p in mod.PROJECTIONS}
        check(globals_["gate_proj"] == globals_["up_proj"] == fold.global13 and globals_["down_proj"] == fold.global2,
              f"build: draft expert {number} has one gate/up global (the W4A16 path takes no paired gains)")
        for index_, projection in enumerate(mod.PROJECTIONS):
            name = f"{W4A16_LAYER}.{number}.{projection}.weight_scale"
            source_plane = np.frombuffer(scale_plane(50 + number * 3 + index_, DRAFT_ROWS, 2), np.uint8).reshape(DRAFT_ROWS, 2)
            check(mod.dense.read_header(out / shard)[1][name]["dtype"] == "F8_E4M3"
                  and np.array_equal(mod.read_plane(out, index["weight_map"], name),
                                     mod.shifted_scales(source_plane, fold.block_shift(projection))),
                  f"build: draft expert {number} {projection} keeps a plain plane, moved by its fold")
    up = {key: struct.unpack("<f", mod.read_tensor(root_, shard, f"{W4A16_LAYER}.0.up_proj.weight_scale_2"))[0]
               * mod.e4m3_value(mod.read_tensor(root_, shard, f"{W4A16_LAYER}.0.up_proj.weight_scale")[0])
          for key, root_ in (("out", out), ("source", source))}
    check(up["out"] / up["source"] == 0.75, "build: draft expert 0's up computes c' = 0.75 times the released one")
    check(not (out / INPUT_SCALES).exists(), "build: dealignai's placeholder input scales are not carried")
    check((out / UNTOUCHED_SHARD).read_bytes() == (source / UNTOUCHED_SHARD).read_bytes(),
          "build: an untouched shard is copied whole")
    config = json.loads((out / "config.json").read_text())
    check(config["quantization_config"] == mod.plan_from_disk(source, base).quantization_config
          and config["text_config"] == ARCH["text_config"], "build: the config carries v16's quantization block")
    check((out / "chat_template.jinja").read_bytes() == (base / "chat_template.jinja").read_bytes(),
          "build: the chat template is v16's pinned bytes, not the source's")
    check({p.name for p in out.iterdir() if p.is_file()} >= {"tokenizer.json", "chat_template.jinja", "README.md"}
          and not (out / ".download-complete").exists() and not (out / ".cache").exists(),
          "build: side files carried over, download bookkeeping left behind")

    check(quiet(lambda: mod.main(["verify", "--source", str(source), "--base", str(base), "--plan", str(plan_path),
                                  "--out", str(out)])) == 0, "verify: the built checkpoint passes")

    def mutant(label, mutate, needle=""):
        scratch = root / "verify-mutant"
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.copytree(out, scratch)
        mutate(scratch)
        check_raises(f"verify catches: {label}", lambda: mod.verify(source, base, scratch, plan_path), needle)

    def flip_last_byte(path: Path):
        data = bytearray(path.read_bytes())
        data[-1] ^= 0xFF
        path.write_bytes(bytes(data))

    def append_byte(path: Path):
        with path.open("ab") as handle:
            handle.write(b"\0")

    def rewrite_json(path: Path, change):
        value = json.loads(path.read_text())
        change(value)
        path.write_text(json.dumps(value))

    experts_shard = "model-00002-of-00005.safetensors"
    mutant("a copied tensor whose bytes changed",
           lambda d: patch_tensor(d, "model-00001-of-00005.safetensors", f"{KDA}.f_a_proj.weight", bytes(8 * 64 * 2)),
           "copied bytes differ")
    mutant("a vision tensor whose bytes changed", lambda d: flip_last_byte(d / mod.VISION_SHARD), "vision bytes")
    mutant("a shard with trailing bytes",
           lambda d: append_byte(d / "model-00003-of-00005.safetensors"), "cover the file")
    mutant("a reflinked shard that drifted", lambda d: append_byte(d / UNTOUCHED_SHARD), "")
    mutant("a wrong total_size",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["metadata"].update(total_size=1)), "total_size")
    mutant("an index that drops a shard",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["weight_map"].update(
               {"model.language_model.norm.weight": "model-00001-of-00005.safetensors",
                "model.language_model.embed_tokens.weight": "model-00001-of-00005.safetensors"})), "against the plan")
    mutant("an index pointing a tensor at the wrong shard",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["weight_map"].update(
               {f"{KDA}.f_a_proj.weight": experts_shard})), "index does not point")
    mutant("declarations that drifted from the plan",
           lambda d: rewrite_json(d / "config.json",
                                  lambda c: c["quantization_config"]["quantized_layers"].pop(W4A16_LAYER)),
           "differ from the plan")
    def plant_plain_plane(d: Path):
        """A consistent checkpoint (shard, index, total_size) that still holds a plain scale plane."""
        name = f"{CSF_LAYER}.0.gate_proj.weight_scale"
        write_safetensors(d / experts_shard, tensors_of(d, experts_shard)
                          + [tensor(name, "F8_E4M3", [CSF_ROWS, 4], scale_plane(0))], {"format": "pt"})

        def reindex(i):
            i["weight_map"][name] = experts_shard
            i["metadata"]["total_size"] += CSF_ROWS * 4

        rewrite_json(d / mod.INDEX, reindex)

    mutant("a plain scale plane left beside its CSF pair", plant_plain_plane, "beside its CSF encoding")
    mutant("a CSF code changed",
           lambda d: patch_tensor(d, experts_shard, f"{CSF_LAYER}.2.down_proj.weight_scale.{mod.CSF_FIXED}",
                                  bytes([0]) * (CSF_ROWS // 16 * (16 + 32))), "do not decode")
    mutant("a gate/up global left unfolded",
           lambda d: patch_tensor(d, experts_shard, f"{CSF_LAYER}.0.up_proj.weight_scale_2", struct.pack("<f", 2.0)),
           "folded value")
    mutant("down's input scale without the ratio",
           lambda d: patch_tensor(d, experts_shard, f"{CSF_LAYER}.0.down_proj.input_scale",
                                  struct.pack("<f", V16_INPUTS["down_proj"])), "folded value")
    mutant("the draft layer's up global left as released (the v2 export failure)",
           lambda d: patch_tensor(d, experts_shard, f"{W4A16_LAYER}.0.up_proj.weight_scale_2", struct.pack("<f", 2.0)),
           "folded value")
    mutant("the draft layer's up plane left unshifted",
           lambda d: patch_tensor(d, experts_shard, f"{W4A16_LAYER}.0.up_proj.weight_scale",
                                  scale_plane(50 + 1, DRAFT_ROWS, 2)), "moved by its fold")
    mutant("the emptied shard written after all",
           lambda d: shutil.copy(source / VISION_SOURCE_SHARD, d), "replaced vision tower")
    mutant("a missing side file", lambda d: (d / "tokenizer.json").unlink(), "tokenizer.json")
    mutant("the source's chat template instead of v16's",
           lambda d: shutil.copy(source / "chat_template.jinja", d / "chat_template.jinja"), "pinned bytes")
    check_raises("verify: a plan the checkpoints no longer produce",
                 lambda: mod.verify(source, base, out, stale), "reviewed plan")
    check(quiet(lambda: mod.main(["verify", "--source", str(source), "--base", str(base), "--plan", str(stale),
                                  "--out", str(out)])) == 1, "main: a refusal exits 1")
    return out


V1_REQUANTS = (f"{KDA}.q_proj", f"{KDA}.k_proj", f"{KDA}.v_proj", f"{MLA}.q_b_proj")


def test_v1_source_converts_like_the_download(root: Path, source: Path, base: Path, out: Path) -> None:
    """The first conversion (v1) kept every BF16 tensor and the plain experts as released, re-encoded
    only the kernel-bound projections (with the same quantizer) and took v16's vision tower. Converting
    it must give the bytes converting the download gives."""
    v1 = root / "v1"
    source_index = json.loads((source / mod.INDEX).read_text())["weight_map"]
    out_index = json.loads((out / mod.INDEX).read_text())["weight_map"]
    shards = {}
    for shard in mod.dense.index_files({"weight_map": source_index}):
        if shard == VISION_SOURCE_SHARD:
            continue
        tensors = []
        for name, dtype, shape, data in tensors_of(source, shard):
            prefix = name[: -len(".weight")]
            if prefix in V1_REQUANTS:
                tensors += [(n, *(lambda m: (m["dtype"], m["shape"]))(mod.dense.read_header(out / out_index[n])[1][n]),
                             mod.read_tensor(out, out_index[n], n)) for n in (name, f"{prefix}.weight_scale")]
            else:
                tensors.append((name, dtype, shape, data))
        shards[shard] = tensors
    shards[mod.VISION_SHARD] = tensors_of(out, mod.VISION_SHARD)
    v1_qc = {**V16_QC, "quantized_layers": {CSF_LAYER: {"quant_algo": "W4A16_NVFP4", "group_size": 16}}}
    write_checkpoint(v1, shards, ARCH | {"quantization_config": v1_qc}, metadata={"format": "pt"})
    for name in ("tokenizer.json", "README.md"):
        shutil.copy(source / name, v1 / name)
    shutil.copy(base / "chat_template.jinja", v1 / "chat_template.jinja")
    (v1 / mod.RECEIPT).write_text(json.dumps({"source_marker": "dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 abc"}))

    plan = mod.plan_from_disk(v1, base)
    check(plan.encoded == tuple(sorted(V1_REQUANTS)) and [r.prefix for r in plan.requants]
          == ["lm_head", f"{KDA}.o_proj"], "v1 plan: the kernel-bound projections are already v16's, the rest re-encode")
    plan_path = root / "v1-plan.json"
    plan_path.write_text(json.dumps(plan.as_json()))
    again, quantize = root / "out-from-v1", FakeQuantizer()
    receipt = mod.build(v1, base, again, plan_path, quantize)
    check(sorted(call[2] for call in quantize.calls) == ["mx8", "mx8"], "v1 build: only BF16 projections reach the port")
    check(receipt["source_receipt"]["source_marker"] == "dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 abc"
          and receipt["source_marker"] is None, "v1 build: the receipt chains to the download v1 came from")
    again_index = json.loads((again / mod.INDEX).read_text())
    check(again_index["weight_map"].keys() == out_index.keys()
          and all(mod.read_tensor(again, again_index["weight_map"][n], n) == mod.read_tensor(out, out_index[n], n)
                  for n in out_index),
          "v1 build: every tensor is byte-identical to the build from the download")
    check(json.loads((again / "config.json").read_text())["quantization_config"]
          == json.loads((out / "config.json").read_text())["quantization_config"],
          "v1 build: the declarations are the download build's")
    check(quiet(lambda: mod.main(["verify", "--source", str(v1), "--base", str(base), "--plan", str(plan_path),
                                  "--out", str(again)])) == 0, "v1 build: verify passes against v1")
    scratch = root / "v1-mutant"
    shutil.copytree(again, scratch)
    first = sorted(V1_REQUANTS)[0]
    patch_tensor(scratch, again_index["weight_map"][f"{first}.weight"], f"{first}.weight",
                 bytes(64 * 64))
    check_raises("verify catches: an already-encoded projection whose bytes changed",
                 lambda: mod.verify(v1, base, scratch, plan_path), "already in v16's storage")


def same_checkpoint(a: Path, b: Path) -> bool:
    """Same index (names, shards, total_size), same bytes for every tensor, same declarations."""
    index_a, index_b = (json.loads((root / mod.INDEX).read_text()) for root in (a, b))
    return (index_a == index_b
            and all(mod.read_tensor(a, shard, name) == mod.read_tensor(b, shard, name)
                    for name, shard in index_a["weight_map"].items())
            and json.loads((a / "config.json").read_text()) == json.loads((b / "config.json").read_text()))


def test_output_is_a_fixed_point(root: Path, source: Path, base: Path, out: Path) -> None:
    """Converting this tool's output again changes no byte (idempotence), and an output whose draft
    layer was left unfolded (the first v2 build, which Hyperflare refused at export) converts into
    that fixed point -- the path the real checkpoint took once its source download was gone."""
    plan = mod.plan_from_disk(out, base)
    shard = "model-00002-of-00005.safetensors"
    check(plan.requants == () and plan.encoded == tuple(sorted(REQUANT_PREFIXES))
          and plan.expert_layers == (mod.ExpertLayer(CSF_LAYER, mod.KEEP, len(GLOBALS)),
                                     mod.ExpertLayer(W4A16_LAYER, mod.FOLD, len(DRAFT_GLOBALS))),
          "fixed point plan: every dense projection already v16's, compressed experts kept, the draft layer refolded")
    check(plan.rewrite == (shard, mod.VISION_SHARD) and plan.emptied == (mod.VISION_SHARD,),
          "fixed point plan: only the draft layer's shard and the vision shard are rewritten")
    plan_path = root / "again-plan.json"
    plan_path.write_text(json.dumps(plan.as_json()))
    again, quantize = root / "again", FakeQuantizer()
    receipt = mod.build(out, base, again, plan_path, quantize)
    check(quantize.calls == [] and receipt["experts"]["kept"] == len(GLOBALS)
          and receipt["experts"]["folded_plain"]["halved"] == {"None": 2, "up_proj": 0, "gate_proj": 0}
          and receipt["experts"]["folded_plain"]["unchanged_globals"] == 2
          and receipt["source_receipt"] == json.loads((out / mod.RECEIPT).read_text()),
          "fixed point build: nothing re-encoded, every fold the identity, the receipt chains to the output")
    check(same_checkpoint(again, out), "fixed point build: every tensor, the index and the config are the output's")
    check(quiet(lambda: mod.main(["verify", "--source", str(out), "--base", str(base), "--plan", str(plan_path),
                                  "--out", str(again)])) == 0, "fixed point build: verify passes against the output")

    def copy_of(name: str, change) -> Path:
        scratch = root / name
        shutil.rmtree(scratch, ignore_errors=True)
        shutil.copytree(out, scratch)
        change(scratch)
        return scratch

    def unfold_draft(d: Path) -> None:
        for name in (f"{W4A16_LAYER}.{n}.{p}.{s}" for n in DRAFT_GLOBALS for p in mod.PROJECTIONS
                     for s in ("weight_scale", "weight_scale_2")):
            patch_tensor(d, shard, name, mod.read_tensor(source, shard, name))

    v2 = copy_of("v2", unfold_draft)
    check_raises("verify catches: the v2 output's unfolded draft layer against its own plan",
                 lambda: mod.verify(source, base, v2, root / "plan.json"), "moved by its fold")
    v2_plan = root / "v2-plan.json"
    v2_plan.write_text(json.dumps(mod.plan_from_disk(v2, base).as_json()))
    fixed = root / "from-v2"
    mod.build(v2, base, fixed, v2_plan, FakeQuantizer())
    check(same_checkpoint(fixed, out), "v2 build: converting the unfolded output gives the fixed point")
    check(quiet(lambda: mod.main(["verify", "--source", str(v2), "--base", str(base), "--plan", str(v2_plan),
                                  "--out", str(fixed)])) == 0, "v2 build: verify passes against the v2 output")

    unvouched = copy_of("unvouched", lambda d: (d / mod.RECEIPT).unlink())
    check_raises("plan refuses: kept experts from a source without this tool's receipt",
                 lambda: mod.plan_from_disk(unvouched, base), "nothing vouches")
    paired = copy_of("paired", lambda d: patch_tensor(d, shard, f"{CSF_LAYER}.0.up_proj.weight_scale_2",
                                                      struct.pack("<f", 9.0)))
    paired_plan = root / "paired-plan.json"
    paired_plan.write_text(json.dumps(mod.plan_from_disk(paired, base).as_json()))
    check_raises("build refuses: a kept expert whose gate and up globals differ",
                 lambda: mod.build(paired, base, root / "never-paired", paired_plan, FakeQuantizer()),
                 "gate and up globals differ")
    check(not (root / "never-paired").exists(), "build: a refusal from the source's values writes nothing")
    check_raises("verify catches: a kept expert's global that is not the source's",
                 lambda: mod.verify(out, base, paired, plan_path), "kept expert tensor is not the source's")
    check_raises("verify catches: a kept expert's CSF stream that is not the source's (globals still one)",
                 lambda: mod.verify(out, base, copy_of("kept-code", lambda d: patch_tensor(
                     d, shard, f"{CSF_LAYER}.1.down_proj.weight_scale.{mod.CSF_FIXED}",
                     bytes(CSF_ROWS // 16 * (16 + 32)))), plan_path), "kept expert tensor is not the source's")
    # Source and output agree byte for byte, so only the loader's invariant itself can refuse.
    check_raises("verify catches: unequal gate/up globals the source also carried",
                 lambda: mod.verify(paired, base, paired, paired_plan), "gate and up globals differ")


def test_torch_adapter() -> None:
    """The production quantizer, where the serving image provides torch."""
    try:
        import torch
    except ImportError:
        print("  (torch not importable here: the production quantizer is checked in the serving image)")
        return
    quantize = mod.torch_quantizer()
    weight = (torch.randn(128, 256, generator=torch.Generator().manual_seed(7)) * 0.02).to(torch.bfloat16)
    data = weight.view(torch.uint8).numpy().tobytes()
    values, scales, (relative, peak) = quantize(data, (128, 256), "mx8")
    check(len(values) == 128 * 256 and len(scales) == 128 * 8 and relative < 0.08 and peak > 0,
          "torch adapter: MXFP8 values, one E8M0 byte per 32 columns, small error")
    values, scales, (relative, _) = quantize(data, (128, 256), "block8")
    check(len(values) == 128 * 256 and len(scales) == 2 * 4 and relative < 0.08,
          "torch adapter: block FP8 values, one F32 scale per 128x128 block")
    decoded = torch.frombuffer(bytearray(values), dtype=torch.float8_e4m3fn).reshape(128, 256).float() \
        * torch.frombuffer(bytearray(scales), dtype=torch.float32).reshape(1, 2).repeat_interleave(128, 0) \
        .repeat_interleave(128, 1)
    check(float((decoded - weight.float()).norm() / weight.float().norm()) < 0.08,
          "torch adapter: the written bytes decode back to the source")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        source, base = build_fixture(root)
        test_pure()
        test_e4m3_and_fold()
        test_csf()
        test_plan(source, base)
        test_plan_refusals(root, source, base)
        out = test_build_and_verify(root, source, base)
        test_v1_source_converts_like_the_download(root, source, base, out)
        test_output_is_a_fixed_point(root, source, base, out)
        test_torch_adapter()
    print(f"glm53-uncensored-convert unit: {CHECKS} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
