#!/usr/bin/env python3
"""Unit checks for glm53-bf16-dense.py: selection, header surgery, build, verify.

Runs entirely on synthetic fixtures in temp directories; the network fetch is replaced by a
local payload table (and, in one check, by a stubbed remote_bytes). Mutations are built on
scratch copies of the fixture -- never on live files.
"""

from __future__ import annotations

import importlib.util
import json
import shutil
import struct
import sys
import tempfile
from pathlib import Path

MODULE_PATH = Path(__file__).resolve().parent.parent / "scripts/inference/glm53/glm53-bf16-dense.py"
spec = importlib.util.spec_from_file_location("bf16_dense", MODULE_PATH)
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod  # dataclasses resolve postponed annotations through sys.modules
spec.loader.exec_module(mod)

CHECKS = 0


def check(condition: bool, label: str) -> None:
    global CHECKS
    CHECKS += 1
    if not condition:
        raise AssertionError(f"check {CHECKS} FAILED: {label}")


def check_raises(label: str, operation):
    global CHECKS
    try:
        operation()
    except Exception:
        CHECKS += 1
        return
    raise AssertionError(f"check {CHECKS + 1} FAILED (no raise): {label}")


def payload(name: str, size: int) -> bytes:
    """Deterministic pseudo-random bytes so mismatches are detectable."""
    seed = sum(name.encode())
    out = bytearray()
    for i in range(size):
        out.append((seed + i * 31) % 256)
    return bytes(out)


def write_safetensors(path: Path, tensors: list[tuple[str, str, list[int], bytes]],
                      metadata: dict | None = None) -> None:
    header: dict = {}
    if metadata:
        header["__metadata__"] = metadata
    offset = 0
    for name, dtype, shape, data in tensors:
        end = offset + len(data)
        header[name] = {"dtype": dtype, "shape": shape, "data_offsets": [offset, end]}
        offset = end
    with path.open("wb") as handle:
        handle.write(mod.serialize_header(header))
        for _, _, _, data in tensors:
            handle.write(data)


# --- fixture -------------------------------------------------------------------------

