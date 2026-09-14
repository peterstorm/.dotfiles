#!/usr/bin/env python3
"""Context-length and KV-fill sweep for a live GLM-5.3 profile (vLLM).

Reuses the gates tooling's stream/chat/calibration so every cell is directly
comparable with the v11.1 receipt numbers. Stdlib only; results append as
JSON lines to RESULTS (one object per cell) and a human log goes to stdout.

Cells:
  idle_short_c1/c8   short decode ITL at idle KV (the baseline)
  ctx_<target>       c1 context sweep at 4k/16k/32k/64k/128k/256k with a fixed
                     256-token decode (TTFT is the prefill cost per context)
  fill52_* / fill84_*  the same cells under a KV cache filled to ~52% and ~84%
                     by concurrent long prefills whose blocks stay cached —
                     the "high fill is slower" hypothesis, tested directly.

Run: RESULTS=/tmp/v12-sweep.jsonl MODEL=<served-model> \
     GATES_DIR=<repo>/benchmarks/vllm-tps python3 glm53-context-sweep.py
"""
from __future__ import annotations

import os
import sys
import threading

sys.path.insert(0, os.environ.get("GATES_DIR", os.path.dirname(os.path.abspath(__file__))))
import importlib.util  # noqa: E402

_gates_path = os.path.join(sys.path[0], "glm53-gates.py")
_spec = importlib.util.spec_from_file_location("glm53_gates", _gates_path)
g = importlib.util.module_from_spec(_spec)  # type: ignore[arg-type]
_spec.loader.exec_module(g)  # type: ignore[union-attr]  # (stream, chat, record, metrics, calibrate, retrieval_prompt, filler_lines)

g.RESULTS = os.environ.get("RESULTS", "/tmp/v12-sweep.jsonl")


def kv_frac() -> float:
    return g.metrics().get("vllm:kv_cache_usage_perc", 0.0)


def measure(label: str, context: int | None = None, concurrency: int = 1) -> None:
    """Short decode ITL at the current KV fill; c1 or cN concurrent prompts."""
    if context is None:
        prompt = "Write a detailed paragraph about how a hash table resolves collisions."
    else:
        prompt = (
            g.retrieval_prompt(context, g.new_code(), salt=50_000_000 + context)
            + " Then write a detailed paragraph about lighthouses."
        )
    if concurrency == 1:
        runs = [g.stream(prompt, 256, think=False)]
    else:
        results: list[dict | None] = [None] * concurrency

        def run(i: int) -> None:
            results[i] = g.stream(prompt if i == 0 else prompt + f" Variant {i}.", 256, think=False)

        threads = [threading.Thread(target=run, args=(i,)) for i in range(concurrency)]
        [t.start() for t in threads]
        [t.join() for t in threads]
        runs = [r for r in results if r]

    med = lambda key: (  # noqa: E731
        sorted(r[key] for r in runs if r[key] is not None)[len(runs) // 2] if runs else None
    )
    g.record(
        label,
        ok=all(r["completion_tokens"] == 256 for r in runs),
        runs=runs,
        context=context,
        concurrency=concurrency,
        kv=round(kv_frac(), 3),
        decode_tok_s=med("decode_tok_s"),
        itl_p50_ms=med("itl_p50_ms"),
        itl_p95_ms=med("itl_p95_ms"),
        ttft_s=med("ttft_s"),
    )


def fill_to(target: float, per_request: int, concurrency: int, salt: int) -> None:
    """Fire concurrent long prefills; they complete and their blocks stay cached."""
    while kv_frac() < target:
        threads = [
            threading.Thread(
                target=g.chat,
                args=(
                    g.filler_lines(int(per_request / g.calibrate()), salt=salt + i * 100_000)
                    + " Summarise the text above in one sentence.",
                    8,
                ),
            )
            for i in range(concurrency)
        ]
        [t.start() for t in threads]
        [t.join() for t in threads]
        g.log(f"fill: kv={kv_frac() * 100:.1f}%")


def main() -> None:
    g.log(f"sweep start: kv={kv_frac() * 100:.1f}%")
    # 1. Idle-KV baseline cells.
    measure("idle_short_c1")
    measure("idle_short_c8", concurrency=8)
    # 2. Context sweep at c1, idle KV: TTFT is the prefill cost per context.
    for target in (4_000, 16_000, 32_000, 64_000, 128_000, 256_000):
        prompt = g.retrieval_prompt(target, g.new_code(), salt=30_000_000 + target)
        r = g.stream(prompt + " Then write a detailed paragraph about lighthouses.", 256, think=False)
        g.record(f"ctx_{target}", ok=r["completion_tokens"] == 256, **r, kv=round(kv_frac(), 3))
    # 3. KV-fill scenarios: the same cells under a filled cache.
    fill_to(0.52, 100_000, 8, 40_000_000)
    measure("fill52_short_c1")
    measure("fill52_short_c8", concurrency=8)
    measure("fill52_128k_c1", context=128_000)
    fill_to(0.84, 64_000, 8, 41_000_000)
    measure("fill84_short_c1")
    measure("fill84_short_c8", concurrency=8)
    measure("fill84_128k_c1", context=128_000)
    g.log("sweep complete")


if __name__ == "__main__":
    main()
