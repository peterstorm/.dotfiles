#!/usr/bin/env python3
"""Assemble a GLM-5.3-Flash hybrid checkpoint: NVIDIA's FP4-Local experts + an abliterated dense pass.

The cyber build ships 90% of its bytes as routed experts that abliteration cannot touch (FP4
storage holds no room for an edit of that size). ``nvidia/GLM-5.3-Flash-FP4-Local`` already has
those experts on disk in the CSF layout the export wants. So the hybrid keeps every NVIDIA expert
shard byte-for-byte and replaces only the dense tensors:

    163.3 GiB reused  /  18.0 GiB fetched   (measured from both repos' shard headers)

Every dense tensor in the cyber build is a strict subset of FP4-Local's name set, with identical
shapes and identical storage formats -- so the splice is an in-place byte patch of a reflinked
copy. Declarations, ``model.safetensors.index.json`` and ``config.json`` stay untouched, which
means ``export-glm-tp2.sh`` sees exactly the checkpoint shape it already exports and produces the
same graph catalog as v16.

Dense tensors are re-encoded from the cyber build's BF16 into the format FP4-Local already uses
for them, on the exact grids the loaders read back:

    mx8     weight F8_E4M3 (n,k)        scale U8  (n, k/32)               E8M0, per 32-column group
    block8  weight F8_E4M3 (n,k)        scale F32 (n/128, 1, k/128, 1)    per 128x128 block
    bf16    weight BF16                 no scale
    f32     weight F32                  no scale

Re-encoding is measured, not assumed: ``splice`` writes the relative and max-absolute error of
every requantized tensor into ``hybrid-receipt.json``.

Commands
    plan    read both repos' headers, classify every tensor, emit hybrid-plan.json   (no torch)
    fetch   range-download only the source tensors the plan names                   (no torch)
    splice  reflink the base checkpoint, patch plan bytes in place, write a receipt  (torch)
    verify  re-read the result and prove headers, index and config are unchanged    (no torch)

Torch lives only in the serving image, so ``splice`` runs there while plan/fetch/verify stay on the
host::

    docker run --rm -v /models:/models -v "$PWD":/work \\
        peterstorm/glm53-hyperflare:ac9136b-cu131 \\
        python3 /work/glm-hybrid-checkpoint.py splice --plan /work/hybrid-plan.json \\
        --staging /work/staging --base /models/glm53-hyperflare/glm53-fp4-local \\
        --out /models/glm53-hyperflare/glm53-cyber-hybrid

A plan entry looks like::

    {"tensor": "model.language_model.layers.7.self_attn.q_a_proj.weight",
     "shard": "model-00003-of-00040.safetensors",       # base shard, patched in place
     "begin": 123456, "end": 7522888,                   # offsets relative to the base data section
     "dtype": "F8_E4M3", "shape": [1536, 4096], "storage": "block8",
     "action": "requant",                               # requant | cast | copy
     "scale": {"tensor": "...weight_scale", "shard": ..., "begin": .., "end": ..,
               "dtype": "F32", "shape": [12, 1, 32, 1]},
     "source": {"shard": "...", "begin": .., "end": .., "dtype": "BF16"}}
"""

from __future__ import annotations

import argparse
import json
import shutil
import struct
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Mapping, Sequence

HF = "https://huggingface.co"
BASE_REPO = "nvidia/GLM-5.3-Flash-FP4-Local"
CYBER_REPO = "dealignai/GLM-5.3-Flash-CYBERSECURITY-W4A16"
INDEX_NAME = "model.safetensors.index.json"

#: Routed experts (and the MTP draft layer's expert block) never leave NVIDIA.
EXPERT_MARKER = ".mlp.experts."
#: Dense text tensors the abliterated build replaces.
DENSE_ROOTS = ("model.language_model.", "lm_head.", "mtp.")
#: KEPT_FROM_BASE: FP4-Local prunes the vision MLP to half width (intermediate 512 against the
#: cyber build's 1024) and packs its weights as U8, so the vision towers are not interchangeable.
#: The text tower matches exactly, tensor for tensor, and carries every tuned value.
VISION_ROOT = "model.visual."


class Storage(Enum):
    """Storage formats the glm53 loader distinguishes."""

    MX8 = "mx8"
    BLOCK8 = "block8"
    BF16 = "bf16"
    F32 = "f32"

    @property
    def quantized(self) -> bool:
        return self in (Storage.MX8, Storage.BLOCK8)

    @property
    def group(self) -> int:
        """Columns per scale group, or 0 for unquantized storage."""
        return {Storage.MX8: 32, Storage.BLOCK8: 128}.get(self, 0)


#: A fetch whose median cosine against the base falls below this read the wrong bytes.
ENVELOPE_MIN_MEDIAN = 0.9
#: A tuned tensor is corrupt where its magnitude leaves the base tensor's envelope by this factor.
#: Abliteration preserves scale: on 846 of 854 tensors the tuned maximum matches the base maximum to
#: three significant figures, while the eight that leave the envelope carry saturated or clipped
#: values (the cyber build's head is clamped at exactly 1000.0 against a base maximum of 0.219).
ENVELOPE_FACTOR = 8.0


def e8m0_scale(byte: int) -> float:
    """The value an E8M0 scale byte encodes: ``2 ** (byte - 127)``."""
    return 2.0 ** (byte - 127)


