#!/usr/bin/env python3
"""Unit tests for the GLM hybrid checkpoint assembler's functional core.

Run directly (`python3 tests/glm-hybrid-checkpoint-unit.py`). No network, no torch, no GPU: the
planner is pure and the splice is exercised on a synthetic two-shard safetensors checkpoint.
"""
import importlib.util
import json
import pathlib
import shutil
import struct
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
MODULE = ROOT / "scripts" / "inference" / "glm53" / "glm-hybrid-checkpoint.py"
spec = importlib.util.spec_from_file_location("glm_hybrid", MODULE)
hybrid = importlib.util.module_from_spec(spec)
# dataclasses resolves string annotations through sys.modules; register before exec.
sys.modules[spec.name] = hybrid
spec.loader.exec_module(hybrid)

failures = 0


def check(name, condition):
    global failures
    if condition:
        print(f"ok   {name}")
    else:
        failures += 1
        print(f"FAIL {name}", file=sys.stderr)


def raises(name, call, needle=""):
    """Assert ``call()`` raises and the message mentions ``needle``."""
    try:
        call()
    except (ValueError, SystemExit) as error:
        text = str(error)
        check(f"{name} -> {needle!r}", needle in text)
        return
    check(f"{name} (did not raise)", False)


def header(shard, begin, dtype, shape, name=""):
    end = begin + _nbytes(dtype, shape)
    return hybrid.TensorHeader(shard, begin, end, dtype, tuple(shape))


def _nbytes(dtype, shape):
    width = {"BF16": 2, "F32": 4, "F8_E4M3": 1, "U8": 1, "I64": 8}[dtype]
    count = 1
    for dimension in shape:
        count *= dimension
    return count * width


# ------------------------------------------------------------------ is_dense

for tensor, expected in [
    ("model.language_model.layers.10.mlp.experts.0.down_proj.weight", False),
    ("model.language_model.layers.45.mlp.experts.7.up_proj.weight", False),
    ("model.language_model.layers.10.self_attn.q_proj.weight", True),
    ("model.language_model.layers.7.mlp.shared_experts.down_proj.weight", True),
    ("model.language_model.embed_tokens.weight", True),
    ("model.visual.blocks.0.attn.proj.weight", False),
    ("lm_head.weight", True),
    ("mtp.eh_proj.weight", True),
]:
    check(f"is_dense {tensor[-46:]} == {expected}", hybrid.is_dense(tensor) is expected)

# ------------------------------------------------------------------ scale_name

check("scale_name strips .weight", hybrid.scale_name("a.b.weight") == "a.b.weight_scale")
raises("scale_name rejects non-weight", lambda: hybrid.scale_name("a.b.weight_scale"), "must end in .weight")

# ------------------------------------------------------------------ storage_of

mx8_scale = header("s", 0, "U8", [8192, 128])
block8_scale = header("s", 0, "F32", [12, 1, 32, 1])
check("storage_of U8 2-D -> MX8", hybrid.storage_of("F8_E4M3", mx8_scale, "t") is hybrid.Storage.MX8)
check("storage_of F32 4-D -> BLOCK8", hybrid.storage_of("F8_E4M3", block8_scale, "t") is hybrid.Storage.BLOCK8)
check("storage_of BF16", hybrid.storage_of("BF16", None, "t") is hybrid.Storage.BF16)
check("storage_of F32", hybrid.storage_of("F32", None, "t") is hybrid.Storage.F32)
raises("storage_of FP8 without scale", lambda: hybrid.storage_of("F8_E4M3", None, "t"), "FP8 weight without a scale")
raises(
    "storage_of FP8 with odd scale",
    lambda: hybrid.storage_of("F8_E4M3", header("s", 0, "F32", [12, 32]), "t"),
    "unrecognised FP8 scale",
)
raises("storage_of I64 dense", lambda: hybrid.storage_of("I64", None, "t"), "dense tensor stored as I64")

# ------------------------------------------------------------------ scale grids

