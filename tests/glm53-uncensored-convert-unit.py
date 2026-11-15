#!/usr/bin/env python3
"""Unit checks for glm53-uncensored-convert.py: the pure plan, the shard layout, build, verify.

Runs on a synthetic dealignai-shaped source and a v16-shaped base in a temp directory. The
quantizer port is a deterministic fake that records its calls; where torch is importable (the
serving image) the production adapter is exercised on a real BF16 tensor as well. Mutations
for verify are made on scratch copies of the built output -- never on live files.

    python3 -I tests/glm53-uncensored-convert-unit.py
    docker run --rm --user 1000:1000 --entrypoint /opt/flare/.venv/bin/python3 -v "$PWD":/work \\
        peterstorm/glm53-hyperflare:ac9136b-cu131 -I /work/tests/glm53-uncensored-convert-unit.py
"""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import math
import shutil
import sys
import tempfile
from pathlib import Path

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


def tensor(name: str, dtype: str, shape: list[int]) -> tuple:
    return (name, dtype, shape, payload(name, mod.nbytes(dtype, shape)))


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


# --- fixture -------------------------------------------------------------------------

ARCH = {"architectures": ["GlmForCausalLM"], "text_config": {"num_hidden_layers": 3, "hidden_size": 64},
        "vision_config": {"depth": 1}}
KDA = f"{L}.0.self_attn"
MLA = f"{L}.1.self_attn"
NVFP4_LAYER = f"{L}.1.mlp.experts"
W4A16_LAYER = f"{L}.2.mlp.experts"
VISION_SOURCE_SHARD = "model-00004-of-00004.safetensors"
V16_LAYERS = {
    f"{KDA}.q_proj": {"quant_algo": "MXFP8", "weight_block_size": [1, 32]},
    f"{KDA}.k_proj": {"quant_algo": "MXFP8", "weight_block_size": [1, 32]},
    f"{KDA}.v_proj": {"quant_algo": "MXFP8", "weight_block_size": [1, 32]},
    f"{KDA}.o_proj": {"quant_algo": "NVFP4", "group_size": 16},
    f"{MLA}.q_b_proj": {"quant_algo": "FP8_PB_WO", "weight_block_size": [128, 128]},
    NVFP4_LAYER: {"quant_algo": "NVFP4", "group_size": 16, "weight_scale_encoding": "csf_32x2_v1"},
    W4A16_LAYER: {"quant_algo": "W4A16_NVFP4", "group_size": 16},
    "model.visual.blocks.0.attn.qkv": {"quant_algo": "NVFP4", "group_size": 16},
}
V16_QC = {"exclude_modules": [], "quant_algo": "MIXED_PRECISION", "quant_method": "modelopt",
          "quantized_layers": V16_LAYERS}
SOURCE_QC = {"quant_method": "modelopt", "quant_algo": "NVFP4", "ignore": ["lm_head"]}


def experts(layer: str, base: bool) -> list:
    out = []
    for proj in ("gate_proj", "up_proj", "down_proj"):
        prefix = f"{layer}.0.{proj}"
        out += [tensor(f"{prefix}.weight", "U8", [32, 8]), tensor(f"{prefix}.weight_scale", "F8_E4M3", [32, 1]),
                tensor(f"{prefix}.weight_scale_2", "F32", [])]
        if base and layer == NVFP4_LAYER:
            out.append(tensor(f"{prefix}.input_scale", "F32", []))
    return out


INPUT_SCALES = "model-input-scales.safetensors"  # dealignai's calibration side file, outside the index


def input_scales(layers) -> list:
    return [tensor(f"{layer}.0.{proj}.input_scale", "F32", [])
            for layer in layers for proj in ("gate_proj", "up_proj", "down_proj")]


def source_vision(extra: bool = False) -> list:
    tensors = [tensor("model.visual.blocks.0.attn.qkv.weight", "BF16", [32, 16]),
               tensor("model.visual.patch_embed.weight", "BF16", [4, 4])]
    return tensors + ([tensor("model.visual.extra.weight", "BF16", [4, 4])] if extra else [])