def build_fixture(root: Path) -> dict:
    """A 4-shard miniature checkpoint with the shapes the real splice pairs."""
    base = root / "base"
    base.mkdir()
    q_w, q_s = payload("qw", 512), payload("qs", 8)
    o_w, o_s = payload("ow", 512), payload("os", 8)
    head_w, head_s = payload("hw", 256), payload("hs", 16)
    sh_w, sh_s = payload("sw", 256), payload("ss", 4)
    expert = payload("ex", 32)
    norm = payload("nm", 16)
    gate = payload("gt", 32)
    native = payload("nq", 16)
    kda_k, kda_s, kda_fa = payload("kk", 128), payload("ks", 8), payload("kf", 32)
    mla_qb, mla_s = payload("qb", 128), payload("qs2", 8)

    write_safetensors(base / "model-00001-of-00004.safetensors", [
        ("model.layers.40.self_attn.q_proj.weight", "F8_E4M3", [8, 32], q_w),
        ("model.layers.40.self_attn.q_proj.weight_scale", "U8", [8, 1], q_s),
        ("model.layers.40.mlp.experts.0.down_proj", "U8", [4, 8], expert),
    ])
    write_safetensors(base / "model-00002-of-00004.safetensors", [
        ("model.layers.39.self_attn.o_proj.weight", "F8_E4M3", [8, 32], o_w),
        ("model.layers.39.self_attn.o_proj.weight_scale", "U8", [8, 1], o_s),
        ("lm_head.weight", "F8_E4M3", [16, 8], head_w),
        ("lm_head.weight_scale", "U8", [16, 1], head_s),
    ])
    write_safetensors(base / "model-00003-of-00004.safetensors", [
        ("model.layers.40.mlp.shared_experts.down_proj.weight", "F8_E4M3", [8, 16], sh_w),
        ("model.layers.40.mlp.shared_experts.down_proj.weight_scale", "F32", [1, 1, 1, 1], sh_s),
        ("model.layers.40.input_layernorm.weight", "BF16", [8], norm),
    ])
    # Layer 42 is a KDA attention block (it has f_a_proj): Hyperflare's side-chain kernel needs
    # its q/k/v to stay the MXFP8 group, so the hybrid's requant of k_proj must not become BF16.
    write_safetensors(base / "model-00004-of-00004.safetensors", [
        ("model.layers.41.mlp.gate.weight", "BF16", [4, 4], gate),
        ("model.layers.42.self_attn.k_proj.weight", "F8_E4M3", [8, 16], kda_k),
        ("model.layers.42.self_attn.k_proj.weight_scale", "U8", [8, 1], kda_s),
        ("model.layers.42.self_attn.f_a_proj.weight", "BF16", [4, 4], kda_fa),
        # Layer 43 is an MLA block: Hyperflare reads q_b_proj.out_features, a quantized linear's.
        ("model.layers.43.self_attn.q_b_proj.weight", "F8_E4M3", [8, 16], mla_qb),
        ("model.layers.43.self_attn.q_b_proj.weight_scale", "U8", [8, 1], mla_s),
    ])
    # FP4-Local keeps some tensors in a subdirectory shard (tensors/native-QB.safetensors on
    # the real checkpoint): the index names it, so the output must carry it.
    (base / "tensors").mkdir()
    write_safetensors(base / "tensors/native-QB.safetensors", [
        ("model.layers.0.self_attn.b_proj.weight", "BF16", [4, 2], native),
    ])
    # A fetch leaves residue directories that are not part of the checkpoint.
    (base / ".cache").mkdir()
    (base / ".cache/residue.lock").write_text("residue")

    index = {"metadata": {"total_size": 1}, "weight_map": {
        "model.layers.40.self_attn.q_proj.weight": "model-00001-of-00004.safetensors",
        "model.layers.40.self_attn.q_proj.weight_scale": "model-00001-of-00004.safetensors",
        "model.layers.40.mlp.experts.0.down_proj": "model-00001-of-00004.safetensors",
        "model.layers.39.self_attn.o_proj.weight": "model-00002-of-00004.safetensors",
        "model.layers.39.self_attn.o_proj.weight_scale": "model-00002-of-00004.safetensors",
        "lm_head.weight": "model-00002-of-00004.safetensors",
        "lm_head.weight_scale": "model-00002-of-00004.safetensors",
        "model.layers.40.mlp.shared_experts.down_proj.weight": "model-00003-of-00004.safetensors",
        "model.layers.40.mlp.shared_experts.down_proj.weight_scale": "model-00003-of-00004.safetensors",
        "model.layers.40.input_layernorm.weight": "model-00003-of-00004.safetensors",
        "model.layers.41.mlp.gate.weight": "model-00004-of-00004.safetensors",
        "model.layers.0.self_attn.b_proj.weight": "tensors/native-QB.safetensors",
        "model.layers.42.self_attn.k_proj.weight": "model-00004-of-00004.safetensors",
        "model.layers.42.self_attn.k_proj.weight_scale": "model-00004-of-00004.safetensors",
        "model.layers.42.self_attn.f_a_proj.weight": "model-00004-of-00004.safetensors",
        "model.layers.43.self_attn.q_b_proj.weight": "model-00004-of-00004.safetensors",
        "model.layers.43.self_attn.q_b_proj.weight_scale": "model-00004-of-00004.safetensors",
    }}
    (base / "model.safetensors.index.json").write_text(json.dumps(index))
    (base / "config.json").write_text(json.dumps({
        "quantization_config": {
            "quant_method": "modelopt", "quant_algo": "MIXED_PRECISION",
            "exclude_modules": ["model.visual"],
            "quantized_layers": {
                "model.layers.40.self_attn.q_proj": {"quant_algo": "MXFP8"},
                "model.layers.39.self_attn.o_proj": {"quant_algo": "MXFP8"},
                "lm_head": {"quant_algo": "MXFP8"},
                "model.layers.40.mlp.shared_experts.down_proj": {"quant_algo": "FP8_PB_WO"},
                "model.layers.42.self_attn.k_proj": {"quant_algo": "MXFP8"},
                "model.layers.43.self_attn.q_b_proj": {"quant_algo": "MXFP8"},
            },
        },
    }))

    # The cyber repo's donor shards, real safetensors files the fake remote serves byte ranges
    # of (as HTTP does: file-absolute). Each shard opens with a tensor that is not selected, so
    # a data-relative range read as a file range lands in the header or that neighbour -- the
    # bug that made the first BF16 builds generate gibberish.
    donor = root / "donor"
    donor.mkdir()
    sources = {
        "model.layers.40.self_attn.q_proj.weight": payload("src-q", 512),
        "model.layers.39.self_attn.o_proj.weight": payload("src-o", 512),
        "lm_head.weight": payload("src-h", 256),
        "model.layers.40.mlp.shared_experts.down_proj.weight": payload("src-s", 256),
        "model.layers.42.self_attn.k_proj.weight": payload("src-k", 256),
        "model.layers.43.self_attn.q_b_proj.weight": payload("src-qb", 256),
        "model.layers.38.self_attn.v_proj.weight": payload("src-v", 512),
    }
    donor_layout = {
        "donor-00001.safetensors": [("model.embed_tokens.weight", "BF16", [64], payload("emb", 128)),
                                    "model.layers.40.self_attn.q_proj.weight",
                                    "model.layers.39.self_attn.o_proj.weight", "lm_head.weight"],
        "donor-00002.safetensors": [("model.layers.40.input_layernorm.weight", "F32", [8], payload("ln", 32)),
                                    "model.layers.40.mlp.shared_experts.down_proj.weight",
                                    "model.layers.42.self_attn.k_proj.weight",
                                    "model.layers.43.self_attn.q_b_proj.weight",
                                    "model.layers.38.self_attn.v_proj.weight"],
    }
    donor_source: dict[str, dict] = {}
    for shard, tensors in donor_layout.items():
        rows = [t if isinstance(t, tuple) else (t, "BF16", [len(sources[t]) // 2], sources[t]) for t in tensors]
        write_safetensors(donor / shard, rows, metadata={"format": "pt"})
        length, header = mod.read_header(donor / shard)
        for name in tensors:
            if isinstance(name, str):
                begin, end = header[name]["data_offsets"]
                donor_source[name] = {"shard": shard, "begin": begin, "end": end, "dtype": "BF16",
                                      "data_start": 8 + length}

    def entry(tensor, shard, shape, storage):
        return {"tensor": tensor, "shard": shard, "begin": 0, "end": 0, "dtype": "F8_E4M3",
                "shape": shape, "storage": storage, "action": "requant",
                "source": donor_source[tensor],
                "scale": {"tensor": tensor.replace(".weight", ".weight_scale"),
                          "shard": shard, "begin": 0, "end": 0, "dtype": "F32", "shape": []}}

    plan = {"base_repo": "base/repo", "cyber_repo": "cyber/repo", "stats": {}, "entries": [
        entry("model.layers.40.self_attn.q_proj.weight", "model-00001-of-00004.safetensors", [8, 32], "mx8"),
        entry("model.layers.39.self_attn.o_proj.weight", "model-00002-of-00004.safetensors", [8, 32], "mx8"),
        entry("lm_head.weight", "model-00002-of-00004.safetensors", [16, 8], "mx8"),
        entry("model.layers.40.mlp.shared_experts.down_proj.weight", "model-00003-of-00004.safetensors", [8, 16], "block8"),
        entry("model.layers.42.self_attn.k_proj.weight", "model-00004-of-00004.safetensors", [8, 16], "mx8"),
        entry("model.layers.43.self_attn.q_b_proj.weight", "model-00004-of-00004.safetensors", [8, 16], "mx8"),
        dict(entry("model.layers.38.self_attn.v_proj.weight", "model-00002-of-00004.safetensors", [8, 32], "mx8"),
             action="copy"),
    ]}
    receipt = {"repos": {}, "stats": {}, "patched": [
        {"tensor": e["tensor"], "action": e["action"], "rel_error": 0.01, "max_abs_error": 0.01,
         "repaired": 0, "peak_ratio": 1.0} for e in plan["entries"]]}

    return {"base": base, "donor": donor, "plan": plan, "receipt": receipt, "sources": sources,
            "raw": {"q_w": q_w, "q_s": q_s, "o_w": o_w, "head_w": head_w, "sh_w": sh_w,
                    "expert": expert, "norm": norm, "gate": gate, "native": native}}


def load_plan_bf16(root: Path, fixture: dict, min_layer: int = 40, keep_fp8: list[str] | None = None,
                   name: str = "bf16-plan.json") -> Path:
    """Run the real plan command against the fixture and return the bf16 plan path."""
    plan_path = root / "hybrid-plan.json"
    plan_path.write_text(json.dumps(fixture["plan"]))
    receipt_path = root / "hybrid-receipt.json"
    receipt_path.write_text(json.dumps(fixture["receipt"]))
    out = root / name
    code = mod.cmd_plan(argparse_ns(base=fixture["base"], plan=plan_path, receipt=receipt_path,
                                    min_layer=min_layer, keep_fp8=keep_fp8 or [], out=out))
    assert code == 0
    return out


def argparse_ns(**kwargs):
    import argparse
    return argparse.Namespace(**kwargs)


# --- pure functions --------------------------------------------------------------------

def test_selection(fixture):
    kda = mod.kernel_fp8_prefixes(json.loads(
        (fixture["base"] / "model.safetensors.index.json").read_text())["weight_map"])
    check(kda == {"model.layers.42.self_attn.q_proj", "model.layers.42.self_attn.k_proj",
                  "model.layers.42.self_attn.v_proj", "model.layers.43.self_attn.q_b_proj"},
          f"FP8-bound: q/k/v of KDA blocks (they have f_a_proj) and every MLA q_b_proj (got {sorted(kda)})")
    check(mod.kernel_fp8_prefixes(["a.self_attn.q_proj.weight", "a.self_attn.f_b_proj.weight"]) == set(),
          "no f_a_proj and no q_b_proj: nothing FP8-bound")
    selected = mod.select_entries(fixture["plan"], fixture["receipt"], 40, keep_fp8=kda)
    names = {e["tensor"] for e in selected}
    check("model.layers.40.self_attn.q_proj.weight" in names, "late requant selected")
    check("lm_head.weight" in names, "lm_head selected")
    check("model.layers.40.mlp.shared_experts.down_proj.weight" in names, "block8 late selected")
    check("model.layers.39.self_attn.o_proj.weight" not in names, "early layer excluded")
    check("model.layers.38.self_attn.v_proj.weight" not in names, "copy action excluded")
    check("model.layers.42.self_attn.k_proj.weight" not in names, "KDA q/k/v kept FP8")
    check("model.layers.43.self_attn.q_b_proj.weight" not in names, "MLA q_b_proj kept FP8")
    check(len(names) == 3, f"selection count is 3, got {len(names)}")
    unkept = mod.select_entries(fixture["plan"], fixture["receipt"], 40, keep_fp8=set())
    check("model.layers.42.self_attn.k_proj.weight" in {e["tensor"] for e in unkept},
          "keep_fp8 is the only thing holding the KDA k_proj back")
    early = mod.select_entries(fixture["plan"], fixture["receipt"], 0, keep_fp8=kda)
    check(len({e["tensor"] for e in early}) == 4, "min_layer 0 includes the early layer")
    check(mod.layer_of("model.layers.41.x.weight") == 41, "layer_of parses")
    check(mod.layer_of("lm_head.weight") is None, "layer_of None for the head")
    check(mod.prefix_of("lm_head.weight") == "lm_head", "prefix_of")
    check(mod.scale_of("lm_head") == "lm_head.weight_scale", "scale_of")
    check_raises("prefix_of rejects non-weights", lambda: mod.prefix_of("lm_head.weight_scale"))

    # Operator holds: a pattern matches a whole prefix, never a substring of one.
    patterns = mod.parse_keep_patterns([r"lm_head", r".*\.shared_experts\..*"])
    prefixes = {"lm_head", "model.layers.40.mlp.shared_experts.down_proj", "model.layers.40.self_attn.q_proj"}
    check(mod.held_prefixes(prefixes, patterns) == {"lm_head", "model.layers.40.mlp.shared_experts.down_proj"},
          "held_prefixes: whole-prefix matches only")
    check(mod.held_prefixes(prefixes, mod.parse_keep_patterns([r"q_proj"])) == set(),
          "held_prefixes: a substring is not a whole-prefix match")
    check(mod.held_prefixes(prefixes, []) == set(), "no patterns hold nothing")
    check_raises("a pattern that does not compile is refused", lambda: mod.parse_keep_patterns(["(unclosed"]))


def test_plan_holds(root, fixture):
    """--keep-fp8 holds matching prefixes in the base's FP8 and records why."""
    held = load_plan_bf16(root, fixture, keep_fp8=[r"lm_head"], name="bf16-plan-held.json")
    plan = json.loads(held.read_text())
    names = {e["tensor"] for e in plan["selected"]}
    check("lm_head.weight" not in names, "a held prefix leaves the selection")
    check(len(names) == 2, f"the rest of the selection is unchanged (got {sorted(names)})")
    check(plan["keep_fp8_patterns"] == ["lm_head"], "the plan records the operator's patterns")
    check(plan["kept_fp8"] == ["lm_head", "model.layers.42.self_attn.k_proj",
                               "model.layers.43.self_attn.q_b_proj"],
          "kept_fp8 lists held and kernel-bound prefixes together")
    check_raises("a held pattern that does not compile fails the plan",
                 lambda: load_plan_bf16(root, fixture, keep_fp8=["(unclosed"], name="bf16-plan-bad.json"))


def test_dequantizable(fixture, root):
    _, headers = mod.read_header(fixture["base"] / "model-00001-of-00004.safetensors")
    entry = next(e for e in fixture["plan"]["entries"] if e["tensor"].endswith("q_proj.weight"))
    mod.dequantizable(entry, headers)
    check(True, "dequantizable accepts a well-formed entry")
    check_raises("missing scale detected", lambda: mod.dequantizable(entry, {}))
    bad_dtype = dict(entry, dtype="BF16")
    check_raises("non-FP8 base weight detected",
                 lambda: mod.dequantizable(bad_dtype, {entry["tensor"]: {"dtype": "BF16"}}))
    short = json.loads(json.dumps(entry))
    short["source"]["end"] -= 2
    check_raises("short source range detected", lambda: mod.dequantizable(short, headers))
    stale = json.loads(json.dumps(entry))
    del stale["source"]["data_start"]
    check_raises("a source without data_start (pre-fix plan) is refused at plan time",
                 lambda: mod.dequantizable(stale, headers))


def test_sources(fixture):
    """A plan source is a SourceRange: data-relative offsets plus where the data section starts,
    confirmed against the donor shard's own header before any byte is fetched."""
    tensor = "lm_head.weight"
    raw = fixture["plan"]["entries"][2]["source"]
    source = mod.parse_source(tensor, raw)
    length, header = mod.read_header(fixture["donor"] / raw["shard"])
    check(source == mod.SourceRange(raw["shard"], raw["begin"], raw["end"], 8 + length),
          "parse_source keeps shard, data-relative offsets and data_start")
    check(source.file_range == (8 + length + raw["begin"], 8 + length + raw["end"]),
          "file_range is data_start + data_offsets")
    check(source.nbytes == 256, "nbytes is the tensor's span")
    donor_bytes = (fixture["donor"] / raw["shard"]).read_bytes()
    check(donor_bytes[slice(*source.file_range)] == fixture["sources"][tensor],
          "the file range holds exactly the donor tensor")
    check(donor_bytes[raw["begin"]:raw["end"]] != fixture["sources"][tensor],
          "the data-relative range read from the file is NOT the tensor (the bug this guards)")
    for label, mutation in (("no data_start", lambda r: r.pop("data_start")),
                            ("data_start inside the length prefix", lambda r: r.update(data_start=4)),
                            ("not BF16", lambda r: r.update(dtype="F8_E4M3")),
                            ("string offset", lambda r: r.update(begin="0")),
                            ("bool offset", lambda r: r.update(end=True)),
                            ("negative begin", lambda r: r.update(begin=-2)),
                            ("end before begin", lambda r: r.update(end=raw["begin"] - 2)),
                            ("no shard", lambda r: r.update(shard=""))):
        broken = dict(raw)
        mutation(broken)
        check_raises(f"parse_source refuses: {label}", lambda b=broken: mod.parse_source(tensor, b))

    check(mod.confirm_source(tensor, source, length, header) == source,
          "confirm_source returns the source the donor header agrees with")
    shifted = mod.SourceRange(source.shard, source.begin + 2, source.end + 2, source.data_start)
    for label, operation in (
            ("a different data section start", lambda: mod.confirm_source(tensor, source, length + 8, header)),
            ("offsets the header does not hold", lambda: mod.confirm_source(tensor, shifted, length, header)),
            ("a tensor the shard lacks", lambda: mod.confirm_source("model.missing.weight", source, length, header)),
            ("a non-BF16 donor tensor", lambda: mod.confirm_source(
                tensor, source, length, {**header, tensor: {**header[tensor], "dtype": "F32"}}))):
        check_raises(f"confirm_source refuses {label}", operation)


def test_header_surgery():
    header = {
        "__metadata__": {"format": "pt"},
        "a.weight": {"dtype": "F8_E4M3", "shape": [4], "data_offsets": [0, 4]},
        "a.weight_scale": {"dtype": "U8", "shape": [1], "data_offsets": [4, 5]},
        "b.weight": {"dtype": "BF16", "shape": [2], "data_offsets": [5, 9]},
    }
    data_start = 8 + len(mod.serialize_header(header))
    new, copy_map = mod.rewrite_header(header, {"a.weight": payload("r", 8)}, {"a.weight_scale"}, data_start)
    check(new["a.weight"]["dtype"] == "BF16" and new["a.weight"]["data_offsets"] == [0, 8],
          "replacement lands first at offset 0 as BF16")
    check("a.weight_scale" not in new, "dropped scale leaves the header")
    check(new["b.weight"]["data_offsets"] == [8, 12], "later tensor shifts past the replacement")
    check(new["b.weight"]["dtype"] == "BF16", "untouched dtype preserved")
    check(new["__metadata__"] == {"format": "pt"}, "metadata preserved")
    check(copy_map == {"b.weight": (data_start + 5, data_start + 9)},
          "copy map carries the file-absolute source range")
    serialized = mod.serialize_header(new)
    (length,) = struct.unpack("<Q", serialized[:8])
    check((8 + length) % 8 == 0, "data section starts 8-byte aligned")
    check(len(serialized) == 8 + length, "padding length is consistent")

    roundtrip = tempfile.TemporaryDirectory()
    path = Path(roundtrip.name) / "t.safetensors"
    with path.open("wb") as handle:
        handle.write(serialized)
        handle.write(payload("r", 8))
        handle.write(payload("b", 4))
    read_len, read_header = mod.read_header(path)
    check(read_len == length and read_header["a.weight"]["data_offsets"] == [0, 8],
          "read_header round-trips the written file")
    shutil.rmtree(roundtrip.name)


def test_index_and_config(fixture):
    index = {"metadata": {"total_size": 5}, "weight_map": {
        "lm_head.weight": "s0", "lm_head.weight_scale": "s0", "keep.weight": "s1"}}
    index["metadata"]["note"] = "kept"
    rewritten = mod.rewrite_index(index, {"lm_head.weight_scale"}, total_size=9)
    check("lm_head.weight_scale" not in rewritten["weight_map"], "scale dropped from the index")
    check(rewritten["weight_map"]["lm_head.weight"] == "s0", "weight keeps its shard")
    check(rewritten["weight_map"]["keep.weight"] == "s1", "unrelated tensors kept")
    check(rewritten["metadata"] == {"total_size": 9, "note": "kept"},
          "total_size is the rewritten payload size; other metadata preserved")
    check(index["metadata"]["total_size"] == 5, "input index not mutated")
    check(mod.payload_bytes([{"__metadata__": {}, "a": {"data_offsets": [0, 4]}},
                             {"b": {"data_offsets": [0, 6]}, "c": {"data_offsets": [6, 7]}}]) == 11,
          "payload_bytes sums every tensor's span across shards, metadata excluded")

    config = json.loads((fixture["base"] / "config.json").read_text())
    patched = mod.patch_config(config, {"lm_head", "model.layers.40.self_attn.q_proj"})
    layers = patched["quantization_config"]["quantized_layers"]
    check("lm_head" not in layers and "model.layers.40.self_attn.q_proj" not in layers,
          "selected prefixes removed from the declaration")
    check("model.layers.39.self_attn.o_proj" in layers, "other declarations preserved")
    check(config["quantization_config"]["quantized_layers"].get("lm_head") is not None,
          "input config not mutated")
    check_raises("undeclared prefix refused", lambda: mod.patch_config(config, {"nope"}))


# --- build + verify end-to-end -------------------------------------------------------------

def test_build_and_verify(root, fixture):
    saved_remote = mod.remote_bytes
    calls: list[tuple[str, int, int]] = []

    def fake_remote(repo, shard, begin, end):
        """The cyber repo over HTTP: file-absolute byte ranges of the donor shard files."""
        if repo != "cyber/repo":
            raise ValueError(f"fetch from {repo}, expected the cyber repo")
        calls.append((shard, begin, end))
        data = (fixture["donor"] / shard).read_bytes()
        if not 0 <= begin <= end <= len(data):
            raise ValueError(f"{shard}[{begin}:{end}] is outside the {len(data)}-byte file")
        return data[begin:end]

    mod.remote_bytes = fake_remote
    try:
        build_and_verify(root, fixture, calls)
    finally:
        mod.remote_bytes = saved_remote


def build_and_verify(root, fixture, calls):
    plan_bf16 = load_plan_bf16(root, fixture)
    selected = {e["tensor"]: mod.parse_source(e["tensor"], e["source"])
                for e in json.loads(plan_bf16.read_text())["selected"]}
    cache = root / "cache"
    out = root / "out"
    header_reads = set()
    for shard in {source.shard for source in selected.values()}:
        length, _ = mod.read_header(fixture["donor"] / shard)
        header_reads |= {(shard, 0, 8), (shard, 8, 8 + length)}

    # A plan written before data_start existed is refused before anything is fetched or written.
    stale_plan = json.loads(plan_bf16.read_text())
    for entry in stale_plan["selected"]:
        del entry["source"]["data_start"]
    stale_path = root / "bf16-plan-stale.json"
    stale_path.write_text(json.dumps(stale_plan))
    check_raises("build refuses a plan without data_start",
                 lambda: mod.build(fixture["base"], stale_path, cache, root / "hybrid-receipt.json", out))
    check(not out.exists() and not calls, "the refused plan wrote nothing and fetched nothing")

    # A plan whose range disagrees with the donor header is refused before any tensor byte moves.
    lying_plan = json.loads(plan_bf16.read_text())
    lying_plan["selected"][0]["source"]["begin"] += 2
    lying_plan["selected"][0]["source"]["end"] += 2
    lying_path = root / "bf16-plan-lying.json"
    lying_path.write_text(json.dumps(lying_plan))
    check_raises("build refuses a range the donor header does not hold",
                 lambda: mod.build(fixture["base"], lying_path, cache, root / "hybrid-receipt.json", out))
    check(not out.exists() and set(calls) <= header_reads, "only headers were read for the refused plan")
    calls.clear()

    # Bytes cached under the old tensor-only key (data-relative, wrong) are never reused.
    cache.mkdir()
    (cache / "lm_head.weight.bf16").write_bytes(b"\0" * 256)

    stats = mod.build(fixture["base"], plan_bf16, cache, root / "hybrid-receipt.json", out)
    check(stats["shards_rewritten"] == 3 and stats["shards_shared"] == 2,
          f"3 shards rewritten, 2 shared (got {stats})")
    check((out / "tensors/native-QB.safetensors").read_bytes()
          == (fixture["base"] / "tensors/native-QB.safetensors").read_bytes(),
          "the subdirectory shard the index names is carried, byte-identical")
    check(not (out / ".cache").exists(), "fetch residue directories are not carried")
    data_fetches = sorted(call for call in calls if call not in header_reads)
    check(data_fetches == sorted((s.shard, *s.file_range) for s in selected.values()),
          f"one fetch per selected tensor, each at its file range (got {data_fetches})")
    check(sorted(call for call in calls if call in header_reads) == sorted(header_reads),
          "each donor shard's header is read once")
    for tensor, source in selected.items():
        check(mod.cache_path(cache, tensor, source).read_bytes() == fixture["sources"][tensor],
              f"cache holds the donor tensor itself: {tensor}")
    check((cache / "lm_head.weight.bf16").read_bytes() == b"\0" * 256,
          "the old-key cache file is left alone, not read")

    _, q_header = mod.read_header(out / "model-00001-of-00004.safetensors")
    check(q_header["model.layers.40.self_attn.q_proj.weight"]["dtype"] == "BF16",
          "q_proj stored as BF16")
    check("model.layers.40.self_attn.q_proj.weight_scale" not in q_header,
          "q_proj scale dropped")
    _, expert_meta = q_header["model.layers.40.mlp.experts.0.down_proj"], None
    check("model.layers.40.mlp.experts.0.down_proj" in q_header, "expert tensor kept")
    with (out / "model-00001-of-00004.safetensors").open("rb") as handle:
        handle.seek(8 + mod.header_len(q_header) + q_header["model.layers.40.mlp.experts.0.down_proj"]["data_offsets"][0])
        stored_expert = handle.read(32)
    check(stored_expert == fixture["raw"]["expert"], "expert bytes untouched")

    _, head_header = mod.read_header(out / "model-00002-of-00004.safetensors")
    check(head_header["lm_head.weight"]["dtype"] == "BF16", "lm_head stored as BF16")
    with (out / "model-00002-of-00004.safetensors").open("rb") as handle:
        handle.seek(8 + mod.header_len(head_header) + head_header["lm_head.weight"]["data_offsets"][0])
        stored_head = handle.read(256)
    check(stored_head == fixture["sources"]["lm_head.weight"], "lm_head bytes equal the source")
    with (out / "model-00002-of-00004.safetensors").open("rb") as handle:
        begin = head_header["model.layers.39.self_attn.o_proj.weight"]["data_offsets"][0]
        handle.seek(8 + mod.header_len(head_header) + begin)
        stored_o = handle.read(512)
    check(stored_o == fixture["raw"]["o_w"], "early o_proj bytes untouched after resharding")

    _, sh_header = mod.read_header(out / "model-00003-of-00004.safetensors")
    check(sh_header["model.layers.40.mlp.shared_experts.down_proj.weight"]["dtype"] == "BF16",
          "shared_experts stored as BF16")
    check("model.layers.40.mlp.shared_experts.down_proj.weight_scale" not in sh_header,
          "block8 scale dropped")
    with (out / "model-00003-of-00004.safetensors").open("rb") as handle:
        begin = sh_header["model.layers.40.input_layernorm.weight"]["data_offsets"][0]
        handle.seek(8 + mod.header_len(sh_header) + begin)
        stored_norm = handle.read(16)
    check(stored_norm == fixture["raw"]["norm"], "layernorm bytes untouched")

    plan_written = json.loads(plan_bf16.read_text())
    check(plan_written["kept_fp8"] == ["model.layers.42.self_attn.k_proj", "model.layers.43.self_attn.q_b_proj"],
          "the plan records which selectable tensors were kept FP8 for Hyperflare's kernels")
    declared = json.loads((out / "config.json").read_text())["quantization_config"]["quantized_layers"]
    check("model.layers.42.self_attn.k_proj" in declared, "KDA k_proj still declared quantized")
    _, kda_header = mod.read_header(out / "model-00004-of-00004.safetensors")
    check(kda_header["model.layers.42.self_attn.k_proj.weight"]["dtype"] == "F8_E4M3"
          and "model.layers.42.self_attn.k_proj.weight_scale" in kda_header,
          "KDA k_proj stays FP8 with its scale")

    _, gate_header = mod.read_header(out / "model-00004-of-00004.safetensors")
    check(gate_header == {k: v for k, v in
                          mod.read_header(fixture["base"] / "model-00004-of-00004.safetensors")[1].items()},
          "shared shard header identical")
    check((out / "model-00004-of-00004.safetensors").read_bytes()
          == (fixture["base"] / "model-00004-of-00004.safetensors").read_bytes(),
          "shared shard byte-identical")

    out_index = json.loads((out / "model.safetensors.index.json").read_text())
    check(all(not n.endswith("weight_scale") for n in out_index["weight_map"]
              if n.startswith(("lm_head", "model.layers.40.self_attn.q_proj",
                               "model.layers.40.mlp.shared_experts.down_proj"))),
          "selected scales gone from the index")
    check(out_index["weight_map"]["model.layers.39.self_attn.o_proj.weight_scale"]
          == "model-00002-of-00004.safetensors", "unselected scale kept in the index")
    # Hyperflare's inspect_indexed_checkpoint: total_size == sum of every tensor's bytes.
    payload = sum(end - begin
                  for shard in sorted(set(out_index["weight_map"].values()))
                  for name, meta in mod.read_header(out / shard)[1].items() if name != "__metadata__"
                  for begin, end in [meta["data_offsets"]])
    check(out_index["metadata"]["total_size"] == payload,
          f"index total_size is the output's payload bytes ({out_index['metadata']['total_size']} vs {payload})")
    out_config = json.loads((out / "config.json").read_text())
    check("lm_head" not in out_config["quantization_config"]["quantized_layers"],
          "lm_head de-declared")
    check(out_config["quantization_config"]["quantized_layers"]
          .get("model.layers.39.self_attn.o_proj") is not None, "early declaration kept")
    receipt = json.loads((out / "hybrid-receipt.json").read_text())
    check(receipt["bf16"]["selected"] == 3 and receipt["bf16"]["min_layer"] == 40,
          "receipt records the bf16 build")
    check(receipt["bf16"]["kept_fp8"] == plan_written["kept_fp8"] and receipt["bf16"]["keep_fp8_patterns"] == [],
          "receipt records what the build held in FP8 and the operator patterns behind it")

    check_raises("build refuses an existing output",
                 lambda: mod.build(fixture["base"], plan_bf16, cache,
                                   root / "hybrid-receipt.json", out))
    check(mod.index_files({"weight_map": {"a": "s2", "b": "tensors/q", "c": "s2"}}) == ["s2", "tensors/q"],
          "index_files: each named file once, sorted, subdirectories kept")

    calls.clear()
    mod.verify(fixture["base"], plan_bf16, cache, out)
    check(set(calls) <= header_reads, "verify passes, re-reading only headers: the cache serves the bytes")

    # --- mutations on scratch copies of the OUTPUT ------------------------------------
    def mutate(action):
        scratch = root / f"mutated-{action.__name__}"
        if scratch.exists():
            shutil.rmtree(scratch)
        shutil.copytree(out, scratch)
        action(scratch)
        try:
            mod.verify(fixture["base"], plan_bf16, cache, scratch)
        except (ValueError, KeyError):
            return True
        return False

    def corrupt_bf16(scratch):
        shard = scratch / "model-00001-of-00004.safetensors"
        data = bytearray(shard.read_bytes())
        _, header = mod.read_header(shard)
        begin = 8 + mod.header_len(header) + header["model.layers.40.self_attn.q_proj.weight"]["data_offsets"][0]
        data[begin] ^= 0xFF
        shard.write_bytes(bytes(data))

    def resurrect_scale(scratch):
        index = json.loads((scratch / "model.safetensors.index.json").read_text())
        index["weight_map"]["lm_head.weight_scale"] = "model-00002-of-00004.safetensors"
        (scratch / "model.safetensors.index.json").write_text(json.dumps(index))

    def resurrect_declaration(scratch):
        config = json.loads((scratch / "config.json").read_text())
        config["quantization_config"]["quantized_layers"]["lm_head"] = {"quant_algo": "MXFP8"}
        (scratch / "config.json").write_text(json.dumps(config))

    def tamper_shared(scratch):
        shard = scratch / "model-00004-of-00004.safetensors"
        data = bytearray(shard.read_bytes())
        data[-1] ^= 0xFF
        shard.write_bytes(bytes(data))

    def drop_shard(scratch):
        (scratch / "model-00003-of-00004.safetensors").unlink()

    def drop_subdir_shard(scratch):
        (scratch / "tensors/native-QB.safetensors").unlink()

    def stale_total_size(scratch):
        index = json.loads((scratch / "model.safetensors.index.json").read_text())
        index["metadata"]["total_size"] = 1
        (scratch / "model.safetensors.index.json").write_text(json.dumps(index))

    def overlap_offsets(scratch):
        shard = scratch / "model-00002-of-00004.safetensors"
        _, header = mod.read_header(shard)
        header["lm_head.weight"]["data_offsets"] = [0, 256]
        data_start = 8 + mod.header_len(header)
        original = shard.read_bytes()
        with shard.open("wb") as handle:
            handle.write(mod.serialize_header(header))
            handle.write(original[data_start:])

    def wrong_shard_point(scratch):
        index = json.loads((scratch / "model.safetensors.index.json").read_text())
        index["weight_map"]["lm_head.weight"] = "model-00001-of-00004.safetensors"
        (scratch / "model.safetensors.index.json").write_text(json.dumps(index))

    for action, label in ((corrupt_bf16, "corrupted BF16 weight"),
                          (resurrect_scale, "resurrected scale"),
                          (resurrect_declaration, "resurrected declaration"),
                          (tamper_shared, "tampered shared shard"),
                          (drop_shard, "missing shard"),
                          (drop_subdir_shard, "missing subdirectory shard"),
                          (stale_total_size, "index total_size not the payload size"),
                          (overlap_offsets, "overlapping offsets"),
                          (wrong_shard_point, "wrong shard pointer")):
        check(mutate(action), f"verify catches: {label}")


def main() -> int:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        fixture = build_fixture(root)
        test_selection(fixture)
        test_plan_holds(root, fixture)
        test_dequantizable(fixture, root)
        test_sources(fixture)
        test_header_surgery()
        test_index_and_config(fixture)
        test_build_and_verify(root, fixture)
    print(f"glm53-bf16-dense unit: {CHECKS} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
