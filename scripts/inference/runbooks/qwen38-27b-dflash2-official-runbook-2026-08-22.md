# Qwen3.8-27B DFlash2 — official SGLang profile (2026-08-22)

SGLang now documents DFlash2 as a first-party Qwen3.8-27B deployment option:
<https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B>.

That changes the preferred *engine artifact*, but it does not invalidate the locally
validated TP2 profile. The new launcher is deliberately versioned and separate:

```bash
bash scripts/inference/qwen38/download-qwen38-27b-dflash2-v2.sh
# pull while the server is still down
docker pull 'lmsysorg/sglang:dev-qwen38-27b-dflash2@sha256:616a3e97f45191af975896cfa644279096cb31bd408a071c2e99ca7209c3cafe'

bash scripts/inference/qwen38/switch-qwen38-backend-v3.sh dflash2-official
```

**Status:** repository profile prepared and statically verified. The desktop was offline
while this update was made, so the new image has not been pulled or GPU-qualified locally.

## Audit verdict

| Existing behavior | Verdict against the official cookbook |
|---|---|
| `--speculative-algorithm DFLASH` | Correct |
| Canonical DFlash2 draft with `DFlash2DraftModel` | Correct in the native launcher |
| `--speculative-num-draft-tokens 8` | Correct; eight is the block/verify width |
| `MAX_MAMBA_CACHE_SIZE = requests × 5` for `extra_buffer` | Correct; do **not** add the eight verify states to this explicit pin |
| FlashInfer, 2,048-token prefill chunks, FP32 GDN state | Matches the official RTX PRO 6000 cell |
| Old architecture surgery to `DFlashDraftModel` | Historical degraded fallback only; no longer appropriate for new runs |
| Locally built merge-commit image `c14312a6` | Functionally real DFlash2 and locally measured, but superseded as the preferred upstream artifact |
| TP2 | A useful locally validated workstation profile, but outside the official cookbook's single-GPU recipe |
| BF16 KV | Intentional quality-first local deviation; official BF16 target recipe pins FP8 E4M3 KV |

The old `dflash2-native` launcher remains the measured TP2 rollback. The old `dflash2`
surgery launcher remains available only to preserve historical reproducibility; it routes
the DFlash2 checkpoint through the v1 draft class and drops selector/convolution weights.

## Immutable release identity

| Item | Pin |
|---|---|
| Official cookbook source | `sgl-project/sglang` main, read 2026-08-22 |
| Cookbook validated source | `1cf2b8c54d81802abc15dcf23a29b9cc687bc01e` |
| Official image | `lmsysorg/sglang:dev-qwen38-27b-dflash2` |
| Multi-platform digest | `sha256:616a3e97f45191af975896cfa644279096cb31bd408a071c2e99ca7209c3cafe` |
| Linux/amd64 manifest | `sha256:b91d664a8e4825afc16ab831c6035a6c88ac20ef8bd26da4fe2b9813a9f44376` |
| Image source label | `5f55db35e926d50676f75b812640ea2410b0fe0e` |
| Target | `Qwen/Qwen3.8-27B@1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` |
| Draft | `incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4` |
| Draft weights | 3,848,817,896 bytes, SHA-256 `67fc76d68dc5a9415511a4f394ef744d67510cd20e93b37cc2cc7d28e4bab65c` |

The prescribed image tag still says `dev`: DFlash2 is official in the cookbook and
published as an official SGLang image, but this is not a numbered stable release. The
launcher therefore pins the exact registry digest and checks the embedded source label.
The current image is three commits ahead of the cookbook's measured `1cf2b8c` source; the
extra source includes compressed-tensors KV-scale loading. Requalify on every digest bump.

The canonical Inco AI and previous z-lab mirror revisions contain byte-identical
`config.json` and `model.safetensors`. Existing complete draft files can be reused. The v2
downloader changes provenance, verifies size and SHA-256, and writes a revision marker.

## New official profile

`scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang-v2.sh` defaults to:

```text
physical GPU:             1
TP:                       1
BF16 target/draft:        yes
KV cache:                 fp8_e4m3
GDN state:                float32
context:                  262144
max running requests:     8
chunked prefill:           2048
mem fraction static:      0.85
radix strategy:           extra_buffer (5 state slots/request)
max Mamba cache size:      40
attention:                flashinfer
DFlash2 verify width:      8
```

This is the official RTX PRO 6000 BF16 cell plus explicit local admission and graph caps.
SGLang's page validates RTX PRO 6000 BF16/FP8 DFlash2 to **boot and serve**; its published
end-to-end DFlash2 measurements are for NVFP4. Do not treat “official” as a BF16
performance receipt.

The launcher selects only physical GPU1 and exposes it as logical CUDA device 0. That
matches the upstream TP1 recipe and keeps the historically suspect GPU0 out of the first
gate. It also:

- refuses the wrong draft architecture/block size;
- requires the pinned image and exact source label;
- probes `DFlash2DraftModel`, `CandidateSelector`, and `DFlashGroupedConv`;
- rejects a busy or over-cap GPU before mutation;
- keeps the API key in a mode-0600 env file and redacts it from SGLang diagnostics;
- archives old container evidence before replacement;
- uses a new container, env file, and cache root, leaving every old profile intact.

## Intentional overrides

The official default is FP8 E4M3 KV. To reproduce the older quality-first cache choice
without changing the file:

```bash
KV_CACHE_DTYPE=bfloat16 \
  bash scripts/inference/qwen38/switch-qwen38-backend-v3.sh dflash2-official
```

That is no longer the official cell and needs its own capacity/performance receipt. The
same applies to `MAMBA_SSM_DTYPE=bfloat16`. The official page calls both precision choices
real quality/capacity trade-offs.

Do not change `DFLASH2_BLOCK_SIZE`, `MAMBA_STATE_SLOTS`, or TP in this launcher. Use the
older `dflash2-native` profile for the measured TP2 shape rather than turning the official
profile into an untracked hybrid.

## First local qualification

When `desktop` is back:

1. Pull the digest-pinned image and run the v2 downloader to verify/reuse the draft.
2. Stop the display manager and confirm GPU1 uses less than 2 GiB.
3. Launch with `switch-qwen38-backend-v3.sh dflash2-official`.
4. Confirm image source label `5f55db35...`, native DFlash2 registration, TP1, FP8 KV,
   FP32 GDN state, and a 40-slot Mamba pool in logs.
5. Pass authenticated text, image, low/medium/xhigh reasoning, required/named/automatic
   tool calls, streaming, and malformed-tool recovery.
6. Verify `sglang:spec_*` counters move and record effective acceptance length; near 1.0
   indicates a wiring failure.
7. Benchmark matched target-only versus DFlash2 at concurrency 1 and 8. Record TPOT,
   TTFT, emitted tok/s, acceptance, preemptions, and useful KV capacity separately.
8. Run the long-context and sustained tool-use soak while watching Xids, GPU telemetry,
   container restarts, and the durable inference ledger.
9. Compare against the locally validated TP2 native receipt before promotion. Official
   provenance alone is not evidence that TP1/FP8-KV is the better workstation default.

Static contract:

```bash
bash tests/qwen38-dflash2-official-v2-contract.sh
```
