#!/usr/bin/env python3
"""Convert dealignai's uncensored GLM-5.3-Flash NVFP4 release into a Hyperflare checkpoint.

dealignai/GLM-5.3-Flash-UNCENSORED-NVFP4 carries the refusal edit in every layer (the late-
layer-only cyber-hybrid-bf16 did not uncensor). Its routed experts are plain NVFP4 and every
other projection is BF16, declared as one modelopt NVFP4 group; Hyperflare's GLM recipe (ac9136b)
loads only modelopt MIXED_PRECISION with a per-prefix ``quantized_layers`` table. The architecture
config is otherwise identical to NVIDIA's FP4-Local (v16), which this tool uses as the reference
for every format decision:

- routed experts keep dealignai's bytes, every layer declared ``W4A16_NVFP4`` group 16. That is
  the mode the recipe runs v16's experts in on SM120 anyway (bootstrap ``expert_activation``
  auto -> a16; only v16's compressed-scale layout adds a calibrated A4 prefill). Declaring
  ``NVFP4`` would put plain experts on the FP4-activation path, which fuses gate and up under one
  global scale (``_expert_scales``) that dealignai's export does not share for most experts, so
  their block scales would have to be re-rounded; W4A16 serves the released bytes exactly and
  dealignai's calibrated input scales (model-input-scales.safetensors) go unused;
- the projections Hyperflare refuses as plain BF16 -- q/k/v of every KDA block (the side-chain
  kernel needs the MXFP8 q/k/v group) and every MLA ``q_b_proj`` (``PreparedGlmMLA`` reads
  ``.out_features``) -- are re-encoded from dealignai's BF16 into the exact format and scale grid
  v16 stores for them, and the error of each re-encoding is recorded;
- the vision tower is v16's (dealignai's card: vision is byte-identical to the base model; the
  recipe prepares every vision projection as a declared quantized linear);
- everything else stays dealignai's BF16, undeclared, which the loader serves natively.

Shards holding nothing that changes are reflinked; the rest are rewritten whole (Hyperflare
refuses a shard whose tensors leave a hole). The index, config and a receipt are written last.

    plan    compute the conversion from both checkpoints' headers and write it   (no torch)
    build   recompute the plan, require it to equal the reviewed one, write the checkpoint
            (torch: runs in the serving image)
    verify  prove the output's headers, index, config and copied bytes            (no torch)

    python3 glm53-uncensored-convert.py plan --source /models/glm53-hyperflare/sources/dealign-uncensored-nvfp4 \\
        --base /models/glm53-hyperflare/glm53-fp4-local --out /tmp/uncensored-plan.json
    docker run --rm --user 1000:1000 --entrypoint /opt/flare/.venv/bin/python3 -v /models:/models \\
        -v "$PWD":/work -v /tmp:/tmp peterstorm/glm53-hyperflare:ac9136b-cu131 \\
        /work/glm53-uncensored-convert.py build --plan /tmp/uncensored-plan.json --source ... --base ... \\
        --out /models/glm53-hyperflare/glm53-uncensored
    python3 glm53-uncensored-convert.py verify --plan /tmp/uncensored-plan.json --source ... --base ... --out ...
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Callable, Mapping


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
DTYPE_BYTES = {"BF16": 2, "F16": 2, "F32": 4, "F8_E4M3": 1, "U8": 1, "I8": 1, "I32": 4, "I64": 8}

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
                  and name not in (INDEX, "config.json", RECEIPT))


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


def requant_prefixes(names) -> set[str]:
    """The projections Hyperflare's GLM kernels refuse as plain BF16 (see glm53-bf16-dense.py)."""
    return dense.kernel_fp8_prefixes(names)


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


EXPERT_DECLARATION = {"quant_algo": "W4A16_NVFP4", "group_size": 16}


def expert_declarations(base_layers: Mapping[str, Mapping], source_names) -> dict[str, dict]:
    """Every routed-expert layer of the source as weight-only NVFP4 group 16 (see the module
    docstring), each one a layer v16 also declares as NVFP4-family group 16 experts."""
    out = {}
    expert_layers = {name.split(".mlp.experts.")[0] + ".mlp.experts"
                     for name in source_names if ".mlp.experts." in name}
    for prefix in sorted(expert_layers):
        base = base_layers.get(prefix)
        if base is None:
            raise ValueError(f"{prefix}: v16 declares no routed-expert format for this layer")
        algo = base.get("quant_algo")
        if algo not in ("NVFP4", "W4A16_NVFP4") or base.get("group_size") != 16:
            raise ValueError(f"{prefix}: v16 declares {base}, expected NVFP4 or W4A16_NVFP4 group 16")
        out[prefix] = dict(EXPERT_DECLARATION)
    return out


