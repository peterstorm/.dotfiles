# TPS probe — Qwen3.8 Flash-Next FP8 TP2 + PLE offload — 2026-08-29

First local runtime qualification of the immutable experimental Flash-Next v1
profile on 2× RTX PRO 6000 Blackwell Workstation Edition.

## Identity and placement

- Container: `qwen38-flash-next-fp8-vllm-v1`.
- Served model: `qwen3.8-flash-next-fp8`.
- Checkpoint: `Qwen/Qwen3.8-Flash-Next-FP8@970c569adaca6b35532111fd6b27351b2baefe50`.
- Image config: `sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9`.
- TP2, FP8 weights, automatic KV dtype, MTP3, 262,144-token context.
- `VLLM_PLE_CPU_OFFLOAD=1`; both TP workers registered the one PLE layer with
  the host `PleOffloadWorker`.
- ComfyUI remained inactive before launch and throughout qualification.
- API key came from the private key file and was never placed in argv.

Unauthenticated model discovery returned HTTP 401. Authenticated discovery
returned exactly `qwen3.8-flash-next-fp8` with a 262,144-token maximum.

## Boot and capacity

- Container start to API readiness: approximately **312 seconds**.
- Weight loading: 166.7–168.5 seconds per TP worker.
- Model allocation: 64.58 GiB per TP worker.
- Peak activation: 1.03 GiB per worker.
- CUDA graphs: 0.29 GiB per worker.
- KV allocation: 21.72–21.84 GiB per worker.
- Logical KV capacity: **1,459,504 tokens**.
- Maximum 262,144-token concurrency: **5.57×**; the launcher still caps active
  sequences at four.

The desktop's 91 GiB host RAM is tight. Immediately after startup, host memory
reported 29 GiB available while zram held 43.6 GiB of logical swap data,
compressed to 34.6 GiB. The PLE worker itself showed roughly 7.6 GiB resident
and 41.2 GiB swapped. This is compressed-RAM residency rather than disk I/O;
`vmstat` showed zero sustained swap-in/out while idle. The model served the
qualification cells without OOM or paging stalls, but ComfyUI and other
memory-heavy workloads must remain off.

## Correctness surface

| Gate | Result |
|---|---|
| Deterministic text | Exact `FLASHNEXT-READY` |
| SSE | Exact `STREAM-OK` and terminal `[DONE]` |
| Tool call | `lookup_weather({"city":"Copenhagen"})`, valid JSON |
| Vision | Generated 32×32 red PNG classified as `red` |
| Authentication | unauthenticated 401; authenticated model list exact |

An initial borrowed one-pixel PNG fixture rendered as white and was rejected as
qualification evidence. The passing vision gate used a programmatically
constructed, CRC-valid RGB PNG with every pixel set to `(255,0,0)`.

## Throughput

The short cell used the same technical hash-map prose prompt family as the
Qwen3.8-27B probe, temperature 0, xhigh thinking, and an 800-token cap.

| Cell | Prompt tokens/request | Completion tokens/request | TTFT p50 | Mean decode TPS/request | Aggregate end-to-end TPS |
|---|---:|---:|---:|---:|---:|
| C1 | 99 | 800 | 0.755 s | **172.1** | **148.1** |
| C4 | 99 | 800 | 1.603 s | **174.9** | **518.3** |

C4 completed 3,200 generation tokens in 6.174 seconds. Its aggregate steady
state after TTFT was approximately 699 tok/s. All requests reached the cap and
finished with valid SSE termination.

### MTP3 acceptance

| Cell | Draft steps | Proposed tokens | Accepted tokens | Draft-token acceptance | Effective acceptance length |
|---|---:|---:|---:|---:|---:|
| C1 | 307 | 921 | 493 | 53.5% | **2.61** |
| C4 | 1,276 | 3,828 | 1,932 | 50.5% | **2.51** |

Effective acceptance length includes the target/bonus position:
`(accepted tokens + draft steps) / draft steps`. MTP3 cannot exceed four.
The runtime warns that its QSA state backend cannot use fused multi-step draft
decode, so it rebuilds attention metadata between draft steps.

## Long-context retrieval and prefix reuse

A fresh prompt containing **249,336 prompt tokens** placed `FALCON-7391` near
the middle of hostile repetitive filler.

- Cold result: exact `FALCON-7391`, TTFT **23.057 s**, total 23.059 s.
- Immediate identical replay: exact result, TTFT **0.741 s**, total 0.743 s.
- Prefix-cache receipt after replay: 246,400 hit tokens.
- Approximate cold prefill rate: **10.8K prompt tok/s**.

This materially improves on the earlier Qwen3.8-27B cold 249K receipt
(280 seconds), while its cached replay was similar (20.6 seconds for that older
profile versus 0.74 seconds here). The prompts and server implementations are
not controlled A/B inputs, so the comparison is directional.

## Runtime health

Across correctness, throughput, and long-context cells:

- zero preemptions;
- zero container restarts and no container OOM;
- no observed GPU Xid;
- requests returned to zero and KV usage returned to zero after isolated cells;
- ComfyUI remained inactive.

The later planning workload drove both GPUs close to full VRAM and generated
concurrent requests, but still recorded zero preemptions, restarts, and OOMs.
The profile remains experimental because the source provenance is not publicly
reconstructible and the host PLE table depends heavily on compressed RAM.