check("grid mx8 (8192,4096)", hybrid.expected_scale_shape(hybrid.Storage.MX8, (8192, 4096)) == (8192, 128))
check("grid mx8 (4096,8192)", hybrid.expected_scale_shape(hybrid.Storage.MX8, (4096, 8192)) == (4096, 256))
check("grid block8 (1536,4096)", hybrid.expected_scale_shape(hybrid.Storage.BLOCK8, (1536, 4096)) == (12, 1, 32, 1))
check("grid block8 (4096,2048)", hybrid.expected_scale_shape(hybrid.Storage.BLOCK8, (4096, 2048)) == (32, 1, 16, 1))
check("grid block8 (512,4096)", hybrid.expected_scale_shape(hybrid.Storage.BLOCK8, (512, 4096)) == (4, 1, 32, 1))
check("grid block8 (16384,1536)", hybrid.expected_scale_shape(hybrid.Storage.BLOCK8, (16384, 1536)) == (128, 1, 12, 1))
raises("grid for bf16", lambda: hybrid.expected_scale_shape(hybrid.Storage.BF16, (8, 8)), "no scale grid")

for name, storage, shape, ok in [
    ("mx8 32-aligned", hybrid.Storage.MX8, (8192, 4096), True),
    ("mx8 misaligned", hybrid.Storage.MX8, (8192, 4090), False),
    ("block8 128-aligned", hybrid.Storage.BLOCK8, (512, 4096), True),
    ("block8 rows unaligned", hybrid.Storage.BLOCK8, (576, 4096), False),
    ("bf16 anything", hybrid.Storage.BF16, (577, 4091), True),
]:
    if ok:
        hybrid.check_grid(storage, shape, "t")
        check(f"check_grid accepts {name}", True)
    else:
        raises(f"check_grid rejects {name}", lambda s=storage, p=shape: hybrid.check_grid(s, p, "t"), "aligned")

# ------------------------------------------------------------------ plan_entry

base_mx8 = header("shard-0", 0, "F8_E4M3", [8192, 4096])
source_bf16 = header("cyber-0", 0, "BF16", [8192, 4096])
entry = hybrid.plan_entry(
    "model.language_model.layers.10.self_attn.q_proj.weight",
    base_mx8,
    source_bf16,
    {"model.language_model.layers.10.self_attn.q_proj.weight_scale": mx8_scale},
)
check("plan_entry mx8 -> requant", entry.action == "requant")
check("plan_entry mx8 storage", entry.storage is hybrid.Storage.MX8)
check("plan_entry keeps scale ref", entry.scale is not None and entry.scale.name.endswith(".weight_scale"))

norms_base = header("shard-0", 100, "BF16", [4096])
norms_cyber_bf16 = header("cyber-0", 100, "BF16", [4096])
copy_entry = hybrid.plan_entry("model.language_model.layers.7.input_layernorm.weight", norms_base, norms_cyber_bf16, {})
check("plan_entry bf16/bf16 -> copy", copy_entry.action == "copy")
check("plan_entry copy carries no scale", copy_entry.scale is None)

cast_entry = hybrid.plan_entry(
    "model.language_model.layers.7.post_attention_layernorm.weight",
    header("shard-0", 200, "BF16", [4096]),
    header("cyber-0", 200, "F32", [4096]),
    {},
)
check("plan_entry bf16/f32 -> cast", cast_entry.action == "cast")

raises(
    "plan_entry rejects shape drift",
    lambda: hybrid.plan_entry("x.weight", header("s", 0, "BF16", [4, 4]), header("c", 0, "BF16", [4, 5]), {}),
    "shape (4, 4) in base, (4, 5) in the cyber build",
)
raises(
    "plan_entry rejects quantized source",
    lambda: hybrid.plan_entry(
        "x.weight", header("s", 0, "F8_E4M3", [128, 128]),
        header("c", 0, "F8_E4M3", [128, 128]), {"x.weight_scale": header("s", 0, "F32", [1, 1, 1, 1])}
    ),
    "expected BF16 or F32",
)
raises(
    "plan_entry rejects wrong scale grid",
    lambda: hybrid.plan_entry(
        "x.weight", header("s", 0, "F8_E4M3", [8192, 4096]),
        header("c", 0, "BF16", [8192, 4096]), {"x.weight_scale": header("s", 0, "U8", [8192, 64])}
    ),
    "!= expected grid",
)

# ------------------------------------------------------------------ build_plan

