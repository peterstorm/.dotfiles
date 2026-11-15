#!/usr/bin/env python3
"""Convert dealignai's uncensored GLM-5.3-Flash NVFP4 release into a Hyperflare checkpoint stored as v16 is.

dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 carries the refusal edit in every layer (the late-
layer-only cyber-hybrid-bf16 did not uncensor). Its routed experts are plain NVFP4 and every
other projection is BF16, declared as one modelopt NVFP4 group; Hyperflare's GLM recipe (ac9136b)
loads only modelopt MIXED_PRECISION with a per-prefix ``quantized_layers`` table. The architecture
config is otherwise identical to NVIDIA's FP4-Local (v16), which this tool uses as the reference
for every format decision.

The output stores every tensor the way v16 does, so it costs the GPUs what v16 costs: Hyperflare's
planner charges a checkpoint directory v16's device bytes scaled by its stored bytes
(``recipes/__init__.py`` ``_replacement``), and v16's whole KV room at TP2 (15.4 GiB, 2.24M tokens)
is about the 12 GiB a plain-format conversion adds -- the first conversion (v1: BF16 dense, plain
expert scales) was refused at export for 2.1 GiB per GPU. Per tensor:

- every dense projection v16 declares (KDA and MLA attention, the indexer, the dense and shared-
  expert MLPs, lm_head) is re-encoded from dealignai's BF16 into the FP8 storage and scale grid v16
  stores for it (MXFP8 [1,32] or block FP8 128x128), and the error of each re-encoding is recorded.
  A projection the source already stores exactly that way is copied, so this tool's earlier output
  (v1) is a complete source: its experts and BF16 tensors are dealignai's bytes and its FP8 ones
  are what this tool's re-encoding writes, so converting it gives the bytes converting the download
  gives (the unit test proves the equivalence on a fixture);
- the routed experts of every layer v16 compresses (3-44) keep dealignai's FP4 codes and block
  scales exactly, stored as v16 runs them: NVFP4 with lossless slab-CSF block scales (the encoding
  of b12x's ``encode_csf_source``, tensors ``weight_scale.nvfp4_csf_fixed``/``_exceptions``) and
  v16's calibrated input scales. That path (``_expert_scales``) needs one global for gate and up,
  which dealignai's export does not share for 8,291 of 12,096 experts. SwiGLU is linear in up, so
  up takes the gate's global and down's global divides the ratio back out: up computes ``c'`` times
  its activations, ``c' = (g_gate / g_up) * 2**m`` in (0.5, 1], the power of two applied as an exact
  halving of the up (c > 1) or gate (c <= 0.5) E4M3 block scales. Every value inside the SwiGLU
  clamp (|up| <= 10) computes as before; an up activation beyond it is clamped at 10/c' instead of
  10. dealignai's own expert input scales (model-input-scales.safetensors) are all 1.0, uncalibrated
  placeholders; v16's are used, down's multiplied by c' with its activations;
- the draft layer's experts (45) stay plain W4A16 NVFP4, as v16 declares them;
- the vision tower is v16's (dealignai's card: vision is byte-identical to the base model; the
  recipe prepares every vision projection as a declared quantized linear);
- norms, embeddings and everything else v16 stores unquantized stay as released;
- the chat template is v16's: the recipe pins it by digest and inserts its message marks at fixed
  offsets (``annotated_template_asset``), so dealignai's edited template (``clear_thinking``
  defaulting to true) would fail the export. Clients pass ``clear_thinking`` per request instead.

Shards holding nothing that changes are reflinked; the rest are rewritten whole (Hyperflare
refuses a shard whose tensors leave a hole). The index, config and a receipt are written last.

    plan    compute the conversion from both checkpoints' headers and write it      (no numpy)
    build   recompute the plan, require it to equal the reviewed one, write the checkpoint
            (torch + numpy: runs in the serving image)
    verify  prove the output against the source and v16: layout, declarations, copied bytes,
            every CSF plane decoding to its source scales, every folded scalar  (numpy: image)

    python3 glm53-uncensored-convert.py plan --source /models/glm53-hyperflare/sources/glm53-uncensored-v1 \\
        --base /models/glm53-hyperflare/glm53-fp4-local --out /tmp/uncensored-plan.json
    docker run --rm --user 1000:1000 --entrypoint /opt/flare/.venv/bin/python3 -v /models:/models \\
        -v "$PWD":/work -v /tmp:/tmp peterstorm/glm53-hyperflare:ac9136b-cu131 \\
        /work/glm53-uncensored-convert.py build --plan /tmp/uncensored-plan.json --source ... --base ... \\
        --out /models/glm53-hyperflare/glm53-uncensored
    (same docker prefix) /work/glm53-uncensored-convert.py verify --plan ... --source ... --base ... --out ...
"""

from __future__ import annotations

import argparse
import functools
import importlib.util
import json
import math
import re
import struct
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Mapping, Sequence


def _sibling(name: str, filename: str):
    """Load a sibling tool (hyphenated file names cannot be imported by name)."""
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / filename)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


hybrid = _sibling("glm_hybrid_checkpoint", "glm-hybrid-checkpoint.py")
dense = _sibling("glm53_bf16_dense", "glm53-bf16-dense.py")

INDEX = "model.safetensors.index.json"
VISION_SHARD = "tensors/visual-v16.safetensors"
VISION_ROOT = "model.visual."
RECEIPT = "convert-receipt.json"
#: Side files taken from v16 rather than the source: the recipe pins their bytes.
BASE_SIDE_FILES = ("chat_template.jinja",)
DTYPE_BYTES = {"BF16": 2, "F16": 2, "F32": 4, "F8_E4M3": 1, "U8": 1, "I8": 1, "U16": 2, "U32": 4,
               "I32": 4, "I64": 8}
