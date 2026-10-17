# GLM-5.3 Flash v14 (Spark TP2) stock gates receipt + three-way verdict — 2026-10-17

Completes the leg promised in `2026-10-17-glm53-v15-gates.md`. v14 = Spark
NVFP4 PTQ checkpoint, re-downloaded the same day after the 2026-10-16 deletion
(75 files, 187,802,635,887 bytes, revision `a6082410…`, receipt in
`~/.local/state/glm53/flash-spark-tp2-v14-checkpoint.txt`). Raw JSONL:
`2026-10-17-glm53-v14-stock-gates.jsonl`. Phases: correctness capabilities
retrieval throughput; soak not run.

## Arm 2 (pinned-up) — crashed, no data

The "just pin more KV" arm (`KV_CACHE_MEMORY_BYTES=7650410496`,
`MAX_NUM_SEQS=8`, same image/revision) was launched at 11:49 local; the
container died before health — almost certainly OOM during memory profiling at
the bigger KV pin. The v14 run script's contract warning ("Keep PRESET, KV,
slots and prefill unchanged") is empirically load-bearing: **the Spark memory
plan does not carry ~3.3 GiB/GPU of slack, and v15's 7296 MiB KV is not
replicable on v14 by pinning.** v14 stays at 986,295 KV tokens / 4 slots
(1.00x full-context concurrency, confirmed at boot).

## Boot identity (stock)

- Served model: `glm-5.3-flash-spark-tp2-v14`
- Image: `sha256:7b5c335c…` (karmic-kraken-beta, 2026-09 line — one month
  older than v15's 20261015.2)
- Resolved: max_model_len 983,040; GPU KV cache 986,295 tokens; max
  concurrency for full-context requests 1.00x

## Three-way measured comparison (this host, same harness, 2026-10-17)

| Cell | v14 stock | v15 (qad2) | Winner |
|---|---:|---:|---|
| C1 decode, no-think (median overall) | **157.4 tok/s** (ITL p50 19.2–19.7 ms) | **215.6 tok/s** (ITL p50 14.5 ms) | v15, +37% |
| Prefill 33K → TTFT | 7.9K tok/s | **8.9K tok/s** | v15 |
| Prefill 135K → TTFT | 7.1K tok/s | **8.0K tok/s** | v15 |
| Prefill 273K → TTFT | 6.7K tok/s | **7.4K tok/s** | v15 |
| Decode after 256K prefill | **183.9 tok/s** | 100.5 tok/s | **v14, ~1.8x** |
| Decode under mixed traffic (2048-tok gen) | 92.0 tok/s | **101.6 tok/s** | v15 |
| MTP mean acceptance | 2.62 | **2.89–2.93** | v15 (BF16 draft head) |
| KV pool / slots | 986,295 / 4 (pin-up crashed) | **1,844,162 / 8** | v15 |
| `prompt_tokens_details` in usage | **absent** (cached_tokens unobservable) | present | v15 |
| Determinism (10× temp 0) | **10 distinct outputs** | 1 distinct output | **v15** |
| Retrieval correctness 128K / 358.9K | found=True / found=True | found=True / found=True | tie |
| Long-context decode (c8 rows, graphs 1–16) | verified at boot | verified at boot | tie |

Upstream's "Spark is faster" (186.5 C1 / 10,919 prefill on Workstation cards)
**does not replicate on our PCIe cards against the newer karmic image**: v15
wins C1 decode, prefill at every depth, mixed-traffic decode, MTP acceptance,
capacity, and API observability. v14's single decisive win is **long-context
decode after a 256K prefill (~1.8x)** — consistent with the qad2 branch's
BF16-restored KDA gates/indexer/kv_b costing long-context attention compute
(the quality-for-speed tradeoff, made visible).

## Quality findings

- **Determinism is the hard differentiator**: v14 produces 10/10 distinct
  outputs for the identical temp-0 request; v15 is bit-stable. For
  extraction/pipeline work this alone disqualifies v14 as a default.
- Spark's undistilled MXFP8-KDA showed **no recall deficit** on the gates'
  exact-retrieval cells (correct codes at 128K and 358.9K, verified against
  expected values) — the qad2 branch card's +3.4pt delta does not manifest as
  binary failures at these depths on our harness.
- The no-think preamble/echo quirk appears on **both** arms (v14 even
  duplicates the bare code: `QX-WXSHYLURQX-WXSHYLUR`) — shared grammar
  behaviour, not quant-specific.

## Verdict

Stay on v15. It wins every measured cell that matters for the agent workload
except long-context decode, it is deterministic at temp 0, its cache metrics
are client-observable, and its capacity lead is structural (v14 cannot be
pinned up). Revisit v14 only for workloads dominated by decode after
≥256K-token prefills.