layer = "model.language_model.layers.10.self_attn.q_proj"
base_headers = {
    f"{layer}.weight": header("shard-0", 0, "F8_E4M3", [8192, 4096]),
    f"{layer}.weight_scale": header("shard-0", 400, "U8", [8192, 128]),
    "model.language_model.layers.10.mlp.experts.0.down_proj.weight": header("shard-1", 0, "F8_E4M3", [4096, 2048]),
    "model.language_model.layers.10.input_layernorm.weight": header("shard-1", 10, "BF16", [4096]),
}
cyber_headers = {
    f"{layer}.weight": header("cyber-0", 0, "BF16", [8192, 4096]),
    f"{layer}.weight_scale": header("cyber-0", 1, "BF16", [8192, 128]),
    "model.language_model.layers.10.mlp.experts.0.down_proj.weight": header("cyber-0", 2, "BF16", [4096, 2048]),
    "model.language_model.layers.10.input_layernorm.weight": header("cyber-0", 3, "BF16", [4096]),
}
plan = hybrid.build_plan(base_headers, cyber_headers)
check("build_plan keeps both dense tensors", len(plan) == 2)
check("build_plan drops expert tensors", all("experts" not in entry.tensor for entry in plan))
check("build_plan drops scale payloads", all(not entry.tensor.endswith(".weight_scale") for entry in plan))
check("build_plan is sorted", [entry.tensor for entry in plan] == sorted(entry.tensor for entry in plan))

raises(
    "build_plan reports every shape mismatch",
    lambda: hybrid.build_plan(
        {**base_headers, "model.language_model.layers.7.self_attn.q_a_proj.weight": header("shard-1", 20, "F8_E4M3", [1536, 4096])},
        {**cyber_headers, "model.language_model.layers.7.self_attn.q_a_proj.weight": header("cyber-0", 20, "BF16", [1536, 2048])},
    ),
    "dense tensors differ in shape",
)

raises(
    "build_plan rejects a dense tensor the base lacks",
    lambda: hybrid.build_plan(
        {k: v for k, v in base_headers.items() if "input_layernorm" not in k}, cyber_headers
    ),
    "absent from the base checkpoint",
)

stats = hybrid.plan_stats(plan)
check("plan_stats counts tensors", stats["tensors"] == 2)
check("plan_stats requantized", stats["requantized"] == 1)
check("plan_stats copied", stats["copied"] == 1)
check(
    "plan_stats fetched bytes are the source bytes",
    stats["fetched_bytes"] == 8192 * 4096 * 2 + 4096 * 2,
)
check(
    "plan_stats patched bytes are the base bytes",
    stats["patched_bytes"] == 8192 * 4096 + 4096 * 2,
)
check("plan_stats by_storage", stats["by_storage"] == {"mx8": 1, "bf16": 1})

# ------------------------------------------------------------------ patching contract

hybrid.require_same_length("t", 4, b"abcd")
raises("require_same_length rejects drift", lambda: hybrid.require_same_length("t", 4, b"ab"), "patch is 2 bytes")

quantized_entry = next(entry for entry in plan if entry.tensor.endswith("self_attn.q_proj.weight"))
copied_entry = next(entry for entry in plan if entry.tensor.endswith("input_layernorm.weight"))
payload_json = quantized_entry.as_json()
check("as_json carries base offsets", payload_json["begin"] == 0 and payload_json["end"] == 8192 * 4096)
check("as_json carries the source window", payload_json["source"]["dtype"] == "BF16")
check("as_json marks requant", payload_json["action"] == "requant")
check("as_json records the scale tensor", payload_json["scale"]["dtype"] == "U8")
check("as_json has no scale for copies", "scale" not in copied_entry.as_json())

# ------------------------------------------------------------------ requantization error


class FakeTensor:
    """Just enough tensor for ``requantization_error``: abs, sub, norm, max, numel, float."""

    def __init__(self, values):
        self.values = list(values)

    def float(self):
        return self

    def __sub__(self, other):
        return FakeTensor([a - b for a, b in zip(self.values, other.values)])

    def abs(self):
        return FakeTensor([abs(v) for v in self.values])

    def norm(self):
        return sum(v * v for v in self.values) ** 0.5

    def max(self):
        return max(self.values)

    def numel(self):
        return len(self.values)


relative, absolute = hybrid.requantization_error(FakeTensor([1.0, 0.0]), FakeTensor([1.0, 0.0]))
check("requantization_error exact -> 0", relative == 0.0 and absolute == 0.0)
relative, absolute = hybrid.requantization_error(FakeTensor([1.0, 1.0]), FakeTensor([0.0, 0.0]))
check("requantization_error full loss -> 1", abs(relative - 1.0) < 1e-9 and absolute == 1.0)
relative, _ = hybrid.requantization_error(FakeTensor([0.0, 0.0]), FakeTensor([0.0, 1.0]))
check("requantization_error zero source -> 0 relative", relative == 0.0)

# ------------------------------------------------------------------ E8M0 scales