SCALE_SUFFIXES = (".weight_scale", ".weight_scale_2", ".input_scale")
EXPERTS = ".mlp.experts"
PROJECTIONS = ("gate_proj", "up_proj", "down_proj")
#: v16's compressed-scale encodings; this tool writes the slab one, which the same loader path reads.
CSF_ENCODINGS = ("csf", "csf_32x2_v1")
CSF_DECLARATION = {"quant_algo": "NVFP4", "group_size": 16, "weight_scale_encoding": "csf"}
CSF_FIXED = "nvfp4_csf_fixed"
CSF_EXCEPTIONS = "nvfp4_csf_exceptions"
#: Scale bytes one 4-bit code reaches above its row's base (NVFP4's sixteen-value window).
CSF_WINDOW = 16
#: An exception record keeps its row-major position in the low 24 bits and the byte above them.
CSF_POSITION_BITS = 24

# --- pure core -----------------------------------------------------------------------


def nbytes(dtype: str, shape) -> int:
    if dtype not in DTYPE_BYTES:
        raise ValueError(f"unsupported dtype {dtype}")
    return math.prod(shape) * DTYPE_BYTES[dtype]


def side_files(names) -> list[str]:
    """Top-level source files carried over unchanged (tokenizer, chat template, processor and
    generation configs, licence, card): everything but tensors, the index, the config this tool
    rewrites, and download bookkeeping."""
    return sorted(name for name in names
                  if not name.startswith(".") and not name.endswith(".safetensors")
                  and name not in (INDEX, "config.json", RECEIPT, *BASE_SIDE_FILES))


def config_mismatches(source: Mapping, base: Mapping, path: str = "") -> list[str]:
    """Every architecture key (all but quantization_config) on which the two configs differ."""
    out = []
    for key in sorted(set(source) | set(base)):
        if key == "quantization_config":
            continue
        a, b, where = source.get(key), base.get(key), f"{path}.{key}" if path else key
        if isinstance(a, Mapping) and isinstance(b, Mapping):
            out += config_mismatches(a, b, where)
        elif a != b:
            out.append(where)
    return out


def unscaled(names) -> set[str]:
    """Tensor names without the scales a quantized format adds next to a weight."""
    return {name for name in names if not name.endswith(SCALE_SUFFIXES)}


def is_expert_layer(prefix: str) -> bool:
    return prefix.endswith(EXPERTS)


def expert_layer_of(name: str) -> str | None:
    """``…layers.N.mlp.experts`` for a routed-expert tensor, else None."""
    head, marker, _ = name.partition(EXPERTS + ".")
    return head + EXPERTS if marker else None


@dataclass(frozen=True)
class Requant:
    """One BF16 source projection re-encoded into v16's stored format for that prefix."""

    prefix: str
    shard: str
    shape: tuple[int, int]
    storage: str            # "mx8" | "block8"
    scale_dtype: str
    scale_shape: tuple[int, ...]

    @property
    def weight(self) -> str:
        return f"{self.prefix}.weight"

    @property
    def scale(self) -> str:
        return f"{self.prefix}.weight_scale"


@dataclass(frozen=True)
class Encoded:
    """A projection the source already stores exactly as v16 does: its weight and scale are copied."""

    prefix: str


def plan_requant(prefix: str, shard: str, source_meta: Mapping, base_meta: Mapping,
                 base_scale_meta: Mapping | None) -> Requant:
    """Parse one target: dealignai stores BF16, v16 stores a scaled FP8 on a grid we can write."""
    if source_meta["dtype"] != "BF16" or len(source_meta["shape"]) != 2:
        raise ValueError(f"{prefix}: source is {source_meta['dtype']}{source_meta['shape']}, expected 2-D BF16")
    if list(base_meta["shape"]) != list(source_meta["shape"]):
        raise ValueError(f"{prefix}: shape {source_meta['shape']} in the source, {base_meta['shape']} in v16")
    scale = None if base_scale_meta is None else hybrid.TensorHeader(
        "", 0, 0, base_scale_meta["dtype"], tuple(base_scale_meta["shape"]))
    storage = hybrid.storage_of(base_meta["dtype"], scale, prefix)
    if not storage.quantized:
        raise ValueError(f"{prefix}: v16 stores it as {storage.value}; nothing to match")
    shape = tuple(source_meta["shape"])
    hybrid.check_grid(storage, shape, prefix)
    expected = hybrid.expected_scale_shape(storage, shape)
    if tuple(base_scale_meta["shape"]) != expected:
        raise ValueError(f"{prefix}: v16 scale grid {base_scale_meta['shape']} is not {expected}")
    return Requant(prefix, shard, shape, storage.value, base_scale_meta["dtype"], expected)


def plan_dense(prefix: str, shard: str, source_meta: Mapping, source_scale_meta: Mapping | None,
               base_meta: Mapping, base_scale_meta: Mapping | None) -> Requant | Encoded:
    """One dense projection v16 declares: re-encode dealignai's BF16, or copy what is already v16's storage."""
    if source_meta["dtype"] == "BF16":
        return plan_requant(prefix, shard, source_meta, base_meta, base_scale_meta)

    def form(meta):
        return None if meta is None else (meta["dtype"], list(meta["shape"]))

    if source_scale_meta is not None and base_scale_meta is not None \
            and form(source_meta) == form(base_meta) and form(source_scale_meta) == form(base_scale_meta):
        return Encoded(prefix)
    raise ValueError(f"{prefix}: source stores {form(source_meta)} scaled {form(source_scale_meta)}; "
                     f"neither BF16 nor v16's {form(base_meta)} scaled {form(base_scale_meta)}")


def expert_declarations(base_layers: Mapping[str, Mapping], source_names) -> dict[str, dict]:
    """Each routed-expert layer of the source declared the way v16 runs it: compressed-scale NVFP4
    (the slab encoding this tool writes) where v16 compresses, v16's own plain W4A16 declaration
    where it does not (the draft layer)."""
    out = {}
    for prefix in sorted({layer for layer in map(expert_layer_of, source_names) if layer}):
        base = base_layers.get(prefix)
        if base is None:
            raise ValueError(f"{prefix}: v16 declares no routed-expert format for this layer")
        if base.get("weight_scale_encoding") in CSF_ENCODINGS \
                and base.get("quant_algo") == "NVFP4" and base.get("group_size") == 16:
            out[prefix] = dict(CSF_DECLARATION)
        elif dict(base) == {"quant_algo": "W4A16_NVFP4", "group_size": 16}:
            out[prefix] = dict(base)
        else:
            raise ValueError(f"{prefix}: v16 declares {dict(base)}, expected compressed NVFP4 or "
                             f"plain W4A16_NVFP4, group 16")
    return out