def build_fixture(root: Path) -> tuple[Path, Path]:
    source, base = root / "source", root / "base"
    write_checkpoint(base, {
        "base-attn.safetensors": [
            tensor(f"{KDA}.q_proj.weight", "F8_E4M3", [64, 64]), tensor(f"{KDA}.q_proj.weight_scale", "U8", [64, 2]),
            tensor(f"{KDA}.k_proj.weight", "F8_E4M3", [64, 64]), tensor(f"{KDA}.k_proj.weight_scale", "U8", [64, 2]),
            tensor(f"{KDA}.v_proj.weight", "F8_E4M3", [64, 64]), tensor(f"{KDA}.v_proj.weight_scale", "U8", [64, 2]),
            tensor(f"{KDA}.f_a_proj.weight", "BF16", [8, 64]),
            tensor(f"{KDA}.o_proj.weight", "U8", [64, 32]), tensor(f"{KDA}.o_proj.weight_scale", "F8_E4M3", [64, 4]),
            tensor(f"{MLA}.q_b_proj.weight", "F8_E4M3", [128, 128]),
            tensor(f"{MLA}.q_b_proj.weight_scale", "F32", [1, 1, 1, 1]),
        ],
        "base-experts.safetensors": experts(NVFP4_LAYER, True) + experts(W4A16_LAYER, True),
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
        "model-00001-of-00004.safetensors": [
            tensor(f"{KDA}.q_proj.weight", "BF16", [64, 64]), tensor(f"{KDA}.k_proj.weight", "BF16", [64, 64]),
            tensor(f"{KDA}.v_proj.weight", "BF16", [64, 64]), tensor(f"{KDA}.f_a_proj.weight", "BF16", [8, 64]),
            tensor(f"{KDA}.o_proj.weight", "BF16", [64, 64]),
        ],
        "model-00002-of-00004.safetensors": [tensor(f"{MLA}.q_b_proj.weight", "BF16", [128, 128])]
        + experts(NVFP4_LAYER, False) + experts(W4A16_LAYER, False),
        "model-00003-of-00004.safetensors": [tensor("lm_head.weight", "BF16", [16, 64])],
        VISION_SOURCE_SHARD: source_vision(),
    }, ARCH | {"quantization_config": SOURCE_QC}, metadata={"format": "pt"})
    write_safetensors(source / INPUT_SCALES, input_scales([NVFP4_LAYER, W4A16_LAYER]))
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
                          "chat_template.jinja", mod.RECEIPT, "README.md"]) == ["README.md", "tokenizer.json"],
          "side_files: tensors, index, config, receipt, dot files and v16-pinned files stay behind")

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

    names = {f"{NVFP4_LAYER}.0.gate_proj.weight", f"{NVFP4_LAYER}.0.gate_proj.weight_scale",
             f"{W4A16_LAYER}.0.gate_proj.weight", f"{L}.0.self_attn.q_proj.weight"}
    w4a16 = {"quant_algo": "W4A16_NVFP4", "group_size": 16}
    check(mod.expert_declarations(V16_LAYERS, names) == {NVFP4_LAYER: w4a16, W4A16_LAYER: w4a16},
          "expert_declarations: every routed layer weight-only NVFP4 group 16, whatever v16's activation format")
    decls = mod.expert_declarations(V16_LAYERS, names)
    decls[NVFP4_LAYER]["group_size"] = 32
    check(mod.EXPERT_DECLARATION == w4a16 and mod.expert_declarations(V16_LAYERS, names)[NVFP4_LAYER] == w4a16,
          "expert_declarations: each layer gets its own copy of the declaration")
    check_raises("expert_declarations: a layer v16 does not declare",
                 lambda: mod.expert_declarations({}, names), "declares no routed-expert format")
    check_raises("expert_declarations: a v16 format other than NVFP4 group 16",
                 lambda: mod.expert_declarations({**V16_LAYERS, NVFP4_LAYER: {"quant_algo": "MXFP8"}}, names),
                 "expected NVFP4")

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
    target = mod.Requant("w", "s", (64, 64), "mx8", "U8", (64, 2))
    slots = mod.shard_slots(header, {"w.weight": target}, {"v"})
    check([(s.name, s.origin) for s in slots] == [("a", "copy"), ("w.weight", "values"),
                                                   ("w.weight_scale", "scale"), ("z", "copy")],
          "shard_slots: order kept, dropped tensor gone, the scale right after its weight")
    check((slots[3].begin, slots[3].end) == (8202, 8206), "shard_slots: a copy keeps its source span")
    placed = mod.layout(slots, header["__metadata__"])
    check(placed["__metadata__"] == {"format": "pt"}
          and [placed[s.name]["data_offsets"] for s in slots] == [[0, 8], [8, 4104], [4104, 4232], [4232, 4236]]
          and placed["w.weight"]["dtype"] == "F8_E4M3" and placed["w.weight_scale"]["shape"] == [64, 2],
          "layout: back to back, F8 values one byte each, the grid's scale bytes")
    check(mod.layout([]) == {}, "layout: an empty shard has an empty header")
    check_raises("layout: a copy span that disagrees with its dtype and shape",
                 lambda: mod.layout([mod.Slot("a", "BF16", (2, 2), "copy", 0, 6)]), "is not 8 bytes")
    check_raises("nbytes: an unknown dtype", lambda: mod.nbytes("F4", [2]), "unsupported dtype")