def quantization_config(base_qc: Mapping, declarations: Mapping[str, Mapping]) -> dict:
    """v16's modelopt MIXED_PRECISION block with this checkpoint's declarations."""
    if base_qc.get("quant_method") != "modelopt" or base_qc.get("quant_algo") != "MIXED_PRECISION":
        raise ValueError("the base checkpoint is not modelopt MIXED_PRECISION")
    out = json.loads(json.dumps(base_qc))
    out["quantized_layers"] = {prefix: dict(declarations[prefix]) for prefix in sorted(declarations)}
    return out


@dataclass(frozen=True)
class Slot:
    """One tensor in an output shard and where its bytes come from."""

    name: str
    dtype: str
    shape: tuple[int, ...]
    origin: str             # "copy" | "values" | "scale"
    begin: int = 0          # copy: data-relative offsets in the source shard
    end: int = 0


def shard_slots(header: Mapping[str, Mapping], requant_by_weight: Mapping[str, Requant],
                drop: set[str]) -> list[Slot]:
    """The rewritten shard: header order kept, dropped tensors gone, each re-encoded weight
    followed by its new scale."""
    slots = []
    for name, meta in header.items():
        if name == "__metadata__" or name in drop:
            continue
        target = requant_by_weight.get(name)
        if target is None:
            slots.append(Slot(name, meta["dtype"], tuple(meta["shape"]), "copy", *meta["data_offsets"]))
            continue
        slots.append(Slot(name, "F8_E4M3", target.shape, "values"))
        slots.append(Slot(target.scale, target.scale_dtype, target.scale_shape, "scale"))
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
    requants: tuple[Requant, ...]
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

    requants = []
    for prefix in sorted(requant_prefixes(source_index)):
        weight = f"{prefix}.weight"
        if weight not in source_meta or weight not in base_meta:
            raise ValueError(f"{prefix}: missing from the source or from v16")
        requants.append(plan_requant(prefix, source_index[weight], source_meta[weight],
                                     base_meta[weight], base_meta.get(f"{prefix}.weight_scale")))
        if base_layers.get(prefix) is None:
            raise ValueError(f"{prefix}: v16 does not declare it")

    experts = expert_declarations(base_layers, source_index)
    vision_source = {name for name in source_index if name.startswith(VISION_ROOT)}
    vision_base = sorted((name, shard) for name, shard in base_index.items() if name.startswith(VISION_ROOT))
    if {name for name, _ in vision_base if not name.endswith(("weight_scale", "weight_scale_2", "input_scale"))} \
            != {name for name in vision_source}:
        raise ValueError("the source and v16 vision towers do not hold the same tensors")
    vision_decls = {prefix: decl for prefix, decl in base_layers.items() if prefix.startswith(VISION_ROOT)}

    declarations = {**experts, **{r.prefix: base_layers[r.prefix] for r in requants}, **vision_decls}
    for name in source_index:
        if name.endswith(".weight_scale") and not name.startswith(VISION_ROOT):
            prefix = name[: -len(".weight_scale")]
            owner = prefix.split(".mlp.experts.")[0] + ".mlp.experts" if ".mlp.experts." in prefix else prefix
            if owner not in declarations:
                raise ValueError(f"{name}: a scaled source tensor with no declaration")

    rewrite = sorted({r.shard for r in requants} | {source_index[name] for name in vision_source})
    emptied = sorted(shard for shard in rewrite
                     if all(name in vision_source for name, owner in source_index.items() if owner == shard))
    return Plan(tuple(requants), tuple(rewrite), tuple(emptied), tuple(vision_base), len(vision_source),
                quantization_config(base_config["quantization_config"], declarations))


def output_files(source_index: Mapping[str, str], plan: Plan) -> list[str]:
    """The tensor files the output's index names: the source's, less the emptied, plus v16's vision."""
    return sorted((set(source_index.values()) - set(plan.emptied)) | {VISION_SHARD})


# --- I/O shell -------------------------------------------------------------------------

Quantizer = Callable[[bytes, tuple, str], tuple[bytes, bytes, tuple[float, float]]]


def read_json(path: Path):
    return json.loads(path.read_text())


def load_headers(root: Path, files) -> dict[str, dict]:
    return {name: dense.read_header(root / name)[1] for name in files}


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
    source_start = None if source_file is None else 8 + dense.read_header(source_file)[0]
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
    length, header = dense.read_header(root / shard)
    begin, end = header[name]["data_offsets"]
    with (root / shard).open("rb") as handle:
        handle.seek(8 + length + begin)
        payload = handle.read(end - begin)
    if len(payload) != end - begin:
        raise ValueError(f"{shard}: short read of {name}")
    return payload


