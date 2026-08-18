# Qwen3.8-27B DFlash 2 runbook — 2026-08-19

TL;DR — serve the DFlash 2 draft alongside the existing Qwen3.8-27B target:

```bash
# 1. download the draft (desktop user's Desktop folder)
bash scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
# 2. cut over (stops the current :8000 server, waits for health + auth)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2
# 3. rollback if anything is off
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh sglang
```

## What DFlash 2 is

DFlash 2 (Inco AI, [blog](https://inco.ai/blog/dflash2/), [code](https://github.com/z-lab/dflash)) is a
**block-diffusion drafter** for speculative decoding: it predicts a whole block of tokens in one
parallel pass, keeps the top-16 candidates at every position, and a lightweight low-rank selector
(rank 256) traces one coherent path through them; two-tap dynamic convolutions stop the draft from
decaying toward the end of the block. Decoding is lossless — greedy output matches the target
exactly, sampling preserves its distribution.

It replaces the DSpark draft (same target model, different drafter family). Card numbers (H200,
FlashAttention 3, Qwen3.8-recommended sampling, xhigh reasoning):

| | acceptance length (GSM8K→MT-Bench) | throughput vs autoregressive, concurrency 1 / 8 |
|---|---|---|
| MTP (built-in) | 5.02 → 3.74 | 2.59× / 2.19× |
| DSpark | 4.36 → 3.01 | 2.69× / 2.23× |
| **DFlash 2** | **5.46 → 4.10** | **3.43× / 2.84×** |

The expected acceptance range on this box (8-way concurrency profile) is therefore roughly
**4.1–5.5**; an acceptance length near 1.0 means the draft is miswired, not merely weak.

## Checkpoint

| field | value |
|---|---|
| repo | `z-lab/Qwen3.8-27B-DFlash2` (mirror of `incoai/Qwen3.8-27B-DFlash2`) |
| pinned revision | `ac04198556d7e8867853cbc356807b969f311b05` (last modified 2026-08-18T20:19:51Z) |
| license | Apache-2.0 |
| size | single `model.safetensors`, 1,924,404,480 params BF16 (≈3.6 GiB) |
| draft shape | 5 layers, all `sliding_attention` (window 2048), hidden 5120, vocab 248320 |
| `dflash_config` | `block_size 8`, `mask_token_id 248070`, `selector_rank 256`, `selector_top_k 16`, `conv_group_size 16`, `conv_kernel_size 2`, `target_layer_ids [5,19,33,47,61]` |
| base model | `Qwen/Qwen3.8-27B` — the same target every profile in this repo serves |

It is a draft model only; it never runs standalone.

## Engine support status (verified 2026-08-19)

| engine | status | detail |
|---|---|---|
| SGLang | **usable now, on the pinned digest** | `lmsysorg/sglang:qwen38-27b@sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124` is a custom build (`0.0.0.dev0+qwen38.27b.g561c8f3`, CUDA 13.0.3) that already carries the DFlash stack: `SpeculativeAlgorithm.DFLASH` → `DFlashWorkerV2`, `parse_dflash_draft_config()` reads `block_size`/`mask_token_id`/`target_layer_ids`/`layer_types`/`sliding_window` from the checkpoint. Upstream PR [sgl-project/sglang#35371](https://github.com/sgl-project/sglang/pull/35371) is still **open** — the support reaches stable SGLang only on merge. |
| vLLM | **blocked on upstream** | Upstream PR [vllm-project/vllm#52816](https://github.com/vllm-project/vllm/pull/52816) is **open** (checked via GitHub API 2026-08-19). No released or nightly vLLM image carries DFlash 2, and this box has no vLLM image at all. The card's vLLM instructions require `pip install vllm @ git+...@refs/pull/52816/head` — a from-source build (full CUDA extension compile) against a moving PR head; not an acceptable pin for a production launcher yet. |

Re-check before any re-pin:

```bash
curl -s https://api.github.com/repos/vllm-project/vllm/pulls/52816 | grep -E '"(merged_at|merge_commit_sha)"'
curl -s https://api.github.com/repos/sgl-project/sglang/pulls/35371 | grep -E '"(merged_at|merge_commit_sha)"'
```

**vLLM, when #52816 merges:** build/pull the first nightly that verifiably contains it, record
image tag + digest, add `run-qwen38-27b-bf16-dflash2-vllm.sh` (method `"dflash"`,
`num_speculative_tokens 7` per the card) and a `dflash2-vllm` switcher mode, mirroring the
DSpark v1/v2 pair.

## Draft-config surgery (why the launcher copies the draft)

The checkpoint declares `architectures: ["DFlash2DraftModel"]`. The image's model registry does
**not** know that name — it only has `DFlashDraftModel` (`sglang/srt/models/dflash.py`) and the
DSpark classes. The launcher therefore prepares an **isolated copy** at
`/models/Qwen3.8-27B-DFlash2-sglang` with that one field rewritten to `["DFlashDraftModel"]`
(everything else byte-identical, idempotent, rebuilt only when stale). The downloaded canonical
tree is never modified — same pattern as the DSpark-on-vLLM launcher. If upstream ever adds
native `DFlash2DraftModel` registration, the surgery stays (it is image-agnostic and idempotent).

## Prerequisites

- The Qwen3.8-27B target at `/models/Qwen3.8-27B` (`download-qwen38-27b.sh`).
- Docker + two GPUs with power caps applied (the launcher fails closed above 450 W).
- `jq` (core-apps package set) for the config surgery.
- The shared key helpers (`scripts/inference/shared/inference-api-key.sh`) — same as every other
  profile; the API key never appears in Docker args or `/proc` cmdline.

## 1. Download

```bash
bash scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
docker logs -f qwen38-dflash2-model-dl   # ...until DOWNLOAD_COMPLETE
```

- Destination: `$HOME/Desktop/Qwen3.8-27B-DFlash2` — deliberately the desktop user's Desktop
  folder for this checkpoint (override: `DFLASH2_DEST=/models/Qwen3.8-27B-DFlash2`). The
  launcher's default matches; if you move the tree later, set `DFLASH2_DRAFT_HOST`.
- Pinned to revision `ac04198`; idempotent and resumable (re-run after an interruption).
- Verify:

```bash
jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' \
  "$HOME/Desktop/Qwen3.8-27B-DFlash2/config.json"
ls -lh "$HOME/Desktop/Qwen3.8-27B-DFlash2/model.safetensors"   # ≈3.6 GiB
```

## 2. Serve

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2
```

The switcher performs the standard hard-stop cutover: stop the current :8000 server (as of
2026-08-19 that is `qwen38-27b-bf16-dspark-sglang-v2`), wait for the port to free, start
`qwen38-27b-bf16-dflash2-sglang`, wait for health, then verify the synchronized desktop-user key
is accepted. :8000 is **down between stop and first healthy response** — the first start compiles
kernels and CUDA graphs (budget: 20 min, `HEALTH_TIMEOUT` seconds). Anything mid-request during
the cutover: resend it.

Direct launch (bypasses the switcher's cutover/health logic):

```bash
bash scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang.sh
```

Launcher defaults: TP2 BF16, 262144 context, 8 running requests, FP32 GDN state,
`extra_buffer` mamba strategy with the 08-17 cookbook pin (`MAX_MAMBA_CACHE_SIZE = 8 × 5`),
flashinfer, checkpoint-native template (`enable_thinking`, `preserve_thinking`,
`reasoning_effort xhigh`), multimodal enabled, `DFLASH2_BLOCK_SIZE=8`
(`--speculative-algorithm DFLASH --speculative-num-draft-tokens 8`), secure entrypoint, crash
evidence archived to `~/.local/state/qwen38/container-archives/`.

Notes:

- No `SGLANG_RAGGED_VERIFY_MODE`: the DSpark v2 launcher exports it, but this image build has no
  consumer for that variable (verified by grep); it was not replicated.
- The DFLASH spec path takes the block size via `--speculative-num-draft-tokens` (the
  `--speculative-dflash-block-size` alias is equivalent); DFlash 2's window is 8 — seven draft
  tokens per verification step plus the bonus position.

## 3. Validation gate (first boot, and after any re-pin)

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status
curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head
nvidia-smi --query-gpu=index,power.draw,temperature.gpu --format=csv
```

- `status` must report `qwen38-27b-bf16-dflash2-sglang`, health OK, client authentication OK.
- `sglang:spec_*` counters must move; after a short chat completion the acceptance length should
  land near **4.1–5.5** (card range at this concurrency class). Near 1.0 ⇒ miswired draft —
  check the log for the draft's resolved architecture and re-verify the surgery copy:
  `jq -c '.architectures' /models/Qwen3.8-27B-DFlash2-sglang/config.json`.
- Both GPUs within the 450 W cap; sustained load clean before benchmarking.
- A/B against the DSpark v2 profile (same target, same flags, one drafter apart) before
  promoting DFlash 2 as the default: switch `sglang` ⇄ `dflash2` and compare acceptance +
  throughput in the Grafana DSpark panels.

## Rollback

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh sglang    # DSpark v2 SGLang (same engine)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh v1-sglang # 08-16 SGLang
```

The DFlash 2 trees (Desktop canonical draft, `/models/Qwen3.8-27B-DFlash2-sglang` surgery copy,
`/models/sglang-cache/qwen38-bf16-dflash2` cache) are side-by-side with every other profile's
trees; rolling back touches nothing of them.

## Watch-list

1. **sgl-project/sglang#35371 merge** → pin an official SGLang release that carries DFlash 2;
   re-validate on the box before dropping the custom image.
2. **vllm-project/vllm#52816 merge** → add the vLLM variant (see status section above).
3. **Native `DFlash2DraftModel` registration** in SGLang → surgery becomes redundant; keep it
   (image-agnostic, idempotent) until the pin moves.
4. **Checkpoint revision drift** — the pinned sha is `ac04198`; if `z-lab` pushes new weights,
   decide deliberately whether to re-pin (weights are not byte-identical across revisions).
5. Concurrency-1 numbers (card's 3.43×) are the headline use case for Pi; the 8-request profile
   here will land lower (≈2.8× class) — benchmark both before judging.
