#!/usr/bin/env python
"""Install the pinned upstream-core-port r2.1 overlay into the served trees.

Identical policy to v11's installer: the manifest is the only install list, its
mapping/destination counts are pinned, every destination is classified as a
replacement of a base-image file or one of the ten new upstream modules, and
every installed python file must byte-compile with the image's interpreter.
r2.1 changes three overlay files and no manifest lines, so every pinned count
below is the same as v11's; a differing count means the vendored archive is not
the r2.1 overlay this installer was written for.
"""

from __future__ import annotations

import py_compile
import shutil
import sys
from pathlib import Path

OVERLAY = Path("/tmp/upstream-core-port")
EXPECTED_MAPPINGS = 99
# Upstream's MANIFEST.txt omits two files that their Dockerfile installs anyway
# via a blind `COPY upstream-core-port/r7/vllm/ -> .../vllm/`. Both replace real
# base-image files and both differ from the base, so they carry changes; listing
# them explicitly keeps this install byte-equivalent to their shipped image
# without weakening the "nothing outside the install list" guarantee.
SUPPLEMENTS = (
    "r7/vllm/third_party/flash_linear_attention/ops/fused_recurrent.py",
    "r7/vllm/third_party/flash_linear_attention/ops/fused_sigmoid_gating.py",
)
EXPECTED_DESTINATIONS = 101
EXPECTED_REPLACEMENTS = 91
EXPECTED_ADDITIONS = 10
# The three r2.1 fix sites must be present in the overlay being installed, or
# this is an r2 archive wearing an r2.1 label.
FIX_MARKERS = (
    ("upstream-g1/vllm/v1/core/kv_cache_manager.py", "VLLM_MAMBA_STATE_PROTECT_AGE"),
    ("upstream-g1/vllm/v1/core/single_type_kv_cache_manager.py", "VLLM_MAMBA_ALIGN_CAP_LEGACY"),
    ("upstream-g1/vllm/v1/core/sched/scheduler.py", "[DEFER-FREE-DRAIN]"),
)


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    stray = sorted(
        path for path in OVERLAY.rglob("*") if "__pycache__" in path.parts or path.suffix == ".pyc"
    )
    if stray:
        fail(f"overlay carries compiled artifacts: {[str(p) for p in stray[:5]]}")

    for relative, marker in FIX_MARKERS:
        if marker not in (OVERLAY / relative).read_text():
            fail(f"overlay file {relative} lacks the r2.1 fix marker {marker!r}")

    mappings: list[tuple[Path, Path]] = []
    for line in (OVERLAY / "MANIFEST.txt").read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "->" not in line:
            continue
        source, destination = (part.strip() for part in line.split("->", 1))
        mappings.append((OVERLAY / source, Path(destination)))

    if len(mappings) != EXPECTED_MAPPINGS:
        fail(f"expected {EXPECTED_MAPPINGS} overlay mappings, parsed {len(mappings)}")

    for relative in SUPPLEMENTS:
        # r7/vllm/<path> installs to /opt/infernal-invocation/vllm/vllm/<path>.
        mappings.append(
            (
                OVERLAY / relative,
                Path("/opt/infernal-invocation/vllm/vllm") / relative.split("r7/vllm/", 1)[1],
            )
        )

    destinations = {destination for _, destination in mappings}
    if len(destinations) != EXPECTED_DESTINATIONS:
        fail(f"expected {EXPECTED_DESTINATIONS} unique destinations, parsed {len(destinations)}")

    mapped = {source.resolve() for source, _ in mappings}
    shipped = {
        path.resolve()
        for path in OVERLAY.rglob("*")
        if path.is_file() and path.name != "MANIFEST.txt"
    }
    unmapped = sorted(str(path) for path in shipped - mapped)
    if unmapped:
        fail(f"overlay ships files absent from the manifest: {unmapped[:5]}")

    replacements = 0
    additions: list[str] = []
    for source, destination in mappings:
        if not source.is_file():
            fail(f"manifest names a missing overlay file: {source}")
        if destination.is_file():
            replacements += 1
        else:
            # The port introduces upstream modules (dcp/pcp ops, kv_cache_layout,
            # recoverssm, batch_shard, adaptive_verification). Each must land in
            # a package the base image already ships.
            if not destination.parent.is_dir():
                fail(f"new overlay module has no base package: {destination}")
            additions.append(str(destination))
        shutil.copyfile(source, destination)

    if replacements != EXPECTED_REPLACEMENTS:
        fail(f"expected {EXPECTED_REPLACEMENTS} base-file replacements, applied {replacements}")
    if len(additions) != EXPECTED_ADDITIONS:
        fail(f"expected {EXPECTED_ADDITIONS} new modules, applied {len(additions)}: {additions}")

    compiled = 0
    for _, destination in mappings:
        if destination.suffix == ".py":
            py_compile.compile(str(destination), doraise=True)
            compiled += 1

    shutil.rmtree(OVERLAY)
    print(
        f"V11.1 OVERLAY INSTALLED: {len(mappings)} installs "
        f"({EXPECTED_MAPPINGS} manifest mappings + {len(SUPPLEMENTS)} documented supplements; "
        f"{replacements} replacements + {len(additions)} new modules), "
        f"{compiled} python destinations compile, "
        f"{len(FIX_MARKERS)} r2.1 fix markers present"
    )


if __name__ == "__main__":
    main()
