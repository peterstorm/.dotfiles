#!/usr/bin/env python3
"""Build a GLM-5.3-Flash checkpoint that keeps the tune's dense weights in BF16.

The cyber-hybrid splice requantized the cybersecurity build's BF16 dense tensors into FP8
(F8_E4M3 + block scales) to match FP4-Local's storage. That requant is the one precision
loss the hybrid added over v16, and its measured error concentrates in the late layers and
``lm_head`` -- exactly where the abliteration edit carries its signal. This tool rebuilds a
checkpoint whose selected dense projections are stored as plain BF16 instead, which the
loader treats as the first-class ``bfloat16`` linear format (``linear_format`` returns it for
any prefix absent from ``quantization_config.quantized_layers`` whose weight is plain BF16
storage with no sibling scale tensor).

Because BF16 tensors are twice the size of their FP8 storage, this cannot be an in-place
patch: affected shards are rewritten, untouched tensors byte-copied, and unaffected shards
reflink-copied. The index and the quantization declaration are rewritten to match.

    plan    select requant tensors from the hybrid plan (late layers + lm_head) and verify
            every selected prefix is de-quantizable                        (no torch)
    build   range-download the source BF16 bytes, rewrite affected shards, patch the index
            and config, write the merged receipt                           (no torch)
    verify  prove headers, index, config and byte fidelity of the result   (no torch)

    python3 glm53-bf16-dense.py plan  --base /models/.../glm53-fp4-local \\
        --plan /tmp/hybrid-work/hybrid-plan-v2.json \\
        --receipt /models/.../glm53-cyber-hybrid/hybrid-receipt.json \\
        --min-layer 40 --out /tmp/hybrid-work/bf16-plan.json
    python3 glm53-bf16-dense.py build --base /models/.../glm53-fp4-local \\
        --plan-bf16 /tmp/hybrid-work/bf16-plan.json --cache /tmp/hybrid-work/bf16-cache \\
        --receipt /models/.../glm53-cyber-hybrid/hybrid-receipt.json \\
        --out /models/glm53-hyperflare/glm53-cyber-hybrid-bf16
    python3 glm53-bf16-dense.py verify --base /models/.../glm53-fp4-local \\
        --plan-bf16 /tmp/hybrid-work/bf16-plan.json --cache /tmp/hybrid-work/bf16-cache \\
        --out /models/.../glm53-cyber-hybrid-bf16
"""

from __future__ import annotations

import argparse
import json
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
from pathlib import Path

SAFETENSORS_ALIGN = 8
COPY_CHUNK = 32 * 1024 * 1024


# --- pure core: selection -----------------------------------------------------------

def layer_of(tensor: str) -> int | None:
    match = re.search(r"\.layers\.(\d+)\.", tensor)
    return int(match.group(1)) if match else None


def kda_input_prefixes(weight_names) -> set[str]:
    """q/k/v projections of every KDA attention block (a self_attn that has an f_a_proj).

    Hyperflare's KDA side-chain kernel (forced on by the recipe's export-glm-tp2.sh) groups a
    block's input projection as exactly two stored parts: MXFP8 q/k/v, then BF16 b + f_a. A
    BF16 q/k/v collapses that into one BF16 part and the export refuses the layer, so these
    prefixes stay in the hybrid's FP8 whatever the selection says.
    """
    blocks = {match.group(1) for name in weight_names
              if (match := re.fullmatch(r"(.*\.self_attn)\.f_a_proj\.weight", name))}
    return {f"{block}.{proj}" for block in blocks for proj in ("q_proj", "k_proj", "v_proj")}


