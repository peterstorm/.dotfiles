# TPS probe — desktop, 2026-08-20 — vLLM + native DFlash 2

First live validation of the locally built vLLM PR #52816 image and the native
DFlash 2 checkpoint. The server remained healthy and authenticated after all
cells.

## Environment

- Host: `desktop`, Ryzen 9 9950X, 91 GiB RAM.
- GPUs: 2× RTX PRO 6000 Blackwell Workstation Edition, 96 GiB each, TP2 over
  PCIe PHB (no NVLink).
- Applied power cap: **350 W per GPU**. The checked-in NixOS configuration says
  450 W, but the active boot generation still applies 350 W.
- Driver: 595.91.07 (CUDA 13.2 compatibility).
- Image tag: `peterstorm/vllm:qwen38-dflash2-pr52816-66e5414`.
- Immutable local image ID:
  `sha256:f07390e05b3bfccd4aa7494fa322a0077f72fbc8842f8b17dca96e57420218a6`.
- Runtime: `vllm 0.26.1rc1.dev920+g66e5414c6`, torch 2.13.0, CUDA 13.0.
- Target: `/models/Qwen3.8-27B`, BF16, 262144 context, TP2.
- Draft: `Qwen3.8-27B-DFlash2`, BF16, native `DFlash2DraftModel`, seven
  speculative tokens.
- Request defaults: temperature 0 in the probe; 59-token prose prompt with
  thinking off, 99 tokens with xhigh thinking.

Startup resolved `Qwen3_5ForConditionalGeneration` for the target and
`DFlash2DraftModel` for the draft. The worker instantiated
`DFlash2Qwen3ForCausalLM` and captured the DFlash2 speculator on both TP ranks.

## Sequential results

The method is the existing `benchmarks/vllm-tps/probe.py`: streamed OpenAI
chat completions, usage counts from the final stream event, answer-token TTFT,
and decode TPS `(completion_tokens - 1) / (total - TTFT)`.

| Run | Thinking | Completion | TTFT | Total | Decode TPS | Overall TPS |
|---|---:|---:|---:|---:|---:|---:|
| warm-up | off | 64 | 0.31 s | 1.11 s | 78.4 | 57.6 |
| A1 | off | 512 | 0.09 s | 4.33 s | **120.4** | 118.3 |
| A2 | off | 512 | 0.08 s | 4.33 s | **120.3** | 118.2 |
| B1 | xhigh | 1500 | 2.11 s | 12.49 s | **144.4** | 120.1 |
| B2 | xhigh | 1500 | 2.11 s | 12.50 s | **144.2** | 120.0 |

The two measured repetitions are effectively identical.

Across those five requests, vLLM reported:

- verification drafts: 1300;
- proposed draft tokens: 9100 (exactly seven per verification);
- accepted draft tokens: 2793;
- draft-token acceptance: `2793 / 9100 = 30.69%`;
- effective acceptance length, including the target/bonus token:
  `1 + 2793 / 1300 = 3.15` tokens per verification.

During the sequential window, one-second GPU samples showed average power
318.5 / 312.7 W, maximum sampled power 364.1 / 352.4 W, average utilization
90.3 / 87.5%, maximum utilization 100 / 100%, and maximum temperature
57 / 52 °C. The slight instantaneous excursion above the configured cap is a
sampling/board-power transient; `nvidia-smi` continued to report a 350 W
configured limit.

## Concurrency 8

Eight identical thinking-off requests were issued simultaneously, each capped
at 512 completion tokens.

| Requests | Total completion tokens | Wall time | Aggregate TPS | Median TTFT | Median request latency |
|---:|---:|---:|---:|---:|---:|
| 8 | 4096 | 5.60 s | **731.3 tok/s** | 0.23 s | 5.54 s |

All requests returned 512 tokens. TTFT ranged 0.12–0.24 s and request latency
5.54–5.59 s.

Counter deltas for this cell:

- verification drafts: 1324;
- proposed draft tokens: 9268;
- accepted draft tokens: 2768;
- draft-token acceptance: `2768 / 9268 = 29.87%`;
- effective acceptance length: `1 + 2768 / 1324 = 3.09`.

## Interpretation

This is a successful first live gate: native DFlash2 routed correctly,
speculative counters moved, output completed, authentication stayed valid,
and no runtime traceback, OOM, NCCL failure, Xid, or container restart occurred.
The Transformers `min_frames` / `max_frames` messages logged at `ERROR` level
are docstring-validation noise from the multimodal processor, not request
failures.

The native profile is materially faster than the historical local cells:
120.3–120.4 tok/s plain decode at 350 W versus 67.0 tok/s for the 2026-08-18
autoregressive vLLM 350-W cell, and 12.5 s for the xhigh 1500-token cell versus
23.5 s historically. These are directional comparisons, not a controlled A/B:
the vLLM revision, driver, kernels, and speculative engine all changed.

The measured effective acceptance length (~3.1) is below the card's 4.1–5.5
range, which was produced on H200/SGLang benchmark workloads, but it is well
above the near-1.0 miswiring threshold. The engine also warns that
`max_num_batched_tokens=4096` may be suboptimal with seven speculative slots.
Treat a larger token budget as a separate measured tuning experiment rather
than changing the validated baseline silently.

## Reproduction

```bash
# Sequential historical cells
nix shell nixpkgs#python3 --command \
  python3 benchmarks/vllm-tps/probe.py --thinking off --max-tokens 512
nix shell nixpkgs#python3 --command \
  python3 benchmarks/vllm-tps/probe.py --thinking xhigh --max-tokens 1500

# Counters
curl -fsS http://192.168.0.80:8000/metrics \
  | grep -E '^vllm:spec_decode_num_(drafts|draft_tokens|accepted_tokens)_total'
```