def corruption_mask(source, torch, threshold: float):
    """Positions where a tuned tensor is non-finite or outside the base tensor's envelope."""
    return ~torch.isfinite(source) | (source.abs() > threshold)


def envelope_threshold(base, factor: float = ENVELOPE_FACTOR) -> float:
    """The magnitude above which a tuned value cannot be a weight the base could also hold."""
    peak = float(base.abs().max())
    return max(peak * factor, 1e-3)


def repair_from_base(source, base, torch, factor: float = ENVELOPE_FACTOR):
    """Replace out-of-envelope elements with the pre-tuning value, returning (tensor, repaired)."""
    threshold = envelope_threshold(base, factor)
    bad = corruption_mask(source, torch, threshold)
    count = int(bad.sum())
    if not count:
        return source, 0
    repaired = torch.where(bad, base, source)
    still_bad = corruption_mask(repaired, torch, threshold)
    if bool(still_bad.any()):
        repaired = torch.where(still_bad, torch.zeros_like(repaired), repaired)
    return repaired, count


# --------------------------------------------------------------------------------------------
# functional core
# --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class TensorHeader:
    """One tensor as its shard header describes it.

    ``begin``/``end`` are relative to the shard's data section; ``data_start`` is where that section
    begins in the file (8 + the header length). Reading a tensor from a remote shard needs the
    absolute ``file_range`` -- reading the data-relative range instead silently returns a
    neighbouring tensor's bytes, shifted by the header length.
    """

    shard: str
    begin: int
    end: int
    dtype: str
    shape: tuple[int, ...]
    data_start: int = 0

    @property
    def nbytes(self) -> int:
        return self.end - self.begin

    @property
    def file_range(self) -> tuple[int, int]:
        """Absolute byte range of this tensor inside its shard file."""
        return (self.data_start + self.begin, self.data_start + self.end)


@dataclass(frozen=True)
class ScaleRef:
    """A quantization scale tensor that travels with its weight."""

    name: str
    header: TensorHeader


@dataclass(frozen=True)
class Entry:
    """One dense tensor the hybrid takes from the cyber build."""

    tensor: str
    base: TensorHeader
    source: TensorHeader
    storage: Storage
    scale: ScaleRef | None
    action: str

    def as_json(self) -> dict:
        payload = {
            "tensor": self.tensor,
            "shard": self.base.shard,
            "begin": self.base.begin,
            "end": self.base.end,
            "dtype": self.base.dtype,
            "shape": list(self.base.shape),
            "storage": self.storage.value,
            "action": self.action,
            "source": {
                "shard": self.source.shard,
                "begin": self.source.begin,
                "end": self.source.end,
                "dtype": self.source.dtype,
                "data_start": self.source.data_start,
            },
        }
        if self.scale is not None:
            payload["scale"] = {
                "tensor": self.scale.name,
                "shard": self.scale.header.shard,
                "begin": self.scale.header.begin,
                "end": self.scale.header.end,
                "dtype": self.scale.header.dtype,
                "shape": list(self.scale.header.shape),
            }
        return payload


def is_dense(tensor: str) -> bool:
    """True for tensors the abliterated build replaces, false for NVIDIA's experts."""
    if EXPERT_MARKER in tensor:
        return False
    return any(tensor.startswith(root) for root in DENSE_ROOTS)


def scale_name(tensor: str) -> str:
    if not tensor.endswith(".weight"):
        raise ValueError(f"{tensor}: a quantized projection must end in .weight")
    return tensor[: -len(".weight")] + ".weight_scale"


def storage_of(dtype: str, scale: TensorHeader | None, tensor: str) -> Storage:
    """Classify a base tensor by how the loader will read it back."""
    if dtype == "F8_E4M3":
        if scale is None:
            raise ValueError(f"{tensor}: FP8 weight without a scale tensor")
        if scale.dtype == "U8" and len(scale.shape) == 2:
            return Storage.MX8
        if scale.dtype == "F32" and len(scale.shape) == 4:
            return Storage.BLOCK8
        raise ValueError(f"{tensor}: unrecognised FP8 scale {scale.dtype}{scale.shape}")
    if dtype == "BF16":
        return Storage.BF16
    if dtype == "F32":
        return Storage.F32
    raise ValueError(f"{tensor}: dense tensor stored as {dtype}")


