# TPS probe — desktop, 2026-08-20 — SGLang + native DFlash 2

First live validation and matched benchmark of the locally built SGLang PR
#35371 merge image. The server remained healthy and authenticated after all
cells and is still the active backend.

## Environment

- Host: `desktop`, Ryzen 9 9950X, 91 GiB RAM.
- GPUs: 2× RTX PRO 6000 Blackwell Workstation Edition, 96 GiB each, TP2 over
  PCIe PHB (no NVLink).
- Applied power cap: **350 W per GPU**. The checked-in NixOS configuration says
  450 W, but the active boot generation still applies 350 W.
- Driver: 595.91.07 (CUDA 13.2 compatibility).
- Image tag: `peterstorm/sglang:qwen38-dflash2-c14312a`.
- Immutable local image ID:
  `sha256:af311253309cebbd021d4f7cc4da695d30434182e89407818200754f0d788880`.
- Runtime: `sglang 0.5.18.dev761+gc14312a66`, torch 2.13.0+cu130,
  CUDA 13.0, NCCL 2.29.7.
- Target: `/models/Qwen3.8-27B`, BF16, 262144 context, TP2.
- Draft: `Qwen3.8-27B-DFlash2`, BF16, native `DFlash2DraftModel`, block
  size 8 (seven proposed draft tokens plus the target/bonus position).
- Request capacity: eight running requests; flashinfer; FP32 GDN state;
  BF16 KV cache; `CUDA_VISIBLE_DEVICES=1,0`.
- Request defaults: temperature 0 in the probe; 59-token prose prompt with
  thinking off, 99 tokens with xhigh thinking.

Startup loaded `DFlash2DraftModel` on both TP ranks, initialized the DFLASH
runner with block size 8 and mask token 248070, enabled fused KV
materialization, and folded greedy/sampling selector decode into the draft
CUDA graph. Engine startup took 128.55 seconds on the first live boot,
including 77.15 seconds for draft-decode graph capture.

The first launch exposed an entrypoint compatibility issue: this merge commit
removed `ServerArgs.derive`. The shared secure entrypoint now creates the
final resolved dataclass with `dataclasses.replace`, retaining the redacted
string subtype without mutating frozen startup configuration. The adapter was
exercised against both the older pinned SGLang image and this merge image
before relaunch. The switcher was also hardened to stop and preserve a failed
container immediately if it exits or restarts, instead of waiting through a
Docker restart loop.

## Sequential results

The method is the existing `benchmarks/vllm-tps/probe.py`: streamed OpenAI
chat completions, usage counts from the final stream event, answer-token TTFT,
and decode TPS `(completion_tokens - 1) / (total - TTFT)`.

| Run | Thinking | Completion | TTFT | Total | Decode TPS | Overall TPS |
|---|---:|---:|---:|---:|---:|---:|
| warm-up | off | 64 | 0.11 s | 0.52 s | 151.2 | 122.0 |
| A1 | off | 512 | 0.09 s | 4.18 s | **125.0** | 122.5 |
| A2 | off | 512 | 0.09 s | 4.19 s | **124.8** | 122.2 |
| B1 | xhigh | 1500 | 2.32 s | 12.28 s | **150.5** | 122.2 |
| B2 | xhigh | 1500 | 2.36 s | 12.51 s | **147.8** | 119.9 |

The repeated plain-decode result was 124.8–125.0 tok/s; xhigh decode ranged
147.8–150.5 tok/s.

The SGLang metric is a windowed gauge rather than a cumulative accepted-token
counter. At the end of the sequential window it reported:

- verification-call counter delta: 1313;
- proposed block length: 8 (seven drafts plus the target/bonus position);
- effective acceptance length: 3.075;
- draft-token acceptance: 29.64%, consistent with
  `(3.075 - 1) / 7`.

Across the 36 one-second samples in the sequential window, GPU power averaged
322.5 / 319.8 W, maximum sampled power was 362 / 362 W, average utilization
was 92.5 / 90.4%, maximum utilization was 98 / 98%, and maximum temperature
was 51 / 48 °C. `nvidia-smi` continued to report the configured 350 W limit;
the isolated 362 W readings are board-power sampling transients.

## Concurrency 8

Eight identical thinking-off requests were issued simultaneously, each capped
at 512 completion tokens.

| Requests | Total completion tokens | Wall time | Aggregate TPS | Median TTFT | Median request latency |
|---:|---:|---:|---:|---:|---:|
| 8 | 4096 | 5.671 s | **722.2 tok/s** | 0.373 s | 5.669 s |

All requests returned 512 tokens. TTFT ranged 0.208–0.374 seconds and request
latency 5.441–5.671 seconds.

The verification-call counter increased by 1273 during this cell. The final
windowed metric reported effective acceptance length 3.533 and draft-token
acceptance 36.18% (`(3.533 - 1) / 7`). Active one-second samples reached
98–99% GPU utilization and 360 / 350 W maximum sampled board power.

## Controlled comparison with vLLM

Both cells used the same host, active 350 W cap, target and draft checkpoints,
BF16 TP2 profile, prompt, client, and output lengths. The engine/image is the
intentional difference.

| Cell | SGLang native | vLLM PR #52816 | SGLang delta |
|---|---:|---:|---:|
| plain 512 decode, mean | **124.9 tok/s** | 120.35 tok/s | **+3.8%** |
| xhigh 1500 decode, mean | **149.2 tok/s** | 144.3 tok/s | **+3.4%** |
| concurrency 8 aggregate | 722.2 tok/s | **731.3 tok/s** | **-1.2%** |
| concurrency 8 median TTFT | 0.373 s | **0.23 s** | +0.143 s |

Native SGLang is slightly faster for sequential decode, while vLLM is slightly
faster in aggregate and materially better in TTFT at concurrency eight. These
differences are small enough that they should be treated as profile-specific,
not universal engine rankings.

SGLang's measured acceptance length (3.075 sequential final window, 3.533 at
concurrency eight) remains below the card's 4.1–5.5 range, which came from
H200/FlashAttention 3 benchmark workloads. It is nevertheless far above the
near-1.0 miswiring threshold, and native throughput is dramatically above the
pre-merge v1-class surgery profile (77.1 tok/s prose decode).

## Validation outcome

The live gate passed: native DFlash 2 routed correctly, speculative metrics
moved, all requests completed, authentication stayed valid, and the container
finished with zero restarts, no OOM, no NCCL failure, and no Xid. The logged
`libtorchcodec` tracebacks are explicitly ignored optional MimoV2-ASR processor
imports caused by absent FFmpeg libraries; they did not affect Qwen requests.

Raw evidence is retained on `desktop` under
`~/.local/state/qwen38/benchmarks/sglang-dflash2-20260820/`.

## Reproduction

```bash
nix shell nixpkgs#python3 --command \
  python3 benchmarks/vllm-tps/probe.py --thinking off --max-tokens 512
nix shell nixpkgs#python3 --command \
  python3 benchmarks/vllm-tps/probe.py --thinking xhigh --max-tokens 1500

curl -fsS http://192.168.0.80:8000/metrics \
  | grep -E '^sglang:spec_'
```