# --- the plan --------------------------------------------------------------------------

def test_plan(source: Path, base: Path) -> None:
    plan = mod.plan_from_disk(source, base)
    check([r.prefix for r in plan.requants] == [f"{KDA}.k_proj", f"{KDA}.q_proj", f"{KDA}.v_proj", f"{MLA}.q_b_proj"],
          "plan: KDA q/k/v and the MLA q_b_proj are re-encoded, nothing else")
    check([r.storage for r in plan.requants] == ["mx8", "mx8", "mx8", "block8"], "plan: each in v16's storage")
    check(plan.rewrite == ("model-00001-of-00004.safetensors", "model-00002-of-00004.safetensors",
                           VISION_SOURCE_SHARD), "plan: lm_head's shard is reflinked")
    check(plan.emptied == (VISION_SOURCE_SHARD,), "plan: the vision-only shard is not written")
    check(len(plan.vision) == 5 and plan.drop_vision == 2
          and all(shard == "tensors/visual.safetensors" for _, shard in plan.vision),
          "plan: v16's five vision tensors replace the source's two")
    layers = plan.quantization_config["quantized_layers"]
    check(set(layers) == set(V16_LAYERS) - {f"{KDA}.o_proj"},
          "plan: declarations cover experts, re-encoded projections and vision; o_proj is BF16, undeclared")
    check(layers[NVFP4_LAYER] == layers[W4A16_LAYER] == {"quant_algo": "W4A16_NVFP4", "group_size": 16},
          "plan: routed experts weight-only, even where v16 runs FP4 activations")
    check(layers[f"{KDA}.q_proj"] == V16_LAYERS[f"{KDA}.q_proj"]
          and layers["model.visual.blocks.0.attn.qkv"] == V16_LAYERS["model.visual.blocks.0.attn.qkv"],
          "plan: re-encoded and vision declarations exactly as v16 writes them")
    as_json = plan.as_json()
    check(json.loads(json.dumps(as_json)) == as_json and as_json["requants"][0]["scale_shape"] == [64, 2],
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
    mutated("a re-encoded projection v16 does not declare",
            lambda s, b: edit_config(b / "config.json",
                                     lambda c: c["quantization_config"]["quantized_layers"].pop(f"{MLA}.q_b_proj")),
            "does not declare")
    mutated("an expert layer v16 does not have",
            lambda s, b: edit_config(b / "config.json",
                                     lambda c: c["quantization_config"]["quantized_layers"].pop(W4A16_LAYER)),
            "declares no routed-expert format")
    mutated("vision towers that differ", lambda s, b: extra_vision(s), "vision towers")


# --- build and verify ------------------------------------------------------------------

def test_build_and_verify(root: Path, source: Path, base: Path) -> None:
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

    out, quantize = root / "out", FakeQuantizer()
    receipt = mod.build(source, base, out, plan_path, quantize)
    check(sorted(quantize.calls) == [(8192, (64, 64), "mx8")] * 3 + [(32768, (128, 128), "block8")],
          "build: the port re-encodes each target once, from its BF16 bytes")
    check(set(receipt["requant_metrics"]) == {r.prefix for r in mod.plan_from_disk(source, base).requants}
          and receipt["requant_metrics"][f"{MLA}.q_b_proj"] == {"storage": "block8", "rel_error": 0.02,
                                                                "max_abs_error": 0.5},
          "build: the receipt records every re-encoding's error")
    check(receipt["source_marker"] == "dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 abc"
          and receipt["shards_rewritten"] == 2 and json.loads((out / mod.RECEIPT).read_text()) == receipt,
          "build: the receipt names the download and counts")

    index = json.loads((out / mod.INDEX).read_text())
    check(set(index["weight_map"].values()) == {"model-00001-of-00004.safetensors", "model-00002-of-00004.safetensors",
                                                "model-00003-of-00004.safetensors", mod.VISION_SHARD},
          "build: the index names the kept shards and v16's vision")
    check(not (out / VISION_SOURCE_SHARD).exists(), "build: the emptied shard is not written")
    _, attn = mod.dense.read_header(out / "model-00001-of-00004.safetensors")
    check(list(attn) == ["__metadata__", f"{KDA}.q_proj.weight", f"{KDA}.q_proj.weight_scale",
                         f"{KDA}.k_proj.weight", f"{KDA}.k_proj.weight_scale", f"{KDA}.v_proj.weight",
                         f"{KDA}.v_proj.weight_scale", f"{KDA}.f_a_proj.weight", f"{KDA}.o_proj.weight"]
          and attn["__metadata__"] == {"format": "pt"} and attn[f"{KDA}.q_proj.weight"]["dtype"] == "F8_E4M3"
          and attn[f"{KDA}.q_proj.weight_scale"] == {"dtype": "U8", "shape": [64, 2], "data_offsets": [4096, 4224]},
          "build: re-encoded weights with their scales in place, metadata kept")
    check(mod.read_tensor(out, "model-00001-of-00004.safetensors", f"{KDA}.o_proj.weight")
          == mod.read_tensor(source, "model-00001-of-00004.safetensors", f"{KDA}.o_proj.weight"),
          "build: an untouched tensor in a rewritten shard keeps its bytes")
    check(not (out / INPUT_SCALES).exists()
          and not any(".mlp.experts." in n and n.endswith(".input_scale") for n in index["weight_map"]),
          "build: weight-only experts carry no input scales")
    check((out / "model-00003-of-00004.safetensors").read_bytes()
          == (source / "model-00003-of-00004.safetensors").read_bytes(), "build: an untouched shard is copied whole")
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

    mutant("a copied tensor whose bytes changed",
           lambda d: flip_last_byte(d / "model-00001-of-00004.safetensors"), "copied bytes differ")
    mutant("a vision tensor whose bytes changed", lambda d: flip_last_byte(d / mod.VISION_SHARD), "vision bytes")
    mutant("a shard with trailing bytes",
           lambda d: append_byte(d / "model-00002-of-00004.safetensors"), "cover the file")
    mutant("a reflinked shard that drifted",
           lambda d: append_byte(d / "model-00003-of-00004.safetensors"), "")
    mutant("a wrong total_size",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["metadata"].update(total_size=1)), "total_size")
    mutant("an index that drops a shard",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["weight_map"].update(
               {"lm_head.weight": "model-00001-of-00004.safetensors"})), "against the plan")
    mutant("an index pointing a tensor at the wrong shard",
           lambda d: rewrite_json(d / mod.INDEX, lambda i: i["weight_map"].update(
               {f"{KDA}.o_proj.weight": "model-00002-of-00004.safetensors"})), "index does not point")
    mutant("declarations that drifted from the plan",
           lambda d: rewrite_json(d / "config.json",
                                  lambda c: c["quantization_config"]["quantized_layers"].pop(W4A16_LAYER)),
           "differ from the plan")
    mutant("the emptied shard written after all",
           lambda d: shutil.copy(source / VISION_SOURCE_SHARD, d), "replaced vision tower")
    mutant("a missing side file", lambda d: (d / "tokenizer.json").unlink(), "tokenizer.json")
    mutant("the source's chat template instead of v16's",
           lambda d: shutil.copy(source / "chat_template.jinja", d / "chat_template.jinja"), "pinned bytes")
    check_raises("verify: a plan the checkpoints no longer produce",
                 lambda: mod.verify(source, base, out, stale), "reviewed plan")
    check(quiet(lambda: mod.main(["verify", "--source", str(source), "--base", str(base), "--plan", str(stale),
                                  "--out", str(out)])) == 1, "main: a refusal exits 1")


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
        test_plan(source, base)
        test_plan_refusals(root, source, base)
        test_build_and_verify(root, source, base)
        test_torch_adapter()
    print(f"glm53-uncensored-convert unit: {CHECKS} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