def csf_experts(names, csf_layers) -> list[str]:
    """Every routed expert (``…experts.N``) of the compressed layers, in name order."""
    layers = set(csf_layers)
    pattern = re.compile(r"^(.*\.mlp\.experts)\.(\d+)\.gate_proj\.weight$")
    found = [(match.group(1), int(match.group(2))) for match in map(pattern.match, names)
             if match and match.group(1) in layers]
    return [f"{layer}.{number}" for layer, number in sorted(found)]


def check_csf_expert(expert: str, source_meta: Mapping[str, Mapping], base_meta: Mapping[str, Mapping]) -> None:
    """Parse one expert the compressed path will read: FP4 codes, E4M3 block scales on a plane the
    slab encoding holds, FP32 globals in the source, and v16's FP32 input scales."""
    def scalar(meta, name):
        if meta is None or meta["dtype"] != "F32" or math.prod(meta["shape"]) != 1:
            raise ValueError(f"{name}: expected one FP32 value")

    for projection in PROJECTIONS:
        prefix = f"{expert}.{projection}"
        weight, scale = source_meta.get(f"{prefix}.weight"), source_meta.get(f"{prefix}.weight_scale")
        if weight is None or weight["dtype"] != "U8" or len(weight["shape"]) != 2:
            raise ValueError(f"{prefix}.weight: expected packed FP4 (2-D U8)")
        rows, packed = weight["shape"]
        if scale is None or scale["dtype"] != "F8_E4M3" or list(scale["shape"]) != [rows, 2 * packed // 16]:
            raise ValueError(f"{prefix}.weight_scale: expected E4M3 [{rows}, {2 * packed // 16}]")
        csf_geometry(rows, 2 * packed // 16, prefix)
        scalar(source_meta.get(f"{prefix}.weight_scale_2"), f"{prefix}.weight_scale_2")
        scalar(base_meta.get(f"{prefix}.input_scale"), f"v16 {prefix}.input_scale")
        if f"{prefix}.input_scale" in source_meta:
            raise ValueError(f"{prefix}.input_scale: the source carries one; this tool writes v16's")


def csf_geometry(rows: int, columns: int, name: str) -> None:
    """The slab encoding's limits: whole 32-row blocks, byte-paired codes, 24-bit positions."""
    if rows <= 0 or rows % 32 or columns <= 0 or columns % 2 or rows * columns > 1 << CSF_POSITION_BITS:
        raise ValueError(f"{name}: a [{rows}, {columns}] scale plane does not fit the slab CSF encoding")


def quantization_config(base_qc: Mapping, declarations: Mapping[str, Mapping]) -> dict:
    """v16's modelopt MIXED_PRECISION block with this checkpoint's declarations."""
    if base_qc.get("quant_method") != "modelopt" or base_qc.get("quant_algo") != "MIXED_PRECISION":
        raise ValueError("the base checkpoint is not modelopt MIXED_PRECISION")
    out = json.loads(json.dumps(base_qc))
    out["quantized_layers"] = {prefix: dict(declarations[prefix]) for prefix in sorted(declarations)}
    return out


# E4M3 block scales and the exact power-of-two moves the fold makes.

def e4m3_value(byte: int) -> float:
    """The value of one E4M3 (FN) byte: bias 7, three mantissa bits, subnormals, NaN at S.1111.111.
    A numpy byte is taken as a Python int first (uint8 arithmetic would wrap the exponent)."""
    byte = int(byte)
    sign = -1.0 if byte & 0x80 else 1.0
    exponent, mantissa = (byte >> 3) & 15, byte & 7
    if exponent == 15 and mantissa == 7:
        return math.nan
    if exponent == 0:
        return sign * mantissa * 2.0 ** -9
    return sign * (1 + mantissa / 8) * 2.0 ** (exponent - 7)


@functools.lru_cache(maxsize=None)
def shift_table(power: int) -> tuple[int, ...]:
    """byte -> the byte holding exactly its value times 2**power, or -1 where E4M3 cannot (a NaN,
    an overflow past 448, a bit lost below 2**-9). Signed zeros keep their sign."""
    def key(value):
        return value, math.copysign(1.0, value)

    by_value = {key(value): byte for byte in range(256) if not math.isnan(value := e4m3_value(byte))}
    return tuple(-1 if math.isnan(value := e4m3_value(byte))
                 else by_value.get(key(value * 2.0 ** power), -1) for byte in range(256))


def _f32(value: float) -> float:
    return struct.unpack("<f", struct.pack("<f", value))[0]


@dataclass(frozen=True)
class Fold:
    """One routed expert's gate and up globals made one (module docstring), every value FP32.

    Up's activations come out ``ratio`` (c', in (0.5, 1]) times the source's; down's global and input
    scale carry the ratio so down's output is unchanged. ``halved`` names the projection whose E4M3
    block scales move by ``2**shift`` (shift < 0), or is None when the globals need no power of two.
    """

    global13: float
    global2: float
    input2: float
    ratio: float
    halved: str | None
    shift: int

    def block_shift(self, projection: str) -> int:
        return self.shift if projection == self.halved else 0

    def weight_global(self, projection: str) -> float:
        return self.global2 if projection == "down_proj" else self.global13


def fold_expert(gate: float, up: float, down: float, down_input: float) -> Fold:
    """The fold for globals ``gate``/``up``/``down`` and v16's down input scale ``down_input``."""
    if not all(math.isfinite(value) and value > 0 for value in (gate, up, down, down_input)):
        raise ValueError(f"expert scales must be positive and finite: {gate}, {up}, {down}, {down_input}")
    mantissa, exponent = math.frexp(gate / up)       # gate / up = mantissa * 2**exponent, mantissa in [0.5, 1)
    power = -exponent if mantissa > 0.5 else 1 - exponent
    ratio = gate / up * 2.0 ** power
    if power < 0:
        halved, shift, global13 = "up_proj", power, gate
    elif power > 0:
        halved, shift, global13 = "gate_proj", -power, gate * 2.0 ** power
    else:
        halved, shift, global13 = None, 0, gate
    return Fold(_f32(global13), _f32(down / ratio), _f32(down_input * ratio), ratio, halved, shift)


# Slab CSF (b12x ``encode_csf_source``; ignition ``decode_csf_slab_scales``). numpy arrays in and out.

def _numpy():
    import numpy

    return numpy


def shifted_scales(plane, power: int, name: str = "scales"):
    """``plane``'s E4M3 bytes times 2**power, exactly, or a refusal naming how many cannot move."""
    if power == 0:
        return plane
    np = _numpy()
    moved = np.asarray(shift_table(power), dtype=np.int16)[plane]
    lost = int((moved < 0).sum())
    if lost:
        raise ValueError(f"{name}: {lost} block scales cannot move by 2**{power} exactly")
    return moved.astype(np.uint8)


def encode_csf_slab(plane):
    """Lossless slab CSF of one [rows, columns] E4M3 plane, byte for byte b12x's encoding.

    Each row keeps the lowest base covering the most of its bytes in a sixteen-value window; every
    16-row slab holds those sixteen bases, then each row's 4-bit codes (byte - base) in column
    order, low nibble first. A byte outside its row's window is a uint32 exception record (row-major
    position, byte << 24), in position order, its code left zero. Returns (fixed [rows/16, 16 + 8 *
    columns] uint8, exceptions [n] uint32).
    """
    np = _numpy()
    rows, columns = plane.shape
    csf_geometry(rows, columns, "plane")
    if plane.dtype != np.uint8:
        raise ValueError("CSF encodes E4M3 bytes (uint8)")
    values = plane.astype(np.int64)
    counts = np.bincount((np.arange(rows)[:, None] * 256 + values).ravel(), minlength=rows * 256)
    below = np.concatenate((np.zeros((rows, 1), np.int64), counts.reshape(rows, 256).cumsum(1)), axis=1)
    covered = below[:, CSF_WINDOW:] - below[:, :257 - CSF_WINDOW]   # bases 0..240
    bases = covered.argmax(1)                                         # first maximum: the lowest base
    delta = values - bases[:, None]
    outside = (delta < 0) | (delta >= CSF_WINDOW)
    codes = np.where(outside, 0, delta).astype(np.uint8)
    packed = codes[:, 0::2] | (codes[:, 1::2] << 4)
    fixed = np.concatenate((bases.astype(np.uint8).reshape(rows // 16, 16),
                            packed.reshape(rows // 16, 16 * columns // 2)), axis=1)
    row, column = np.nonzero(outside)
    exceptions = (row * columns + column).astype(np.uint32) | (plane[row, column].astype(np.uint32) << 24)
    return np.ascontiguousarray(fixed), exceptions.astype(np.uint32)


def decode_csf_slab(fixed, exceptions, rows: int, columns: int):
    """The [rows, columns] E4M3 plane a slab CSF pair holds; refuses a malformed pair."""
    np = _numpy()
    csf_geometry(rows, columns, "plane")
    if fixed.dtype != np.uint8 or fixed.shape != (rows // 16, 16 + 8 * columns):
        raise ValueError(f"CSF fixed stream is {fixed.dtype}{fixed.shape}, expected uint8 "
                         f"{(rows // 16, 16 + 8 * columns)}")
    if exceptions.dtype != np.uint32 or exceptions.ndim != 1:
        raise ValueError("CSF exceptions must be a one-dimensional uint32 stream")
    bases = fixed[:, :16].reshape(rows).astype(np.int64)
    pairs = fixed[:, 16:].reshape(rows, columns // 2)
    codes = np.stack((pairs & 15, pairs >> 4), axis=-1).reshape(rows, columns).astype(np.int64)
    decoded = bases[:, None] + codes
    if bool((decoded > 255).any()):
        raise ValueError("CSF base plus code exceeds a byte")
    decoded = decoded.astype(np.uint8).ravel()
    positions = (exceptions & ((1 << CSF_POSITION_BITS) - 1)).astype(np.int64)
    if positions.size and (positions[-1] >= rows * columns or bool((np.diff(positions) <= 0).any())):
        raise ValueError("CSF exception positions must be sorted, unique and inside the plane")
    decoded[positions] = (exceptions >> CSF_POSITION_BITS).astype(np.uint8)
    return decoded.reshape(rows, columns)


@dataclass(frozen=True)
class Slot:
    """One tensor in an output shard and where its bytes come from."""

    name: str
    dtype: str
    shape: tuple[int, ...]
    origin: str             # "copy" | "values"
    begin: int = 0          # copy: data-relative offsets in the source shard
    end: int = 0


def shard_slots(header: Mapping[str, Mapping], replacements: Mapping[str, Sequence[Slot]],
                drop: set[str]) -> list[Slot]:
    """The rewritten shard: header order kept, dropped tensors gone, each replaced tensor's slots
    (a re-encoded weight and its scale; a CSF pair; a folded global and its input scale) in its place."""
    slots = []
    for name, meta in header.items():
        if name == "__metadata__" or name in drop:
            continue
        if name in replacements:
            slots.extend(replacements[name])
            continue
        slots.append(Slot(name, meta["dtype"], tuple(meta["shape"]), "copy", *meta["data_offsets"]))
    return slots


def layout(slots: list[Slot], metadata: Mapping | None = None) -> dict:
    """A safetensors header placing the slots back to back (no holes, as Hyperflare requires)."""
    header: dict = {}
    if metadata:
        header["__metadata__"] = dict(metadata)
    offset = 0
    for slot in slots:
        size = nbytes(slot.dtype, slot.shape)
        if slot.origin == "copy" and slot.end - slot.begin != size:
            raise ValueError(f"{slot.name}: source span {slot.end - slot.begin} is not {size} bytes")
        header[slot.name] = {"dtype": slot.dtype, "shape": list(slot.shape), "data_offsets": [offset, offset + size]}
        offset += size
    return header


@dataclass(frozen=True)
class Plan:
    requants: tuple[Requant, ...]       # BF16 in the source, re-encoded into v16's storage
    encoded: tuple[str, ...]            # dense prefixes the source already stores as v16 does (copied)
    csf_layers: tuple[str, ...]         # routed-expert layers written with slab-CSF scales, globals folded
    csf_experts: int
    rewrite: tuple[str, ...]            # source shards rewritten (everything else is reflinked)
    emptied: tuple[str, ...]            # rewritten shards left with no tensors: not written
    vision: tuple[tuple[str, str], ...]  # (tensor, v16 shard) for the vision shard
    drop_vision: int
    quantization_config: dict

    def as_json(self) -> dict:
        """The plan as JSON values (tuples become lists), comparable to a reviewed plan file."""
        return json.loads(json.dumps(asdict(self)))


def make_plan(source_index: Mapping[str, str], source_headers: Mapping[str, Mapping], source_config: Mapping,
              base_index: Mapping[str, str], base_headers: Mapping[str, Mapping], base_config: Mapping) -> Plan:
    """The whole conversion from parsed headers. ``*_headers`` map shard -> raw header."""
    mismatched = config_mismatches(source_config, base_config)
    if mismatched:
        raise ValueError(f"source and v16 configs differ beyond quantization: {mismatched[:5]}")
    base_layers = base_config["quantization_config"]["quantized_layers"]
    source_meta = {name: source_headers[shard][name] for name, shard in source_index.items()}
    base_meta = {name: base_headers[shard][name] for name, shard in base_index.items()}

    experts = expert_declarations(base_layers, source_index)
    csf_layers = tuple(sorted(prefix for prefix, declaration in experts.items()
                              if declaration == CSF_DECLARATION))
    compressed = csf_experts(source_index, csf_layers)
    for expert in compressed:
        check_csf_expert(expert, source_meta, base_meta)

    requants, encoded = [], []
    for prefix in sorted(base_layers):
        if prefix.startswith(VISION_ROOT) or is_expert_layer(prefix):
            continue
        weight, scale = f"{prefix}.weight", f"{prefix}.weight_scale"
        if weight not in source_meta or weight not in base_meta:
            raise ValueError(f"{prefix}: v16 declares it, but it is missing from the source or from v16")
        target = plan_dense(prefix, source_index[weight], source_meta[weight], source_meta.get(scale),
                            base_meta[weight], base_meta.get(scale))
        (requants if isinstance(target, Requant) else encoded).append(target)

    vision_source = {name for name in source_index if name.startswith(VISION_ROOT)}
    vision_base = sorted((name, shard) for name, shard in base_index.items() if name.startswith(VISION_ROOT))
    if unscaled(name for name, _ in vision_base) != unscaled(vision_source):
        raise ValueError("the source and v16 vision towers do not hold the same tensors")
    vision_decls = {prefix: decl for prefix, decl in base_layers.items() if prefix.startswith(VISION_ROOT)}

    dense_decls = {prefix: base_layers[prefix] for prefix in [r.prefix for r in requants] + [e.prefix for e in encoded]}
    declarations = {**experts, **dense_decls, **vision_decls}
    for name in source_index:
        if name.endswith(".weight_scale") and not name.startswith(VISION_ROOT):
            prefix = name[: -len(".weight_scale")]
            if (expert_layer_of(prefix) or prefix) not in declarations:
                raise ValueError(f"{name}: a scaled source tensor with no declaration")

    expert_shards = {source_index[f"{expert}.{projection}.{suffix}"] for expert in compressed
                     for projection in PROJECTIONS for suffix in ("weight_scale", "weight_scale_2")}
    rewrite = sorted({r.shard for r in requants} | expert_shards | {source_index[name] for name in vision_source})
    emptied = sorted(shard for shard in rewrite
                     if all(name in vision_source for name, owner in source_index.items() if owner == shard))
    return Plan(tuple(requants), tuple(e.prefix for e in encoded), csf_layers, len(compressed),
                tuple(rewrite), tuple(emptied), tuple(vision_base), len(vision_source),
                quantization_config(base_config["quantization_config"], declarations))


def output_files(source_index: Mapping[str, str], plan: Plan) -> list[str]:
    """The tensor files the output's index names: the source's, less the emptied, plus v16's vision."""
    return sorted((set(source_index.values()) - set(plan.emptied)) | {VISION_SHARD})


# --- I/O shell -------------------------------------------------------------------------

Quantizer = Callable[[bytes, tuple, str], tuple[bytes, bytes, tuple[float, float]]]


def read_json(path: Path):
    return json.loads(path.read_text())


def _header(path: Path) -> tuple[int, dict]:
    """A shard's header, parsed once per file version: the expert passes read tens of thousands of
    tensors. Keyed by modification time and size, so a rewritten file is never answered stale."""
    status = path.stat()
    return _parsed_header(path, status.st_mtime_ns, status.st_size)


@functools.lru_cache(maxsize=None)
def _parsed_header(path: Path, mtime_ns: int, size: int) -> tuple[int, dict]:
    return dense.read_header(path)


def load_headers(root: Path, files) -> dict[str, dict]:
    return {name: _header(root / name)[1] for name in files}


def plan_from_disk(source: Path, base: Path) -> Plan:
    source_index = read_json(source / INDEX)["weight_map"]
    base_index = read_json(base / INDEX)["weight_map"]
    return make_plan(source_index, load_headers(source, set(source_index.values())), read_json(source / "config.json"),
                     base_index, load_headers(base, set(base_index.values())), read_json(base / "config.json"))


def torch_quantizer() -> Quantizer:
    """The production adapter: hybrid's quantizers on the CPU, inside the serving image."""
    torch = hybrid.import_torch()

    def quantize(payload: bytes, shape: tuple, storage: str):
        source = torch.frombuffer(bytearray(payload), dtype=torch.bfloat16).reshape(shape)
        if storage == "mx8":
            values, scales = hybrid.quantize_mx8(source, torch)
            approx = hybrid.decode_mx8(values, scales, torch)
        else:
            values, scales = hybrid.quantize_block8(source, torch)
            approx = hybrid.decode_block8(values, scales, torch)
        if not bool(torch.isfinite(approx).all()):
            raise ValueError("re-encoding produced non-finite values")
        return (hybrid._raw_bytes(values, torch), hybrid._raw_bytes(scales.contiguous(), torch),
                hybrid.requantization_error(source, approx))

    return quantize


def write_shard(path: Path, header: dict, slots: list[Slot], source_file: Path | None,
                payloads: Mapping[str, bytes]) -> None:
    """Write one shard from a layout: copied spans stream from ``source_file``, the rest from payloads."""
    path.parent.mkdir(parents=True, exist_ok=True)
    serialized = dense.serialize_header(header)
    source_start = None if source_file is None else 8 + _header(source_file)[0]
    with path.open("wb") as dst:
        dst.write(serialized)
        src = None if source_file is None else source_file.open("rb")
        try:
            for slot in slots:
                if slot.origin != "copy":
                    dst.write(payloads[slot.name])
                    continue
                src.seek(source_start + slot.begin)
                remaining = slot.end - slot.begin
                while remaining:
                    chunk = src.read(min(remaining, dense.COPY_CHUNK))
                    if not chunk:
                        raise ValueError(f"{source_file}: short read at {slot.name}")
                    dst.write(chunk)
                    remaining -= len(chunk)
        finally:
            if src is not None:
                src.close()


def read_tensor(root: Path, shard: str, name: str) -> bytes:
    length, header = _header(root / shard)
    begin, end = header[name]["data_offsets"]
    with (root / shard).open("rb") as handle:
        handle.seek(8 + length + begin)
        payload = handle.read(end - begin)
    if len(payload) != end - begin:
        raise ValueError(f"{shard}: short read of {name}")
    return payload


def read_scalar(root: Path, index: Mapping[str, str], name: str) -> float:
    payload = read_tensor(root, index[name], name)
    if len(payload) != 4:
        raise ValueError(f"{name}: expected one FP32 value, found {len(payload)} bytes")
    return struct.unpack("<f", payload)[0]


def read_plane(root: Path, index: Mapping[str, str], name: str):
    """One block-scale plane as a [rows, columns] uint8 array."""
    np = _numpy()
    rows, columns = _header(root / index[name])[1][name]["shape"]
    return np.frombuffer(read_tensor(root, index[name], name), dtype=np.uint8).reshape(rows, columns)


def expert_folds(source: Path, source_index: Mapping[str, str], base: Path, base_index: Mapping[str, str],
                 experts: Sequence[str]) -> dict[str, Fold]:
    """Every compressed expert's fold, from the source's globals and v16's down input scale."""
    return {expert: fold_expert(*(read_scalar(source, source_index, f"{expert}.{projection}.weight_scale_2")
                                  for projection in PROJECTIONS),
                                read_scalar(base, base_index, f"{expert}.down_proj.input_scale"))
            for expert in experts}


def expert_input(fold: Fold, projection: str, base: Path, base_index: Mapping[str, str], prefix: str) -> float:
    """The input scale written for one expert projection: v16's, down's carrying the fold's ratio."""
    return fold.input2 if projection == "down_proj" else read_scalar(base, base_index, f"{prefix}.input_scale")


def build(source: Path, base: Path, out: Path, plan_path: Path, quantize: Quantizer) -> dict:
    plan = plan_from_disk(source, base)
    if plan.as_json() != read_json(plan_path):
        raise ValueError(f"{plan_path}: the checkpoints no longer produce the reviewed plan; re-plan")
    if out.exists():
        raise ValueError(f"{out}: refuses to overwrite an existing directory")
    out.mkdir(parents=True)
    source_index = read_json(source / INDEX)["weight_map"]
    base_index = read_json(base / INDEX)["weight_map"]
    by_weight = {r.weight: r for r in plan.requants}
    vision = {name for name in source_index if name.startswith(VISION_ROOT)}
    experts = csf_experts(source_index, plan.csf_layers)
    folds = expert_folds(source, source_index, base, base_index, experts)
    # Each compressed projection's scale plane and global, keyed by the source tensor they replace.
    planes = {f"{expert}.{projection}.weight_scale": (expert, projection) for expert in experts for projection in PROJECTIONS}
    globals_ = {f"{expert}.{projection}.weight_scale_2": (expert, projection)
                for expert in experts for projection in PROJECTIONS}
    metrics, written, csf = {}, {}, {"exceptions": 0, "plain_bytes": 0, "csf_bytes": 0}

    for shard in dense.index_files({"weight_map": source_index}):
        if shard in plan.emptied:
            continue
        if shard not in plan.rewrite:
            dense.ref_copy(source / shard, out / shard)
            continue
        _, header = _header(source / shard)
        replacements, payloads = {}, {}
        for name in header:
            if name in by_weight:
                target = by_weight[name]
                values, scales, error = quantize(read_tensor(source, shard, name), target.shape, target.storage)
                replacements[name] = [Slot(name, "F8_E4M3", target.shape, "values"),
                                      Slot(target.scale, target.scale_dtype, target.scale_shape, "values")]
                payloads[name], payloads[target.scale] = values, scales
                metrics[target.prefix] = {"storage": target.storage, "rel_error": error[0], "max_abs_error": error[1]}
            elif name in planes:
                expert, projection = planes[name]
                plane = read_plane(source, source_index, name)
                fixed, exceptions = encode_csf_slab(
                    shifted_scales(plane, folds[expert].block_shift(projection), name))
                pair = [Slot(f"{name}.{CSF_FIXED}", "U8", fixed.shape, "values"),
                        Slot(f"{name}.{CSF_EXCEPTIONS}", "U32", exceptions.shape, "values")]
                replacements[name] = pair
                payloads[pair[0].name], payloads[pair[1].name] = fixed.tobytes(), exceptions.tobytes()
                csf["exceptions"] += int(exceptions.size)
                csf["plain_bytes"] += plane.size
                csf["csf_bytes"] += fixed.size + 4 * exceptions.size
            elif name in globals_:
                expert, projection = globals_[name]
                fold, prefix = folds[expert], f"{expert}.{projection}"
                input_meta = _header(base / base_index[f"{prefix}.input_scale"])[1][f"{prefix}.input_scale"]
                pair = [Slot(name, "F32", tuple(header[name]["shape"]), "values"),
                        Slot(f"{prefix}.input_scale", "F32", tuple(input_meta["shape"]), "values")]
                replacements[name] = pair
                payloads[name] = struct.pack("<f", fold.weight_global(projection))
                payloads[pair[1].name] = struct.pack("<f", expert_input(fold, projection, base, base_index, prefix))
        slots = shard_slots(header, replacements, vision)
        write_shard(out / shard, layout(slots, header.get("__metadata__")), slots, source / shard, payloads)
        written[shard] = len(slots)

    # v16's vision tower, as one shard of copied bytes.
    vision_slots, vision_payloads = [], {}
    for name, shard in plan.vision:
        meta = load_headers(base, [shard])[shard][name]
        vision_slots.append(Slot(name, meta["dtype"], tuple(meta["shape"]), "values"))
        vision_payloads[name] = read_tensor(base, shard, name)
    write_shard(out / VISION_SHARD, layout(vision_slots), vision_slots, None, vision_payloads)

    files = output_files(source_index, plan)
    headers = {name: dense.read_header(out / name)[1] for name in files}
    weight_map = {name: shard for shard in files for name in headers[shard] if name != "__metadata__"}
    (out / INDEX).write_text(json.dumps(
        {"metadata": {"total_size": dense.payload_bytes(headers.values())}, "weight_map": weight_map}, indent=2))
    config = read_json(source / "config.json")
    config["quantization_config"] = plan.quantization_config
    (out / "config.json").write_text(json.dumps(config, indent=2))
    for name in side_files(entry.name for entry in source.iterdir() if entry.is_file()):
        dense.ref_copy(source / name, out / name)
    for name in BASE_SIDE_FILES:
        dense.ref_copy(base / name, out / name)
    receipt = {"source": str(source), "source_marker": (source / ".download-complete").read_text().strip()
               if (source / ".download-complete").exists() else None,
               # A source that is this tool's earlier output names the download it came from.
               "source_receipt": read_json(source / RECEIPT) if (source / RECEIPT).exists() else None,
               "base": str(base), "plan": plan.as_json() | {"quantization_config": "see config.json"},
               "requant_metrics": metrics, "shards_rewritten": len(written), "vision_tensors": len(vision_slots),
               "experts": fold_summary(folds.values()) | csf,
               "total_size": dense.payload_bytes(headers.values())}
    (out / RECEIPT).write_text(json.dumps(receipt, indent=1))
    return receipt


def fold_summary(folds) -> dict:
    """How many experts needed which move, and the ratios the down globals absorb."""
    folds = list(folds)
    ratios = [fold.ratio for fold in folds]
    return {"compressed": len(folds),
            "folded": {str(halved): sum(fold.halved == halved for fold in folds) for halved in (None, "up_proj", "gate_proj")},
            "unchanged_globals": sum(fold.ratio == 1.0 and fold.halved is None for fold in folds),
            "ratio_min": min(ratios, default=None), "ratio_max": max(ratios, default=None)}


def verify(source: Path, base: Path, out: Path, plan_path: Path) -> None:
    np = _numpy()
    plan = plan_from_disk(source, base)
    if plan.as_json() != read_json(plan_path):
        raise ValueError(f"{plan_path}: the checkpoints no longer produce the reviewed plan")
    index = read_json(out / INDEX)
    files = dense.index_files(index)
    source_index = read_json(source / INDEX)["weight_map"]
    base_index = read_json(base / INDEX)["weight_map"]
    expected = output_files(source_index, plan)
    if files != expected:
        raise ValueError(f"index names files {sorted(set(files) ^ set(expected))[:3]} against the plan")
    headers = {shard: dense.read_header(out / shard)[1] for shard in files}
    for shard in files:
        end, size = 0, (out / shard).stat().st_size
        data_start = 8 + dense.read_header(out / shard)[0]
        for name, meta in sorted(((n, m) for n, m in headers[shard].items() if n != "__metadata__"),
                                 key=lambda item: (item[1]["data_offsets"][0], item[1]["data_offsets"][1])):
            begin, stop = meta["data_offsets"]
            if begin != end or stop - begin != nbytes(meta["dtype"], meta["shape"]):
                raise ValueError(f"{shard}: hole, overlap or wrong size at {name}")
            if index["weight_map"].get(name) != shard:
                raise ValueError(f"{name}: index does not point at {shard}")
            end = stop
        if data_start + end != size:
            raise ValueError(f"{shard}: tensors do not cover the file")
    if index["metadata"]["total_size"] != dense.payload_bytes(headers.values()):
        raise ValueError("index total_size is not the payload size")
    names = set(index["weight_map"])
    declared = read_json(out / "config.json")["quantization_config"]["quantized_layers"]
    if declared != plan.quantization_config["quantized_layers"]:
        raise ValueError("config.json declarations differ from the plan")
    for prefix in declared:
        if not any(n.startswith(prefix + ".") for n in names):
            raise ValueError(f"{prefix}: declared but absent")
    for name in names:
        if name.endswith(".weight_scale"):
            prefix = name[: -len(".weight_scale")]
            if (expert_layer_of(prefix) or prefix) not in declared:
                raise ValueError(f"{name}: scaled but undeclared")
    for target in plan.requants:
        meta = headers[target.shard]
        if meta[target.weight]["dtype"] != "F8_E4M3" or tuple(meta[target.scale]["shape"]) != target.scale_shape:
            raise ValueError(f"{target.prefix}: not re-encoded as planned")
    for prefix in plan.encoded:
        for name in (f"{prefix}.weight", f"{prefix}.weight_scale"):
            if read_tensor(out, index["weight_map"][name], name) != read_tensor(source, source_index[name], name):
                raise ValueError(f"{name}: already in v16's storage, yet its bytes differ from the source")

    # Every compressed expert: its planes decode to the source's scales moved by its fold, its scalars
    # are the fold's, and no plain scale plane is left beside them.
    experts = csf_experts(source_index, plan.csf_layers)
    folds = expert_folds(source, source_index, base, base_index, experts)
    for expert in experts:
        fold = folds[expert]
        for projection in PROJECTIONS:
            prefix = f"{expert}.{projection}"
            if f"{prefix}.weight_scale" in names:
                raise ValueError(f"{prefix}.weight_scale: a plain scale plane beside its CSF encoding")
            plane = read_plane(source, source_index, f"{prefix}.weight_scale")
            fixed = read_plane(out, index["weight_map"], f"{prefix}.weight_scale.{CSF_FIXED}")
            exceptions_name = f"{prefix}.weight_scale.{CSF_EXCEPTIONS}"
            exceptions = np.frombuffer(read_tensor(out, index["weight_map"][exceptions_name], exceptions_name),
                                       dtype=np.uint32)
            if not np.array_equal(decode_csf_slab(fixed, exceptions, *plane.shape),
                                  shifted_scales(plane, fold.block_shift(projection), prefix)):
                raise ValueError(f"{prefix}: CSF scales do not decode to the source's block scales")
            for name, value in ((f"{prefix}.weight_scale_2", fold.weight_global(projection)),
                                (f"{prefix}.input_scale", expert_input(fold, projection, base, base_index, prefix))):
                if read_tensor(out, index["weight_map"][name], name) != struct.pack("<f", value):
                    raise ValueError(f"{name}: not the folded value {value}")

    replaced = {r.weight for r in plan.requants} | {f"{e}.{p}.{s}" for e in experts for p in PROJECTIONS
                                                    for s in ("weight_scale", "weight_scale_2")}
    for shard in dense.index_files({"weight_map": source_index}):
        if shard in plan.emptied:
            # A source that is this tool's output keeps its vision tower at VISION_SHARD, which the
            # output reuses for v16's tower (proven tensor by tensor below).
            if shard != VISION_SHARD and (shard in files or (out / shard).exists()):
                raise ValueError(f"{shard}: held only the replaced vision tower, yet it was written")
            continue
        if shard in plan.rewrite:
            sample = [n for n in headers[shard] if n != "__metadata__" and n in source_index and n not in replaced]
            for name in {sample[0], sample[-1]} if sample else ():
                if read_tensor(out, shard, name) != read_tensor(source, shard, name):
                    raise ValueError(f"{shard}:{name}: copied bytes differ from the source")
        elif dense.read_header(out / shard)[1] != dense.read_header(source / shard)[1] \
                or (out / shard).stat().st_size != (source / shard).stat().st_size:
            raise ValueError(f"{shard}: shared shard drifted from the source")
    for name, shard in plan.vision:
        if read_tensor(out, VISION_SHARD, name) != read_tensor(base, shard, name):
            raise ValueError(f"{name}: vision bytes differ from v16")
    for name in side_files(entry.name for entry in source.iterdir() if entry.is_file()):
        if not (out / name).is_file() or (out / name).read_bytes() != (source / name).read_bytes():
            raise ValueError(f"{name}: not carried over from the source")
    for name in BASE_SIDE_FILES:
        if not (out / name).is_file() or (out / name).read_bytes() != (base / name).read_bytes():
            raise ValueError(f"{name}: not v16's pinned bytes")
    print(f"verify OK: {len(files)} files cover their bytes, {len(plan.requants)} re-encoded, "
          f"{len(plan.encoded)} already v16's, {len(experts)} experts CSF-encoded and folded, "
          f"{len(plan.vision)} vision tensors from v16, {len(declared)} declarations")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("plan", "build", "verify"):
        p = sub.add_parser(command)
        p.add_argument("--source", type=Path, required=True)
        p.add_argument("--base", type=Path, required=True)
        p.add_argument("--plan" if command != "plan" else "--out", type=Path, required=True, dest="plan")
        if command != "plan":
            p.add_argument("--out", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        if args.command == "plan":
            plan = plan_from_disk(args.source, args.base)
            args.plan.write_text(json.dumps(plan.as_json(), indent=1))
            print(f"plan: {len(plan.requants)} re-encoded, {len(plan.encoded)} already v16's, "
                  f"{plan.csf_experts} experts in {len(plan.csf_layers)} layers CSF-encoded, "
                  f"{len(plan.rewrite)} shards rewritten ({len(plan.emptied)} emptied), "
                  f"{len(plan.vision)} vision tensors from v16 (replacing {plan.drop_vision}), "
                  f"{len(plan.quantization_config['quantized_layers'])} declarations")
        elif args.command == "build":
            receipt = build(args.source, args.base, args.out, args.plan, torch_quantizer())
            worst = max(receipt["requant_metrics"].values(), key=lambda m: m["rel_error"], default=None)
            print(f"build OK: {receipt['shards_rewritten']} shards rewritten, {receipt['total_size']} bytes, "
                  f"experts {receipt['experts']}, worst re-encoding {worst}")
        else:
            verify(args.source, args.base, args.out, args.plan)
    except (ValueError, OSError, KeyError) as error:
        print(f"error: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