def expected_scale_shape(storage: Storage, shape: Sequence[int]) -> tuple[int, ...]:
    """The scale grid the loader insists on for a weight of ``shape``."""
    rows, columns = shape
    if storage is Storage.MX8:
        return (rows, (columns + 31) // 32)
    if storage is Storage.BLOCK8:
        return ((rows + 127) // 128, 1, (columns + 127) // 128, 1)
    raise ValueError(f"{storage.value} storage carries no scale grid")


def check_grid(storage: Storage, shape: Sequence[int], tensor: str) -> None:
    """Reject shapes whose scale grid this recipe cannot express."""
    if not storage.quantized:
        return
    rows, columns = shape
    if storage is Storage.MX8 and columns % 32:
        raise ValueError(f"{tensor}: MXFP8 needs a 32-aligned input width, got {columns}")
    if storage is Storage.BLOCK8 and (rows % 128 or columns % 128):
        raise ValueError(f"{tensor}: block-FP8 needs 128-aligned rows and columns, got {shape}")


def plan_entry(
    tensor: str,
    base: TensorHeader,
    source: TensorHeader,
    headers: Mapping[str, TensorHeader],
) -> Entry:
    """Pair one base tensor with its cyber-build source, deriving storage and action."""
    if base.shape != source.shape:
        raise ValueError(f"{tensor}: shape {base.shape} in base, {source.shape} in the cyber build")
    if source.dtype not in ("BF16", "F32"):
        raise ValueError(f"{tensor}: cyber source is {source.dtype}, expected BF16 or F32")
    scale_header = headers.get(scale_name(tensor)) if base.dtype == "F8_E4M3" else None
    storage = storage_of(base.dtype, scale_header, tensor)
    if scale_header is not None:
        want = expected_scale_shape(storage, base.shape)
        if scale_header.shape != want:
            raise ValueError(f"{tensor}: scale {scale_header.shape} != expected grid {want}")
    check_grid(storage, base.shape, tensor)
    if storage.quantized:
        action = "requant"
    else:
        action = "copy" if base.dtype == source.dtype else "cast"
    return Entry(
        tensor=tensor,
        base=base,
        source=source,
        storage=storage,
        scale=ScaleRef(scale_name(tensor), scale_header) if scale_header else None,
        action=action,
    )


def build_plan(
    base_headers: Mapping[str, TensorHeader],
    cyber_headers: Mapping[str, TensorHeader],
) -> list[Entry]:
    """Every dense tensor the cyber build can supply, checked against the base checkpoint."""
    supplied = [
        tensor
        for tensor in cyber_headers
        if is_dense(tensor) and tensor.endswith(".weight") and not tensor.endswith(".weight_scale")
    ]
    missing = sorted(tensor for tensor in supplied if tensor not in base_headers)
    if missing:
        raise ValueError(
            f"{len(missing)} cyber dense tensors are absent from the base checkpoint; "
            f"first: {missing[:3]}"
        )
    mismatched = {
        tensor: (base_headers[tensor].shape, cyber_headers[tensor].shape)
        for tensor in supplied
        if base_headers[tensor].shape != cyber_headers[tensor].shape
    }
    if mismatched:
        sample = "; ".join(
            f"{tensor} {base} vs {cyber}"
            for tensor, (base, cyber) in list(mismatched.items())[:3]
        )
        raise ValueError(f"{len(mismatched)} dense tensors differ in shape: {sample}")
    return [
        plan_entry(tensor, base_headers[tensor], cyber_headers[tensor], base_headers)
        for tensor in sorted(supplied)
    ]


def plan_stats(entries: Sequence[Entry]) -> dict:
    """Byte accounting: what is fetched, what is re-encoded, what is patched in place."""
    by_storage: dict[str, int] = {}
    for entry in entries:
        by_storage[entry.storage.value] = by_storage.get(entry.storage.value, 0) + 1
    return {
        "tensors": len(entries),
        "fetched_bytes": sum(entry.source.nbytes for entry in entries),
        "patched_bytes": sum(entry.base.nbytes for entry in entries),
        "requantized": sum(1 for entry in entries if entry.action == "requant"),
        "copied": sum(1 for entry in entries if entry.action == "copy"),
        "cast": sum(1 for entry in entries if entry.action == "cast"),
        "by_storage": by_storage,
    }


@dataclass(frozen=True)
class FetchVerdict:
    """Whether the staged bytes plausibly came from the same model as the base checkpoint.

    A tuned checkpoint stays close to its base: the abliteration moves a few percent of the energy.
    A mis-addressed range read returns a neighbouring tensor's bytes and scores a cosine near zero,
    so the median cosine separates "same model, tuned" from "same model, read wrong" without
    assuming anything about how much a tune changed.
    """

    samples: int
    median: float
    fifth_percentile: float
    share_identical: float
    ok: bool

    def as_json(self) -> dict:
        return {
            "samples": self.samples,
            "median_cosine": round(self.median, 6),
            "p05_cosine": round(self.fifth_percentile, 6),
            "share_cosine_at_least_0.99": round(self.share_identical, 4),
            "ok": self.ok,
        }


def fetch_verdict(
    scores: Sequence[float], *, min_median: float = 0.9, min_share: float = 0.5
) -> FetchVerdict:
    """Score the staged tensors against the base: median cosine and the identical share."""
    if not scores:
        raise ValueError("no staged tensors scored")
    ordered = sorted(scores)
    median = ordered[len(ordered) // 2]
    position = max(int(round(0.05 * (len(ordered) - 1))), 0)
    share = sum(1 for score in ordered if score >= 0.99) / len(ordered)
    return FetchVerdict(
        samples=len(ordered),
        median=median,
        fifth_percentile=ordered[position],
        share_identical=share,
        ok=median >= min_median and share >= min_share,
    )


def require_same_length(tensor: str, expected: int, payload: bytes) -> None:
    """A patch that changes length would shift every later tensor in the shard."""
    if len(payload) != expected:
        raise ValueError(
            f"{tensor}: patch is {len(payload)} bytes, the base tensor is {expected}; "
            "in-place splicing requires identical storage"
        )


def quantize_mx8(weight, torch):
    """BF16 weight -> (F8_E4M3 values, U8 E8M0 scales (n, k/32)) on the loader's grid."""
    rows, columns = weight.shape
    groups = weight.float().reshape(rows, columns // 32, 32)
    amax = groups.abs().amax(dim=-1)
    target = (amax / 448.0).clamp_min(2.0**-126)
    exponent = torch.ceil(torch.log2(target)).clamp(-127, 126)
    scale = torch.exp2(exponent)
    values = (groups / scale.unsqueeze(-1)).clamp(-448.0, 448.0).to(torch.float8_e4m3fn)
    encoded = (exponent + 127).clamp(0, 254).to(torch.uint8)
    return values.reshape(rows, columns), encoded


def quantize_block8(weight, torch):
    """BF16 weight -> (F8_E4M3 values, F32 scales (n/128, 1, k/128, 1)) on 128x128 blocks."""
    rows, columns = weight.shape
    blocks = weight.float().reshape(rows // 128, 128, columns // 128, 128)
    amax = blocks.abs().amax(dim=(1, 3))
    scale = torch.where(amax == 0, torch.ones_like(amax), amax / 448.0)
    values = (blocks / scale[:, None, :, None]).clamp(-448.0, 448.0).to(torch.float8_e4m3fn)
    return values.reshape(rows, columns), scale.reshape(rows // 128, 1, columns // 128, 1)


def decode_mx8(values, scales, torch):
    """Rebuild the approximation the kernel computes, for error measurement."""
    rows, columns = values.shape
    scale_values = torch.exp2(scales.to(torch.float32) - 127.0)
    return values.to(torch.float32) * scale_values.unsqueeze(-1).expand(
        rows, columns // 32, 32
    ).reshape(rows, columns)


def decode_block8(values, scales, torch):
    rows, columns = values.shape
    return values.to(torch.float32) * scales.reshape(rows // 128, columns // 128).to(
        torch.float32
    ).repeat_interleave(128, 0).repeat_interleave(128, 1)


def requantization_error(source, approximation) -> tuple[float, float]:
    """(relative L2 error, max absolute error) of a re-encoding."""
    delta = (source.float() - approximation.float()).abs()
    norm = source.float().norm()
    relative = float(delta.norm()) / float(norm) if float(norm) else 0.0
    return relative, float(delta.max()) if delta.numel() else 0.0


# --------------------------------------------------------------------------------------------
# imperative shell
# --------------------------------------------------------------------------------------------


def read_header(path: Path | str) -> tuple[int, dict]:
    """Return (header length, parsed header) for a safetensors file."""
    with open(path, "rb") as handle:
        (length,) = struct.unpack("<Q", handle.read(8))
        header = json.loads(handle.read(length))
    header.pop("__metadata__", None)
    return length, header


def _range(url: str, begin: int, end: int, timeout: int) -> bytes:
    request = urllib.request.Request(url, headers={"Range": f"bytes={begin}-{end - 1}"})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        payload = response.read()
    if len(payload) != end - begin:
        raise ValueError(f"{url}: short read {len(payload)} != {end - begin}")
    return payload


def _with_retries(operation, *, attempts: int = 5, base_delay: float = 1.0):
    """Run an HTTP operation, absorbing the resets and 5xx bursts a 900-request fetch attracts."""
    last = None
    for attempt in range(attempts):
        try:
            return operation()
        except urllib.error.HTTPError as error:
            if error.code < 500 and error.code != 429:
                raise
            last = error
        except (urllib.error.URLError, TimeoutError, ConnectionResetError) as error:
            last = error
        time.sleep(base_delay * 2**attempt)
    raise last


def remote_header(repo: str, shard: str) -> tuple[int, dict]:
    """Fetch only a shard's JSON header, returning (header length, parsed header)."""
    url = f"{HF}/{repo}/resolve/main/{shard}"
    (length,) = struct.unpack("<Q", _range(url, 0, 8, timeout=120))
    header = json.loads(_range(url, 8, 8 + length, timeout=120))
    header.pop("__metadata__", None)
    return length, header


def remote_bytes(repo: str, shard: str, begin: int, end: int) -> bytes:
    url = f"{HF}/{repo}/resolve/main/{shard}"
    return _with_retries(lambda: _range(url, begin, end, timeout=600))


def remote_index(repo: str) -> dict:
    url = f"{HF}/{repo}/resolve/main/{INDEX_NAME}"

    def fetch():
        with urllib.request.urlopen(url, timeout=120) as response:
            return json.load(response)["weight_map"]

    return _with_retries(fetch)


def headers_of(
    shard: str, raw: Mapping[str, Mapping], data_start: int = 0
) -> dict[str, TensorHeader]:
    """Turn one shard's raw header into typed tensor headers (pure)."""
    out = {}
    for tensor, entry in raw.items():
        if tensor == "__metadata__":
            continue
        begin, end = entry["data_offsets"]
        out[tensor] = TensorHeader(
            shard, begin, end, entry["dtype"], tuple(entry["shape"]), data_start
        )
    return out


def local_headers(directory: Path | str, index: Mapping[str, str]) -> dict[str, TensorHeader]:
    """Materialise every tensor header in ``index`` from a checkpoint already on disk."""
    out: dict[str, TensorHeader] = {}
    for shard in sorted(set(index.values())):
        length, raw = read_header(Path(directory) / shard)
        out.update(headers_of(shard, raw, 8 + length))
    return out


def remote_headers(
    repo: str, index: Mapping[str, str], cache: Path | None
) -> dict[str, TensorHeader]:
    """Materialise every tensor header in ``index`` by fetching each shard's header only."""
    shards = sorted(set(index.values()))
    out: dict[str, TensorHeader] = {}
    for position, shard in enumerate(shards, 1):
        cached = cache / f"{shard}.header.json" if cache else None
        if cached and cached.exists():
            raw = json.loads(cached.read_text())
            length = raw.pop("__header_bytes__")
        else:
            length, raw = remote_header(repo, shard)
            if cached:
                cached.parent.mkdir(parents=True, exist_ok=True)
                cached.write_text(json.dumps({**raw, "__header_bytes__": length}))
        out.update(headers_of(shard, raw, 8 + length))
        print(f"\r  {repo}: {position}/{len(shards)} shard headers", end="", file=sys.stderr)
    print(file=sys.stderr)
    return out


def _load_plan(path: str, limit: int) -> tuple[dict, list[dict]]:
    plan = json.loads(Path(path).read_text())
    entries = plan["entries"] if limit == 0 else plan["entries"][:limit]
    return plan, entries


def cmd_plan(args: argparse.Namespace) -> int:
    cache = Path(args.cache) if args.cache else None
    base_index = remote_index(BASE_REPO)
    cyber_index = remote_index(CYBER_REPO)
    base_headers = remote_headers(BASE_REPO, base_index, cache and cache / "base")
    cyber_headers = remote_headers(CYBER_REPO, cyber_index, cache and cache / "cyber")
    entries = build_plan(base_headers, cyber_headers)
    stats = plan_stats(entries)
    Path(args.out).write_text(
        json.dumps(
            {
                "base_repo": BASE_REPO,
                "cyber_repo": CYBER_REPO,
                "base_index": base_index,
                "stats": stats,
                "entries": [entry.as_json() for entry in entries],
            },
            indent=1,
        )
    )
    print(
        f"plan: {stats['tensors']} dense tensors  fetch={stats['fetched_bytes'] / 2**30:.1f} GiB  "
        f"patch={stats['patched_bytes'] / 2**30:.1f} GiB  requant={stats['requantized']} "
        f"copy={stats['copied']} cast={stats['cast']}\n  -> {args.out}"
    )
    return 0


def cmd_fetch(args: argparse.Namespace) -> int:
    plan, entries = _load_plan(args.plan, args.limit)
    repo, dest = plan["cyber_repo"], Path(args.staging)
    dest.mkdir(parents=True, exist_ok=True)

    def download(item: tuple[int, dict]) -> tuple[str, str]:
        position, entry = item
        name = f"{position:05d}.bin"
        target, source = dest / name, entry["source"]
        size = source["end"] - source["begin"]
        if not target.exists() or target.stat().st_size != size:
            begin = source["data_start"] + source["begin"]
            end = source["data_start"] + source["end"]
            target.write_bytes(remote_bytes(repo, source["shard"], begin, end))
        return name, entry["tensor"]

    manifest: dict[str, str] = {}
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        for position, (name, tensor) in enumerate(pool.map(download, enumerate(entries, 1)), 1):
            manifest[name] = tensor
            print(f"\r  fetched {position}/{len(entries)}  {tensor[:70]}", end="", file=sys.stderr)
    print(file=sys.stderr)
    (dest / "manifest.json").write_text(json.dumps(manifest, indent=1))
    total = sum((dest / name).stat().st_size for name in manifest)
    print(f"staging: {len(manifest)} tensors, {total / 2**30:.2f} GiB in {dest}")
    return 0


def _tensor_from_bytes(payload: bytes, shape: Sequence[int], dtype: str, torch):
    dtypes = {"BF16": torch.bfloat16, "F32": torch.float32, "F16": torch.float16}
    if dtype not in dtypes:
        raise ValueError(f"cannot cast from {dtype}")
    return torch.frombuffer(bytearray(payload), dtype=dtypes[dtype]).reshape(tuple(shape)).clone()


def _raw_bytes(tensor, torch) -> bytes:
    """Serialise a tensor to checkpoint bytes, viewing the dtypes numpy cannot hold as U8."""
    if tensor.dtype in (torch.float8_e4m3fn, torch.bfloat16):
        tensor = tensor.view(torch.uint8)
    return tensor.contiguous().cpu().numpy().tobytes()


def _base_tensor(entry: dict, base_dir: Path, torch):
    """Read and dequantize the base checkpoint's version of a tensor, for repairing corruption."""
    path = base_dir / entry["shard"]
    length, header = read_header(path)
    meta = header[entry["tensor"]]
    with open(path, "rb") as handle:
        handle.seek(8 + length + meta["data_offsets"][0])
        raw = handle.read(meta["data_offsets"][1] - meta["data_offsets"][0])
    if meta["dtype"] == "BF16":
        return torch.frombuffer(bytearray(raw), dtype=torch.bfloat16).reshape(
            tuple(entry["shape"])
        ).float()
    if meta["dtype"] == "F32":
        return torch.frombuffer(bytearray(raw), dtype=torch.float32).reshape(tuple(entry["shape"]))
    values = torch.frombuffer(bytearray(raw), dtype=torch.float8_e4m3fn).reshape(
        tuple(entry["shape"])
    ).float()
    scale_ref = entry.get("scale")
    if scale_ref is None:
        raise SystemExit(f"{entry['tensor']}: FP8 base tensor without a scale entry")
    scale_path = base_dir / scale_ref["shard"]
    scale_length, scale_header = read_header(scale_path)
    scale_meta = scale_header[scale_ref["tensor"]]
    with open(scale_path, "rb") as handle:
        handle.seek(8 + scale_length + scale_meta["data_offsets"][0])
        scale_raw = handle.read(scale_meta["data_offsets"][1] - scale_meta["data_offsets"][0])
    if scale_meta["dtype"] == "U8":
        scales = torch.frombuffer(bytearray(scale_raw), dtype=torch.uint8).reshape(
            tuple(scale_ref["shape"])
        )
        return decode_mx8(values, scales, torch)
    scales = torch.frombuffer(bytearray(scale_raw), dtype=torch.float32).reshape(
        tuple(scale_ref["shape"])
    )
    return decode_block8(values, scales, torch)


def _produce(
    entry: dict, payload: bytes, base_dir: Path, torch, envelope: float = ENVELOPE_FACTOR
) -> tuple[bytes, bytes | None, dict]:
    """Turn one staged tensor into the bytes the base shard expects, repairing corruption."""
    source = _tensor_from_bytes(payload, entry["shape"], entry["source"]["dtype"], torch)
    base_values = _base_tensor(entry, base_dir, torch)
    source, repaired = repair_from_base(source, base_values, torch, envelope)
    if entry["source"]["dtype"] != "BF16":
        source = source.to(torch.bfloat16)
    peak_ratio = float(source.abs().max()) / max(float(base_values.abs().max()), 1e-9)
    storage_dtype = {"BF16": torch.bfloat16, "F32": torch.float32}.get(entry["dtype"])
    if entry["action"] in ("copy", "cast"):
        return _raw_bytes(source.to(storage_dtype), torch), None, _metrics((0.0, 0.0), repaired, peak_ratio)
    source = source.to(torch.bfloat16)
    if entry["storage"] == "mx8":
        values, scales = quantize_mx8(source, torch)
        error = requantization_error(source, decode_mx8(values, scales, torch))
        return _raw_bytes(values, torch), _raw_bytes(scales, torch), _metrics(error, repaired, peak_ratio)
    if entry["storage"] == "block8":
        values, scales = quantize_block8(source, torch)
        error = requantization_error(source, decode_block8(values, scales, torch))
        return _raw_bytes(values, torch), _raw_bytes(scales, torch), _metrics(error, repaired, peak_ratio)
    raise ValueError(f"{entry['tensor']}: requant requested for {entry['storage']} storage")


def _metrics(error: tuple[float, float], repaired: int = 0, peak_ratio: float = 1.0) -> dict:
    """The receipt records how far the tuned tensor left the base envelope, not just its error."""
    return {
        "rel_error": error[0],
        "max_abs_error": error[1],
        "repaired": repaired,
        "peak_ratio": round(peak_ratio, 4),
    }


def _patch(path: Path, data_start: int, begin: int, end: int, payload: bytes) -> None:
    """Overwrite one tensor's bytes, preserving the shard header and every other tensor."""
    require_same_length(str(path), end - begin, payload)
    with open(path, "r+b") as handle:
        handle.seek(data_start + begin)
        handle.write(payload)


def _reflinks(directory: Path) -> bool:
    """Probe once whether this filesystem clones blocks; a plain copy costs the full checkpoint."""
    probe = directory / ".reflink-probe"
    probe.write_bytes(b"hybrid")
    target = directory / ".reflink-probe.copy"
    try:
        result = subprocess.run(
            ["cp", "--reflink=always", str(probe), str(target)], capture_output=True
        )
        return result.returncode == 0
    finally:
        for path in (probe, target):
            path.unlink(missing_ok=True)


def check_against_local(entries: Sequence[dict], headers: Mapping[str, Mapping[str, TensorHeader]]) -> None:
    """Prove the plan's offsets still describe the checkpoint on disk before writing anything."""
    stale = []
    for entry in entries:
        local = headers[entry["shard"]].get(entry["tensor"])
        if local is None:
            stale.append(f"{entry['tensor']}: missing")
        elif (local.begin, local.end, local.dtype) != (entry["begin"], entry["end"], entry["dtype"]):
            stale.append(
                f"{entry['tensor']}: local {local.dtype}[{local.begin}:{local.end}] "
                f"!= plan {entry['dtype']}[{entry['begin']}:{entry['end']}]"
            )
    if stale:
        raise SystemExit(
            f"{len(stale)} plan entries disagree with {len(headers)} local shards; "
            f"the checkpoint on disk is not the revision the plan was built from: {stale[:3]}"
        )


def _plain_copy(base: Path, out: Path) -> None:
    print(
        "warning: this filesystem cannot clone blocks, copying the whole base checkpoint "
        "instead of only the patched tensors",
        file=sys.stderr,
    )
    subprocess.run(["cp", "-a", str(base) + "/.", str(out)], check=True)


def import_torch():
    """Torch ships in the serving image only; a copy-only splice stays stdlib."""
    try:
        import torch
    except ImportError as error:
        raise SystemExit(
            "splice needs torch for re-encoding; run it in the serving image, e.g.\n"
            '  docker run --rm -v /models:/models -v "$PWD":/work \\\n'
            "    peterstorm/glm53-hyperflare:ac9136b-cu131 \\\n"
            "    python3 /work/glm-hybrid-checkpoint.py splice "
            "--plan ... --staging ... --base ... --out ..."
        ) from error
    return torch


def cmd_check(args: argparse.Namespace) -> int:
    import torch

    plan, entries = _load_plan(args.plan, args.limit)
    staging, base = Path(args.staging), Path(args.base)
    manifest_path = staging / "manifest.json"
    if manifest_path.exists():
        by_tensor = {t: name for name, t in json.loads(manifest_path.read_text()).items()}
    else:
        # A partial fetch is still checkable: payloads are named by plan position.
        by_tensor = {
            entry["tensor"]: f"{position:05d}.bin"
            for position, entry in enumerate(entries, 1)
            if (staging / f"{position:05d}.bin").exists()
        }
    scores: list[tuple[str, float]] = []
    for entry in entries:
        name = by_tensor.get(entry["tensor"])
        if name is None:
            continue
        source = _tensor_from_bytes(
            (staging / name).read_bytes(), entry["shape"], entry["source"]["dtype"], torch
        ).float()
        reference = _base_tensor(entry, base, torch).float()
        denominator = float(source.norm()) * float(reference.norm())
        cosine = float((source.flatten() @ reference.flatten()) / denominator) if denominator else 0.0
        scores.append((entry["tensor"], cosine))
    verdict = fetch_verdict(
        [cosine for _, cosine in scores], min_median=args.min_median, min_share=args.min_share
    )
    worst = sorted(scores, key=lambda row: row[1])[: args.worst]
    payload = {
        "verdict": verdict.as_json(),
        "worst": [{"tensor": t, "cosine": round(c, 6)} for t, c in worst],
    }
    (staging / "fetch-check.json").write_text(json.dumps(payload, indent=1))
    print(
        f"check: {verdict.samples} tensors  median cos={verdict.median:.5f}  "
        f"p05={verdict.fifth_percentile:.5f}  identical={verdict.share_identical:.1%}  "
        f"-> {'OK' if verdict.ok else 'FAIL'}"
    )
    for tensor, cosine in worst[:5]:
        print(f"  {cosine:+.5f}  {tensor}")
    return 0 if verdict.ok else 1


def cmd_splice(args: argparse.Namespace) -> int:
    plan, entries = _load_plan(args.plan, args.limit)
    torch = import_torch()
    staging, base, out = Path(args.staging), Path(args.base).resolve(), Path(args.out)
    manifest = json.loads((staging / "manifest.json").read_text())
    by_tensor = {tensor: name for name, tensor in manifest.items()}
    if args.skip_check:
        print("warning: splicing without a fetch content check", file=sys.stderr)
    else:
        check_path = staging / "fetch-check.json"
        if not check_path.exists():
            raise SystemExit(f"no {check_path}; run the check subcommand first")
        verdict = json.loads(check_path.read_text())["verdict"]
        if not verdict["ok"]:
            raise SystemExit(
                f"fetch content check failed: median cosine {verdict['median_cosine']} "
                f"(< {ENVELOPE_MIN_MEDIAN}). The staged bytes do not belong to this checkpoint."
            )
    free_before = shutil.disk_usage(out.parent).free
    if not (out / INDEX_NAME).exists():
        out.mkdir(parents=True, exist_ok=True)
        if any(out.iterdir()):
            raise SystemExit(f"{out} is not empty; refusing to splice into it")
        print(f"copying {base} -> {out}", file=sys.stderr)
        if _reflinks(out.parent):
            subprocess.run(["cp", "-a", "--reflink=always", str(base) + "/.", str(out)], check=True)
        else:
            _plain_copy(base, out)
    spent = (free_before - shutil.disk_usage(out.parent).free) / 2**30
    print(
        f"checkpoint copy cost {spent:.1f} GiB for {plan['stats']['patched_bytes'] / 2**30:.1f} GiB "
        f"of patched tensors ({'reflinked' if spent < plan['stats']['patched_bytes'] / 2**30 * 1.5 else 'full copy'})",
        file=sys.stderr,
    )
    shards = {entry["shard"] for entry in entries} | {
        entry["scale"]["shard"] for entry in entries if "scale" in entry
    }
    headers = {shard: headers_of(shard, read_header(base / shard)[1]) for shard in shards}
    check_against_local(entries, headers)
    data_start = {shard: 8 + read_header(out / shard)[0] for shard in shards}
    receipt: list[dict] = []
    for position, entry in enumerate(entries, 1):
        name = by_tensor.get(entry["tensor"])
        if name is None:
            raise SystemExit(f"missing staging payload for {entry['tensor']}; rerun fetch")
        payload = (staging / name).read_bytes()
        weight, scale, metrics = _produce(entry, payload, base, torch, args.envelope)
        _patch(out / entry["shard"], data_start[entry["shard"]], entry["begin"], entry["end"], weight)
        if "scale" in entry and scale is not None:
            scale_entry = entry["scale"]
            _patch(
                out / scale_entry["shard"],
                data_start[scale_entry["shard"]],
                scale_entry["begin"],
                scale_entry["end"],
                scale,
            )
        receipt.append({"tensor": entry["tensor"], "action": entry["action"], **metrics})
        print(f"\r  spliced {position}/{len(entries)}  {entry['tensor'][:70]}", end="", file=sys.stderr)
    print(file=sys.stderr)
    (out / "hybrid-receipt.json").write_text(
        json.dumps(
            {
                "repos": {"base": plan["base_repo"], "cyber": plan["cyber_repo"]},
                "stats": plan["stats"],
                "patched": receipt,
            },
            indent=1,
        )
    )
    worst = sorted(receipt, key=lambda row: row["rel_error"], reverse=True)[:5]
    repaired = [row for row in receipt if row["repaired"]]
    print(f"spliced {len(receipt)} tensors into {out}")
    for row in worst:
        print(f"  rel error {row['rel_error']:.4f}  max|d| {row['max_abs_error']:.5f}  {row['tensor']}")
    if repaired:
        print(f"repaired corruption from the base in {len(repaired)} tensors:")
        for row in repaired:
            print(f"  {row['repaired']} elements  {row['tensor']}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    _, entries = _load_plan(args.plan, args.limit)
    base, out = Path(args.base), Path(args.out)
    for entry in entries:
        _, header = read_header(out / entry["shard"])
        present = header.get(entry["tensor"])
        if present is None:
            raise SystemExit(f"{entry['tensor']} vanished from {entry['shard']}")
        if present["dtype"] != entry["dtype"] or tuple(present["shape"]) != tuple(entry["shape"]):
            raise SystemExit(f"{entry['tensor']}: header became {present['dtype']}{present['shape']}")
        if present["data_offsets"] != [entry["begin"], entry["end"]]:
            raise SystemExit(f"{entry['tensor']}: data offsets moved")
        if "scale" in entry:
            scale = entry["scale"]
            _, scale_header = read_header(out / scale["shard"])
            if scale["tensor"] not in scale_header:
                raise SystemExit(f"{scale['tensor']} vanished from {scale['shard']}")
    if json.loads((base / INDEX_NAME).read_text()) != json.loads((out / INDEX_NAME).read_text()):
        raise SystemExit("index changed; the export manifest would disagree with the shards")
    if (base / "config.json").read_bytes() != (out / "config.json").read_bytes():
        raise SystemExit("config.json changed; declarations must stay identical for splicing")
    total = lambda root: sum(path.stat().st_size for path in root.rglob("*.safetensors"))
    print(
        f"verify: {len(entries)} entries intact, index and config identical, "
        f"shards {total(out) / 2**30:.1f} GiB out / {total(base) / 2**30:.1f} GiB base"
    )
    return 0


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    sub = parser.add_subparsers(dest="command", required=True)

    plan_parser = sub.add_parser("plan", help="classify both checkpoints and emit a plan")
    plan_parser.add_argument("--out", default="hybrid-plan.json")
    plan_parser.add_argument("--cache", default="", help="directory for the per-shard header cache")
    plan_parser.set_defaults(func=cmd_plan)

    fetch_parser = sub.add_parser("fetch", help="range-download the plan's source tensors")
    fetch_parser.add_argument("--plan", required=True)
    fetch_parser.add_argument("--staging", required=True)
    fetch_parser.add_argument("--limit", type=int, default=0)
    fetch_parser.add_argument("--jobs", type=int, default=8, help="parallel range downloads")
    fetch_parser.set_defaults(func=cmd_fetch)

    check_parser = sub.add_parser("check", help="score staged tensors against the base (torch)")
    check_parser.add_argument("--plan", required=True)
    check_parser.add_argument("--staging", required=True)
    check_parser.add_argument("--base", required=True)
    check_parser.add_argument("--min-median", type=float, default=ENVELOPE_MIN_MEDIAN)
    check_parser.add_argument("--min-share", type=float, default=0.5)
    check_parser.add_argument("--worst", type=int, default=10)
    check_parser.add_argument("--limit", type=int, default=0)
    check_parser.set_defaults(func=cmd_check)

    splice_parser = sub.add_parser("splice", help="reflink the base and patch plan bytes in place")
    splice_parser.add_argument("--plan", required=True)
    splice_parser.add_argument("--staging", required=True)
    splice_parser.add_argument("--base", required=True)
    splice_parser.add_argument("--out", required=True)
    splice_parser.add_argument("--limit", type=int, default=0)
    splice_parser.add_argument("--skip-check", action="store_true")
    splice_parser.add_argument(
        "--envelope", type=float, default=ENVELOPE_FACTOR,
        help="repair tuned values above this multiple of the base tensor's peak",
    )
    splice_parser.set_defaults(func=cmd_splice)

    verify_parser = sub.add_parser("verify", help="prove headers, index and config unchanged")
    verify_parser.add_argument("--plan", required=True)
    verify_parser.add_argument("--base", required=True)
    verify_parser.add_argument("--out", required=True)
    verify_parser.add_argument("--limit", type=int, default=0)
    verify_parser.set_defaults(func=cmd_verify)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
