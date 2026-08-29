# TPS probe — Qwen3.8-27B vLLM TP1 BF16-KV — 2026-08-29

Runtime benchmark of the single-GPU profile after the planning-only Loom batch.
The server remained healthy and authenticated throughout.

## Environment

- Container: `qwen38-27b-bf16-dflash2-vllm-v3`.
- Physical GPU: GPU0, RTX PRO 6000 Blackwell Workstation Edition; GPU1 reserved
  for ComfyUI.
- Image: `vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c`
  at digest `sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674`.
- Target/draft: unchanged BF16 Qwen3.8-27B + canonical BF16 DFlash2, depth 7.
- KV/GDN: BF16 KV, FP32 GDN state; TP1; warm persistent kernel cache.
- Context/KV capacity: 262,144 / 355,082 tokens.
- Request sampling: temperature 0; server-default xhigh thinking.
- Driver: credential-safe Python stdlib streaming client; API key read from the
  private key file inside the process and never placed in argv.

## Results

| Round | Requests | Prompt tokens/request | Completion tokens/request | TTFT p50 | TTFT max | Mean decode TPS/request | Aggregate TPS |
|---|---:|---:|---:|---:|---:|---:|---:|
| C1 short | 1 | 82 | 800 | 0.101 s | 0.101 s | **148.1** | **145.4** |
| C8 short | 8 | 82 | 800 | 0.193 s | 0.193 s | **124.2** | **965.8** |
| C4 long | 4 | 25,246 | 174 | 11.973 s | 11.974 s | 100.1 | **52.1** |

All C1/C8 requests reached the 800-token cap. All four long-context requests
stopped naturally after 174 completion tokens. C8 completed 6,400 tokens in
6.626 seconds. The C4 long cell processed 100,984 aggregate prompt tokens and
returned all four correct responses in 13.369 seconds.

The first C4 request saw TTFT at 6.906 seconds but only 28.2 decode tok/s over
its remaining wall interval because the scheduler continued prefilling the
other three requests. The other requests began together near 11.973 seconds
and decoded at about 124.1 tok/s each. Aggregate throughput is the reliable
comparison for this mixed-prefill cell.

## DFlash2 acceptance

| Round | Draft steps | Proposed tokens | Accepted tokens | Draft-token acceptance | Effective acceptance length |
|---|---:|---:|---:|---:|---:|
| C1 short | 135 | 945 | 666 | 70.5% | **5.93** |
| C8 short | 1,056 | 7,392 | 5,376 | 72.7% | **6.09** |
| C4 long | 121 | 847 | 575 | 67.9% | **5.75** |

Effective acceptance length includes the target/bonus position:
`(accepted tokens + draft steps) / draft steps`.

## Runtime health

- zero benchmark-window preemptions in all three cells;
- zero waiting/running requests and zero KV use after completion;
- container restart count zero and OOM flag false;
- no GPU Xid observed.

## Interpretation

The TP1 profile is not merely capacity-feasible: short-request throughput is
strong. C1 decode is 148 tok/s and C8 aggregate decode reaches 966 tok/s while
leaving physical GPU1 untouched. DFlash2 acceptance around 5.8–6.1 is materially
better than the earlier TP2 PR-image receipt's approximately 3.1 on its sampled
prompts, though this is directional rather than a controlled A/B because the
runtime profile, TP degree, power state, prompts, and image differ.

Long-prefill fairness remains visible: one request starts decoding while three
prefills continue, depressing that request's wall-clock decode rate. There were
no preemptions or correctness failures in this 25K-token C4 cell.