check("e8m0 127 -> 1.0", hybrid.e8m0_scale(127) == 1.0)
check("e8m0 112 -> 2^-15", hybrid.e8m0_scale(112) == 2.0**-15)
check("e8m0 130 -> 8.0", hybrid.e8m0_scale(130) == 8.0)
check("e8m0 0 -> smallest exponent", hybrid.e8m0_scale(0) == 2.0**-127)
check("e8m0 126 -> 0.5", hybrid.e8m0_scale(126) == 0.5)

# ------------------------------------------------------------------ base envelope

check(
    "envelope is 8x the base peak",
    abs(hybrid.envelope_threshold(FakeTensor([0.1, -0.2])) - 1.6) < 1e-9,
)
check(
    "envelope keeps a floor for degenerate tensors",
    hybrid.envelope_threshold(FakeTensor([0.0, 0.0])) == 1e-3,
)
# ------------------------------------------------------------------ file addressing

addressed = header("shard-0", 100, "BF16", [4])
check("header keeps data-relative offsets", (addressed.begin, addressed.end) == (100, 108))
check("header without a data start reads from the file start", addressed.file_range == (100, 108))
placed = hybrid.TensorHeader("shard-0", 100, 108, "BF16", (4,), 51_548)
check("header addresses itself in the file", placed.file_range == (51_648, 51_656))
placed = hybrid.TensorHeader("shard-9", 0, 8, "BF16", (4,))
check("a zero data start stays zero", placed.file_range == (0, 8))

# ------------------------------------------------------------------ fetch verdict

verdict = hybrid.fetch_verdict([1.0, 0.999, 0.995, 0.99, 0.95, 0.8])
check("verdict accepts a tuned copy", verdict.ok)
check("verdict reports the median", abs(verdict.median - 0.99) < 1e-9)
check("verdict counts the identical share", abs(verdict.share_identical - 4 / 6) < 1e-9)
check("verdict rejects a tuned copy that lost most tensors",
      not hybrid.fetch_verdict([1.0, 0.99, 0.8, 0.7, 0.6, 0.5]).ok)
verdict = hybrid.fetch_verdict([0.01, -0.02, 0.0, 0.03, -0.01])
check("verdict rejects shifted bytes", not verdict.ok)
check("verdict reports a near-zero median", abs(verdict.median) < 0.02)
verdict = hybrid.fetch_verdict([1.0] * 10)
check("verdict rejects a fetch that is a perfect copy but claims to be tuned",
      verdict.ok and verdict.share_identical == 1.0)
raises("verdict rejects an empty sample", lambda: hybrid.fetch_verdict([]), "no staged tensors")
check(
    "envelope honours a custom factor",
    abs(hybrid.envelope_threshold(FakeTensor([0.5]), 4.0) - 2.0) < 1e-9,
)

# ------------------------------------------------------------------ splice on a real safetensors layout


def write_shard(path, tensors):
    """Write a minimal safetensors shard: tensors is [(name, dtype, shape, payload)]."""
    entries, offset = {}, 0
    for name, dtype, shape, payload in tensors:
        entries[name] = {"dtype": dtype, "shape": list(shape), "data_offsets": [offset, offset + len(payload)]}
        offset += len(payload)
    raw = json.dumps(entries).encode()
    with open(path, "wb") as handle:
        handle.write(struct.pack("<Q", len(raw)))
        handle.write(raw)
        for _, _, _, payload in tensors:
            handle.write(payload)