def select_entries(plan: dict, receipt: dict, min_layer: int, keep_fp8: set[str]) -> list[dict]:
    """Requantized dense tensors from the late block plus the vocabulary head, except the
    prefixes that must keep their FP8 storage (keep_fp8, see kda_input_prefixes)."""
    requant = {entry["tensor"] for entry in receipt["patched"] if entry["action"] == "requant"}
    selected = []
    for entry in plan["entries"]:
        if entry["tensor"] not in requant or entry["action"] != "requant":
            continue
        if prefix_of(entry["tensor"]) in keep_fp8:
            continue
        layer = layer_of(entry["tensor"])
        if (layer is not None and layer >= min_layer) or entry["tensor"].startswith("lm_head."):
            selected.append(entry)
    return selected


def prefix_of(tensor: str) -> str:
    if not tensor.endswith(".weight"):
        raise ValueError(f"{tensor}: expected a .weight tensor")
    return tensor[: -len(".weight")]


def scale_of(prefix: str) -> str:
    return f"{prefix}.weight_scale"


def dequantizable(entry: dict, base_headers: dict[str, dict]) -> None:
    """Every selected prefix must have a scale to drop and an FP8 weight to replace."""
    prefix = prefix_of(entry["tensor"])
    if scale_of(prefix) not in base_headers:
        raise ValueError(f"{prefix}: no {scale_of(prefix)} in the base checkpoint")
    stored = base_headers[entry["tensor"]]["dtype"]
    if stored != "F8_E4M3":
        raise ValueError(f"{prefix}: base weight is {stored}, expected F8_E4M3")
    source = entry["source"]
    numel = 1
    for dim in entry["shape"]:
        numel *= dim
    if source["end"] - source["begin"] != numel * 2:
        raise ValueError(f"{prefix}: source BF16 range is {source['end'] - source['begin']} bytes, expected {numel * 2}")


# --- pure core: safetensors header surgery ------------------------------------------

def read_header(path: Path) -> tuple[int, dict]:
    with path.open("rb") as handle:
        (length,) = struct.unpack("<Q", handle.read(8))
        return length, json.loads(handle.read(length))


def rewrite_header(
    header: dict,
    replacement: dict[str, bytes],
    drop: set[str],
    data_start: int,
) -> tuple[dict, dict[str, tuple[int, int]]]:
    """Rebuild a safetensors header: replace weights, drop scales, shift everything else.

    ``data_start`` is the source file's absolute first data byte (8 + on-disk header length).
    Returns the new header (data_offsets relative to the new data section) and, per surviving
    untouched tensor, its FILE-ABSOLUTE source range to copy from. Order is preserved except
    for dropped tensors, so replacements and copies may interleave -- the writer places each
    tensor at its own new offset.
    """
    new_header: dict = {}
    if "__metadata__" in header:
        new_header["__metadata__"] = header["__metadata__"]
    offset = 0
    copy_map: dict[str, tuple[int, int]] = {}
    for name, meta in header.items():
        if name == "__metadata__":
            continue
        if name in drop:
            continue
        begin, end = meta["data_offsets"]
        size = end - begin
        if name in replacement:
            payload = replacement[name]
            new_header[name] = {"dtype": "BF16", "shape": meta["shape"],
                                "data_offsets": [offset, offset + len(payload)]}
            offset += len(payload)
            continue
        new_header[name] = {"dtype": meta["dtype"], "shape": meta["shape"],
                            "data_offsets": [offset, offset + size]}
        copy_map[name] = (data_start + begin, data_start + end)
        offset += size
    return new_header, copy_map


def serialize_header(header: dict) -> bytes:
    """JSON header padded so the data section starts on an 8-byte boundary."""
    encoded = json.dumps(header, separators=(",", ":")).encode()
    padding = (-(8 + len(encoded))) % SAFETENSORS_ALIGN
    return struct.pack("<Q", len(encoded) + padding) + encoded + b" " * padding


def index_files(index: dict) -> list[str]:
    """Every tensor file the index names, once each. Paths are relative to the checkpoint and
    may sit in subdirectories (FP4-Local keeps 214 tensors in tensors/native-QB.safetensors),
    so the index, not a top-level glob, is what says which files make the checkpoint."""
    return sorted(set(index["weight_map"].values()))


