# GLM-5.3 Flash v9 fast/safe — initial graph receipt — 2026-08-31

## Identity

- Image: `sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2`
- Served model: `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9`
- Hardware: 2× RTX PRO 6000 Blackwell Workstation Edition, 450 W
- Runtime: TP2 / EP2 / DCP1, FP8 DS MLA KV, built-in greedy MTP3, prefix cache, vision
- Graphs: FULL + PIECEWISE prefill/decode captured; `enforce_eager=False`
- Restart policy: `no`

## Build/GPU operator probe

The pinned GPU verification script passed exact overflow values, deterministic all-equal boundary
membership, the 806,736-column regression, overlap-safe state copy, slot bounds, and persistent
KPool address checks.

| Selector, 33×32,769 K=2,048 crowded overflow | Median |
|---|---:|
| v9 persistent exact top-k | 0.0255–0.0340 ms |
| `torch.topk(sorted=True)` | 0.0584–0.0586 ms |

The range covers the build-time and release-puller invocations. This is an operator microbenchmark,
not an end-to-end claim.

## Boot capacity

| Measurement | Result |
|---|---:|
| Available KV cache memory | 4.62 GiB/GPU |
| KV token capacity | 517,558 |
| 359K concurrency | 1.44× |
| Actual CUDA graph pool | 0.15 GiB/GPU |
| Estimated graph pool | 0.39 GiB/GPU |
| Restart count | 0 |
| Current-boot GPU fault events | 0 |

The first 0.986 boot with vLLM graph estimation enabled exposed only 2.9 GiB KV and cleanly
rejected 359K (3.19 GiB required). A 0.991 retry began before prior CUDA workers had fully released
VRAM and cleanly failed the free-memory preflight. The accepted profile returned to the proven
0.986 envelope and used `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`; actual retained graph memory
was 0.24 GiB below the estimate.

## Short C1 throughput

Prompt: repository `c1-short` hash-table prompt (40 prompt tokens). Each response reached the
800-token limit. The existing shell harness counts SSE chunks and under-reports multi-token deltas;
rates below use API `usage.completion_tokens / wall time`.

| Run | Completion tokens | Wall | Usage-derived output tok/s | TTFT | MTP mean acceptance |
|---:|---:|---:|---:|---:|---:|
| 1 | 800 | 6.043 s | 132.4 | 196 ms | 2.75 |
| 2 | 800 | 6.153 s | 130.0 | 107 ms | 2.67 |
| 3 | 800 | 5.603 s | 142.8 | 116 ms | 2.94 |
| 4 | 800 | 6.084 s | 131.5 | 108 ms | 2.70 |

Three-repeat median (runs 2–4): **131.5 output tok/s**, 4.28× the ~30.7 tok/s v8 service rate.
This clears the 2× target only for short C1; 32K/128K/256K cells remain required.

## Capability smokes

- Vision: generated 32×32 red PNG → exact `red`; 16 image tokens.
- Prefix reuse: identical 8,263-token prompt → `PREFIX_OK` twice; second request reused 3,456
  tokens and improved 3.77 s → 0.83 s.
- Engine remained idle/healthy after tests; zero fatal container logs and zero current-boot Xids.

## Correctness gate: RED

Ten identical completed requests used `temperature=0`, `top_p=1`, `seed=0`, low reasoning, and a
33-token prompt. All ended with `finish_reason=stop` and the required marker, but all ten complete
content hashes differed.

```text
unique complete content hashes: 10 / 10
```

Therefore the fast graph candidate is useful for diagnosis and substantially faster, but is not
promotable. The remaining numerical nondeterminism is outside the repaired persistent-top-k
membership path.