def build(source: Path, base: Path, out: Path, plan_path: Path, quantize: Quantizer) -> dict:
    plan = plan_from_disk(source, base)
    if plan.as_json() != read_json(plan_path):
        raise ValueError(f"{plan_path}: the checkpoints no longer produce the reviewed plan; re-plan")
    if out.exists():
        raise ValueError(f"{out}: refuses to overwrite an existing directory")
    out.mkdir(parents=True)
    source_index = read_json(source / INDEX)["weight_map"]
    by_weight = {r.weight: r for r in plan.requants}
    vision = {name for name in source_index if name.startswith(VISION_ROOT)}
    metrics, written = {}, {}

    for shard in dense.index_files({"weight_map": source_index}):
        if shard in plan.emptied:
            continue
        if shard not in plan.rewrite:
            dense.ref_copy(source / shard, out / shard)
            continue
        _, header = dense.read_header(source / shard)
        targets = {name: target for name, target in by_weight.items() if source_index[name] == shard}
        slots = shard_slots(header, targets, vision)
        payloads = {}
        for target in targets.values():
            values, scales, error = quantize(read_tensor(source, shard, target.weight), target.shape, target.storage)
            payloads[target.weight], payloads[target.scale] = values, scales
            metrics[target.prefix] = {"storage": target.storage, "rel_error": error[0], "max_abs_error": error[1]}
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
    headers = load_headers(out, files)
    weight_map = {name: shard for shard in files for name in headers[shard] if name != "__metadata__"}
    (out / INDEX).write_text(json.dumps(
        {"metadata": {"total_size": dense.payload_bytes(headers.values())}, "weight_map": weight_map}, indent=2))
    config = read_json(source / "config.json")
    config["quantization_config"] = plan.quantization_config
    (out / "config.json").write_text(json.dumps(config, indent=2))
    for name in side_files(entry.name for entry in source.iterdir() if entry.is_file()):
        dense.ref_copy(source / name, out / name)
    receipt = {"source": str(source), "source_marker": (source / ".download-complete").read_text().strip()
               if (source / ".download-complete").exists() else None,
               "base": str(base), "plan": plan.as_json() | {"quantization_config": "see config.json"},
               "requant_metrics": metrics, "shards_rewritten": len(written), "vision_tensors": len(vision_slots)}
    (out / RECEIPT).write_text(json.dumps(receipt, indent=1))
    return receipt


def verify(source: Path, base: Path, out: Path, plan_path: Path) -> None:
    plan = plan_from_disk(source, base)
    if plan.as_json() != read_json(plan_path):
        raise ValueError(f"{plan_path}: the checkpoints no longer produce the reviewed plan")
    index = read_json(out / INDEX)
    files = dense.index_files(index)
    source_index = read_json(source / INDEX)["weight_map"]
    expected = output_files(source_index, plan)
    if files != expected:
        raise ValueError(f"index names files {sorted(set(files) ^ set(expected))[:3]} against the plan")
    headers = load_headers(out, files)
    for shard in files:
        end, size = 0, (out / shard).stat().st_size
        data_start = 8 + dense.read_header(out / shard)[0]
        for name, meta in sorted(((n, m) for n, m in headers[shard].items() if n != "__metadata__"),
                                 key=lambda item: item[1]["data_offsets"][0]):
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
            owner = prefix.split(".mlp.experts.")[0] + ".mlp.experts" if ".mlp.experts." in prefix else prefix
            if owner not in declared:
                raise ValueError(f"{name}: scaled but undeclared")
    for target in plan.requants:
        meta = headers[target.shard]
        if meta[target.weight]["dtype"] != "F8_E4M3" or tuple(meta[target.scale]["shape"]) != target.scale_shape:
            raise ValueError(f"{target.prefix}: not re-encoded as planned")
    requant_weights = {r.weight for r in plan.requants}
    for shard in dense.index_files({"weight_map": source_index}):
        if shard in plan.emptied:
            if shard in files or (out / shard).exists():
                raise ValueError(f"{shard}: held only the replaced vision tower, yet it was written")
            continue
        if shard in plan.rewrite:
            sample = [n for n in headers[shard] if n != "__metadata__" and n in source_index
                      and n not in requant_weights]
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
    print(f"verify OK: {len(files)} files cover their bytes, {len(plan.requants)} re-encoded, "
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
            print(f"plan: {len(plan.requants)} re-encoded, {len(plan.rewrite)} shards rewritten "
                  f"({len(plan.emptied)} emptied), "
                  f"{len(plan.vision)} vision tensors from v16 (replacing {plan.drop_vision}), "
                  f"{len(plan.quantization_config['quantized_layers'])} declarations")
        elif args.command == "build":
            receipt = build(args.source, args.base, args.out, args.plan, torch_quantizer())
            worst = max(receipt["requant_metrics"].values(), key=lambda m: m["rel_error"], default=None)
            print(f"build OK: {receipt['shards_rewritten']} shards rewritten, worst re-encoding {worst}")
        else:
            verify(args.source, args.base, args.out, args.plan)
    except (ValueError, OSError, KeyError) as error:
        print(f"error: {type(error).__name__}: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