def payload_bytes(headers) -> int:
    """Sum of every tensor's data span across safetensors headers: what an index's
    metadata.total_size must equal (Hyperflare's inspect_indexed_checkpoint refuses otherwise)."""
    return sum(meta["data_offsets"][1] - meta["data_offsets"][0]
               for header in headers for name, meta in header.items() if name != "__metadata__")


def rewrite_index(index: dict, dropped: set[str], total_size: int) -> dict:
    """Forget dropped scale tensors and restate the payload size; weights keep their shard
    names, offsets live in headers. BF16 doubles each selected weight and its scale is gone,
    so the base's total_size is never the output's."""
    return {
        "metadata": {**index.get("metadata", {}), "total_size": total_size},
        "weight_map": {name: file for name, file in index["weight_map"].items() if name not in dropped},
    }


def patch_config(config: dict, prefixes: set[str]) -> dict:
    """Remove de-quantized prefixes from the modelopt declaration."""
    quant = config.get("quantization_config")
    if not isinstance(quant, dict) or not isinstance(quant.get("quantized_layers"), dict):
        raise ValueError("config.json has no quantization_config.quantized_layers to patch")
    patched = json.loads(json.dumps(config))
    layers = patched["quantization_config"]["quantized_layers"]
    for prefix in prefixes:
        if prefix not in layers:
            raise ValueError(f"{prefix}: not declared in quantized_layers")
        del layers[prefix]
    return patched


# --- I/O shell -----------------------------------------------------------------------