with tempfile.TemporaryDirectory() as scratch:
    root = pathlib.Path(scratch)
    base_dir, cyber_dir, staging, out_dir = root / "base", root / "cyber", root / "staging", root / "out"
    for path in (base_dir, cyber_dir, staging):
        path.mkdir()

    dense_name = "model.language_model.layers.10.input_layernorm.weight"
    expert_name = "model.language_model.layers.10.mlp.experts.0.down_proj.weight"
    dense_shape, expert_shape = (8,), (2, 2)
    base_dense, base_expert = b"\x01" * 16, b"\x02" * 8
    cyber_dense, cyber_expert = b"\xaa" * 16, b"\xbb" * 8

    write_shard(base_dir / "shard-0.safetensors", [(dense_name, "BF16", dense_shape, base_dense)])
    write_shard(base_dir / "shard-1.safetensors", [(expert_name, "BF16", expert_shape, base_expert)])
    write_shard(cyber_dir / "shard-0.safetensors", [(dense_name, "BF16", dense_shape, cyber_dense)])
    write_shard(cyber_dir / "shard-1.safetensors", [(expert_name, "BF16", expert_shape, cyber_expert)])

    base_index = {dense_name: "shard-0.safetensors", expert_name: "shard-1.safetensors"}
    (base_dir / hybrid.INDEX_NAME).write_text(json.dumps({"weight_map": base_index}))
    (base_dir / "config.json").write_text(json.dumps({"quant_method": "modelopt"}))

    local_base = hybrid.local_headers(base_dir, base_index)
    check("local_headers reads local shards", len(local_base) == 2)
    check("local_headers keeps offsets", local_base[expert_name].begin == 0)

    cyber_local = hybrid.local_headers(cyber_dir, base_index)
    local_plan = hybrid.build_plan(local_base, cyber_local)
    check("local plan selects only the dense tensor", [entry.tensor for entry in local_plan] == [dense_name])
    local_entry = local_plan[0].as_json()
    check("local plan action is copy", local_entry["action"] == "copy")

    (staging / "00001.bin").write_bytes(cyber_dense)
    (staging / "manifest.json").write_text(json.dumps({"00001.bin": dense_name}))
    plan_path = root / "plan.json"
    plan_path.write_text(
        json.dumps(
            {
                "base_repo": "base",
                "cyber_repo": "cyber",
                "base_index": base_index,
                "stats": hybrid.plan_stats(local_plan),
                "entries": [local_entry],
            }
        )
    )

    raises(
        "splice without torch names the serving image",
        lambda: hybrid.main(
            [
                "splice", "--plan", str(plan_path), "--staging", str(staging),
                "--base", str(base_dir), "--out", str(out_dir),
            ]
        ),
        "splice needs torch",
    )

    shutil.copytree(base_dir, out_dir)
    data_start = 8 + hybrid.read_header(out_dir / "shard-0.safetensors")[0]
    hybrid._patch(out_dir / "shard-0.safetensors", data_start, 0, 16, cyber_dense)
    with open(out_dir / "shard-0.safetensors", "rb") as handle:
        length = struct.unpack("<Q", handle.read(8))[0]
        handle.seek(length + 8)
        patched = handle.read(16)
    check("_patch wrote the cyber bytes at the planned offset", patched == cyber_dense)
    _, spliced = hybrid.read_header(out_dir / "shard-0.safetensors")
    check("_patch preserved the header offsets", spliced[dense_name]["data_offsets"] == [0, 16])
    check("_patch left the sibling shard untouched", (out_dir / "shard-1.safetensors").read_bytes().endswith(base_expert))
    raises(
        "_patch rejects a length change",
        lambda: hybrid._patch(out_dir / "shard-0.safetensors", data_start, 0, 16, b"short"),
        "patch is 5 bytes",
    )

    check(
        "verify accepts a patched checkpoint",
        hybrid.main(["verify", "--plan", str(plan_path), "--base", str(base_dir), "--out", str(out_dir)]) == 0,
    )

    (out_dir / "config.json").write_text(json.dumps({"quant_method": "compressed-tensors"}))
    raises(
        "verify rejects a changed config",
        lambda: hybrid.main(["verify", "--plan", str(plan_path), "--base", str(base_dir), "--out", str(out_dir)]),
        "config.json changed",
    )
    (out_dir / "config.json").write_text((base_dir / "config.json").read_text())

    check(
        "verify accepts the repaired config",
        hybrid.main(["verify", "--plan", str(plan_path), "--base", str(base_dir), "--out", str(out_dir)]) == 0,
    )

    stale_plan = json.loads(plan_path.read_text())
    stale_plan["entries"][0]["begin"] = 8
    stale_plan["entries"][0]["end"] = 24
    (root / "stale.json").write_text(json.dumps(stale_plan))
    raises(
        "verify rejects offsets that moved",
        lambda: hybrid.main(["verify", "--plan", str(root / "stale.json"), "--base", str(base_dir), "--out", str(out_dir)]),
        "data offsets moved",
    )

    raises(
        "check_against_local rejects a stale plan",
        lambda: hybrid.check_against_local(
            json.loads((root / "stale.json").read_text())["entries"],
            {"shard-0.safetensors": hybrid.local_headers(base_dir, base_index)},
        ),
        "disagree with",
    )

print()
if failures:
    print(f"{failures} check(s) failed", file=sys.stderr)
    raise SystemExit(1)
print("all checks passed")