def _range(url: str, begin: int, end: int, timeout: int) -> bytes:
    request = urllib.request.Request(url, headers={"Range": f"bytes={begin}-{end - 1}"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def _with_retries(operation, *, attempts: int = 5, base_delay: float = 1.0):
    for attempt in range(attempts):
        try:
            return operation()
        except Exception:
            if attempt == attempts - 1:
                raise
            time.sleep(base_delay * 2**attempt)


def remote_bytes(repo: str, shard: str, begin: int, end: int) -> bytes:
    url = f"https://huggingface.co/{repo}/resolve/main/{shard}"
    payload = _with_retries(lambda: _range(url, begin, end, timeout=600))
    if len(payload) != end - begin:
        raise ValueError(f"{repo}/{shard}[{begin}:{end}]: got {len(payload)} bytes")
    return payload


def ref_copy(source: Path, target: Path) -> None:
    """Copy one file, sharing blocks where the filesystem supports it."""
    result = subprocess.run(["cp", "--reflink=auto", str(source), str(target)], check=False)
    if result.returncode != 0:
        shutil.copy2(source, target)


def cache_path(cache: Path, tensor: str) -> Path:
    return cache / (tensor + ".bf16")


def fetch_selected(plan: dict, cache: Path) -> dict[str, bytes]:
    cache.mkdir(parents=True, exist_ok=True)
    payloads: dict[str, bytes] = {}
    for entry in plan["selected"]:
        name = entry["tensor"]
        size = entry["source"]["end"] - entry["source"]["begin"]
        target = cache_path(cache, name)
        if target.exists() and target.stat().st_size == size:
            payloads[name] = target.read_bytes()
            continue
        payload = remote_bytes(plan["cyber_repo"], entry["source"]["shard"],
                               entry["source"]["begin"], entry["source"]["end"])
        target.write_bytes(payload)
        payloads[name] = payload
    return payloads


def build(base: Path, plan_path: Path, cache: Path, receipt_path: Path, out: Path) -> dict:
    plan = json.loads(plan_path.read_text())
    selected = {entry["tensor"]: entry for entry in plan["selected"]}
    prefixes = {prefix_of(name) for name in selected}
    drop = {scale_of(prefix) for prefix in prefixes}
    payloads = fetch_selected(plan, cache)
    if out.exists():
        raise ValueError(f"{out}: refuses to overwrite an existing directory")
    out.mkdir(parents=True)

    index = json.loads((base / "model.safetensors.index.json").read_text())
    weight_map = index["weight_map"]
    shards_affected: dict[str, set[str]] = {}
    for name in selected:
        shards_affected.setdefault(selected[name]["shard"], set()).add(name)
    for name in drop:
        shard = weight_map.get(name)
        if shard is None:
            raise ValueError(f"{name}: scale not in the base index")
        shards_affected.setdefault(shard, set()).add(name)

    stats = {"shards_rewritten": 0, "shards_shared": 0, "bytes_copied": 0, "bytes_written": 0}
    shards = index_files(index)
    for shard in shards:
        source_file = base / shard
        target_file = out / shard
        target_file.parent.mkdir(parents=True, exist_ok=True)
        if shard not in shards_affected:
            ref_copy(source_file, target_file)
            stats["shards_shared"] += 1
            continue
        length, header = read_header(source_file)
        replacement = {name: payloads[name] for name in shards_affected[shard]
                       if name in selected}
        new_header, copy_map = rewrite_header(header, replacement, drop, data_start=8 + length)
        with source_file.open("rb") as src, target_file.open("wb") as dst:
            serialized = serialize_header(new_header)
            dst.write(serialized)
            data_start = len(serialized)  # serialize_header already carries the 8-byte length prefix
            for name, meta in new_header.items():
                if name == "__metadata__":
                    continue
                begin, end = meta["data_offsets"]
                dst.seek(data_start + begin)
                if name in replacement:
                    dst.write(replacement[name])
                    stats["bytes_written"] += end - begin
                    continue
                src_begin, src_end = copy_map[name]
                src.seek(src_begin)
                remaining = src_end - src_begin
                while remaining:
                    chunk = src.read(min(remaining, COPY_CHUNK))
                    if not chunk:
                        raise ValueError(f"{shard}: short read at {src.tell()}")
                    dst.write(chunk)
                    remaining -= len(chunk)
                    stats["bytes_copied"] += len(chunk)
        stats["shards_rewritten"] += 1

    new_index = rewrite_index(index, drop,
                              total_size=payload_bytes(read_header(out / shard)[1] for shard in shards))
    (out / "model.safetensors.index.json").write_text(json.dumps(new_index, indent=2))
    (out / "config.json").write_text(
        json.dumps(patch_config(json.loads((base / "config.json").read_text()), prefixes), indent=2))
    # Top-level files the index does not name (tokenizer, processor config, an unindexed
    # .safetensors) come along. Directories do not: any that hold indexed shards were written
    # above, and the rest is fetch residue (e.g. a .cache/).
    for leftover in sorted(base.iterdir()):
        if leftover.name in shards or leftover.name in ("config.json", "model.safetensors.index.json"):
            continue
        if leftover.is_dir():
            continue
        if not leftover.is_file():
            raise ValueError(f"{leftover}: neither a regular file nor a directory; handle manually")
        ref_copy(leftover, out / leftover.name)
    missing = [f for f in index_files(new_index) if not (out / f).is_file()]
    if missing:
        raise ValueError(f"{out}: the index names files the build did not write: {missing}")
    receipt = json.loads(receipt_path.read_text())
    receipt["bf16"] = {"selected": len(selected), "prefixes": sorted(prefixes),
                       "min_layer": plan["min_layer"], "source_repo": plan["cyber_repo"], **stats}
    (out / "hybrid-receipt.json").write_text(json.dumps(receipt, indent=1))
    return stats


def header_len(header: dict) -> int:
    return len(serialize_header(header)) - 8


def verify(base: Path, plan_path: Path, cache: Path, out: Path) -> None:
    plan = json.loads(plan_path.read_text())
    selected = {entry["tensor"]: entry for entry in plan["selected"]}
    prefixes = {prefix_of(name) for name in selected}
    drop = {scale_of(prefix) for prefix in prefixes}
    payloads = fetch_selected(plan, cache)

    base_index = json.loads((base / "model.safetensors.index.json").read_text())
    out_index = json.loads((out / "model.safetensors.index.json").read_text())
    out_config = json.loads((out / "config.json").read_text())
    declared = out_config["quantization_config"]["quantized_layers"]

    for name in sorted(drop):
        if name in out_index["weight_map"]:
            raise ValueError(f"{name}: scale survived the rewrite")
    for prefix in sorted(prefixes):
        if prefix in declared:
            raise ValueError(f"{prefix}: still declared quantized")
    for name in selected:
        shard = out_index["weight_map"].get(name)
        if shard != selected[name]["shard"]:
            raise ValueError(f"{name}: index points at {shard}, expected {selected[name]['shard']}")

    missing = [f for f in index_files(out_index) if not (out / f).is_file()]
    if missing:
        raise ValueError(f"the output index names files that are not there: {missing}")
    payload = payload_bytes(read_header(out / shard)[1] for shard in index_files(out_index))
    if out_index.get("metadata", {}).get("total_size") != payload:
        raise ValueError(f"index total_size {out_index.get('metadata', {}).get('total_size')} "
                         f"is not the payload size {payload}")

    affected_shards = {entry["shard"] for entry in plan["selected"]}
    affected_shards |= {base_index["weight_map"][name] for name in drop
                        if name in base_index["weight_map"]}
    for shard in index_files(base_index):
        source_file = base / shard
        out_file = out / shard
        if not out_file.exists():
            raise ValueError(f"{shard}: missing from the output")
        _, out_header = read_header(out_file)
        previous_end = 0
        for name, meta in out_header.items():
            if name == "__metadata__":
                continue
            begin, end = meta["data_offsets"]
            if begin < previous_end:
                raise ValueError(f"{shard}:{name}: overlapping data_offsets")
            previous_end = end
        if shard in affected_shards:
            continue
        # shared shard: same header, same size, and its first and last tensors byte-equal
        # (both ends of the file; a full read of every 5 GB reflink is not worth its time)
        _, base_header = read_header(source_file)
        if base_header != out_header:
            raise ValueError(f"{shard}: shared shard header drifted from the base")
        if out_file.stat().st_size != source_file.stat().st_size:
            raise ValueError(f"{shard}: shared shard size drifted from the base")
        names = [name for name in out_header if name != "__metadata__"]
        for sample in {names[0], names[-1]}:
            begin, end = out_header[sample]["data_offsets"]
            with source_file.open("rb") as src, out_file.open("rb") as dst:
                dst.seek(8 + header_len(out_header) + begin)
                src.seek(8 + header_len(base_header) + begin)
                if src.read(end - begin) != dst.read(end - begin):
                    raise ValueError(f"{shard}:{sample}: shared shard bytes drifted")

    checked = 0
    for name, entry in selected.items():
        shard = out_index["weight_map"][name]
        _, header = read_header(out / shard)
        meta = header[name]
        if meta["dtype"] != "BF16":
            raise ValueError(f"{name}: stored as {meta['dtype']}, expected BF16")
        if meta["shape"] != entry["shape"]:
            raise ValueError(f"{name}: shape drifted")
        begin, end = meta["data_offsets"]
        with (out / shard).open("rb") as handle:
            handle.seek(8 + header_len(header) + begin)
            stored = handle.read(end - begin)
        if stored != payloads[name]:
            raise ValueError(f"{name}: stored BF16 bytes differ from the source")
        checked += end - begin
    print(f"verify OK: {len(selected)} BF16 weights ({checked} bytes exact), "
          f"{len(prefixes)} prefixes de-quantized, {len(drop)} scales dropped")


def cmd_plan(args: argparse.Namespace) -> int:
    plan = json.loads(Path(args.plan).read_text())
    receipt = json.loads(Path(args.receipt).read_text())
    index = json.loads((Path(args.base) / "model.safetensors.index.json").read_text())
    base_headers: dict[str, dict] = {}
    for shard in sorted(set(index["weight_map"].values())):
        _, header = read_header(Path(args.base) / shard)
        base_headers.update({name: meta for name, meta in header.items() if name != "__metadata__"})
    declared = json.loads((Path(args.base) / "config.json").read_text())[
        "quantization_config"]["quantized_layers"]
    keep_fp8 = kda_input_prefixes(index["weight_map"])
    selected = select_entries(plan, receipt, args.min_layer, keep_fp8)
    kept = sorted({prefix_of(e["tensor"]) for e in select_entries(plan, receipt, args.min_layer, set())}
                  & keep_fp8)
    if not selected:
        raise ValueError("selection is empty; check --min-layer against the receipt")
    for entry in selected:
        dequantizable(entry, base_headers)
        if prefix_of(entry["tensor"]) not in declared:
            raise ValueError(f"{prefix_of(entry['tensor'])}: not declared in quantized_layers")
    Path(args.out).write_text(json.dumps({
        "base_repo": plan["base_repo"],
        "cyber_repo": plan["cyber_repo"],
        "min_layer": args.min_layer,
        "kept_fp8": kept,
        "selected": [
            {"tensor": e["tensor"], "shard": e["shard"], "shape": e["shape"],
             "storage": e["storage"],
             "source": {"shard": e["source"]["shard"], "begin": e["source"]["begin"],
                        "end": e["source"]["end"], "dtype": e["source"]["dtype"]}}
            for e in selected
        ],
    }, indent=1))
    late = sum(1 for e in selected if layer_of(e["tensor"]) is not None)
    print(f"plan: {len(selected)} tensors ({late} late >= layer {args.min_layer}, "
          f"{len(selected) - late} lm_head), {len({prefix_of(e['tensor']) for e in selected})} prefixes; "
          f"{len(kept)} KDA q/k/v kept FP8")
    return 0


def cmd_build(args: argparse.Namespace) -> int:
    stats = build(Path(args.base), Path(args.plan_bf16), Path(args.cache),
                  Path(args.receipt), Path(args.out))
    print(f"build OK: {stats['shards_rewritten']} shards rewritten, "
          f"{stats['shards_shared']} shared, {stats['bytes_written']} BF16 bytes written, "
          f"{stats['bytes_copied']} bytes copied")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    verify(Path(args.base), Path(args.plan_bf16), Path(args.cache), Path(args.out))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    sub = parser.add_subparsers(dest="command", required=True)

    p_plan = sub.add_parser("plan")
    p_plan.add_argument("--base", required=True)
    p_plan.add_argument("--plan", required=True, help="hybrid-plan.json from the splice")
    p_plan.add_argument("--receipt", required=True, help="hybrid-receipt.json from the splice")
    p_plan.add_argument("--min-layer", type=int, default=40)
    p_plan.add_argument("--out", required=True)
    p_plan.set_defaults(function=cmd_plan)

    p_build = sub.add_parser("build")
    p_build.add_argument("--base", required=True)
    p_build.add_argument("--plan-bf16", required=True)
    p_build.add_argument("--cache", required=True)
    p_build.add_argument("--receipt", required=True)
    p_build.add_argument("--out", required=True)
    p_build.set_defaults(function=cmd_build)

    p_verify = sub.add_parser("verify")
    p_verify.add_argument("--base", required=True)
    p_verify.add_argument("--plan-bf16", required=True)
    p_verify.add_argument("--cache", required=True)
    p_verify.add_argument("--out", required=True)
    p_verify.set_defaults(function=cmd_verify)

    args = parser.parse_args()
    try:
        return args.function(args)
    except (ValueError, OSError, KeyError) as error:
        print(f"error: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
