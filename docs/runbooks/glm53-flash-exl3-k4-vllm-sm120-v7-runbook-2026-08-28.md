# GLM-5.3 Flash EXL3 K4 v84 vision NVFP4 + MTP3 fair-prefill v7

**Status:** immutable, prepared, and unqualified. Static contracts are complete. This profile
has not been launched. v5 remains the running, qualified rollback; v6 remains the separate
text-only FP8-DS-MLA recipe.

## Purpose

v7 derives from v5's long-context multimodal envelope and retains its FP4-class cache path:

```text
--kv-cache-dtype nvfp4_ds_mla
--attention-backend B12X_MLA_SPARSE
```

It changes exactly two cache/scheduler behaviors:

```text
--enable-prefix-caching
--long-prefill-token-threshold 512
```

Everything else remains aligned with v5: EXL3 K4 weights, 393,216-token context, TP2/EP2/DCP2,
calibrated NVFP4 DS MLA KV, B12X sparse MLA, built-in MTP3, the official multimodal template,
TORCH_SDPA vision encoder attention, up to four images, and video disabled.

Live v5 telemetry identified repeated long-prefill head-of-line blocking. Requests averaged
approximately 100,000 prompt tokens, prefix-cache hits were zero, and an uncapped prefill could
consume the entire 2,072-token scheduler iteration. During those prefills aggregate generation
fell from 173–187 tokens/s to 2–7 tokens/s, while 12,079 inter-token intervals landed in the
400–500 ms bucket. Host CPU, RAM, disk, container health, Xids, OOMs, and preemption did not
explain the collapse.

Prefix caching should avoid recomputing exact warm conversation prefixes. The 512-token cap
protects an active decode when a request is a cold miss or has an unrelated prefix: one long
prefill cannot consume the full scheduler iteration. Both benefits remain hypotheses until this
exact multimodal NVFP4 profile is booted and measured. Prefix caching with the hybrid GLM state
and image inputs is a correctness gate, not an assumed capability.

## Immutable identities

| Artifact | Identity |
|---|---|
| Verified checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Byte-identical named TR3 target | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| Runtime AMD64 manifest | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image index evidence | `sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Embedded vLLM commit | `6dc2f516688fe6f84c6994dcd20fddf296853a6c` |
| Embedded B12X commit | `36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8` |
| Multimodal template SHA-256 | `34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891` |

The dedicated v7 puller proves the pinned image's multimodal provenance, native vision-RoPE
fallback, TORCH_SDPA and B12X sparse MLA backends, and `long_prefill_token_threshold` scheduler
field. The custom overlay remains unavailable as a fully reconstructible public build;
immutable binary and embedded-source identities provide provenance, not independent source
reproducibility.

## Envelope

| Setting | v7 value |
|---|---:|
| Inputs | text and image |
| Image limit | 4 |
| Video limit | 0 |
| Context ceiling | 393,216 tokens |
| Parallelism | TP2 / EP2 / DCP2 |
| Maximum sequences | 4 |
| Batched-token budget | 2,072 |
| Long-prefill cap | 512 scheduled tokens per iteration |
| Scheduler policy | default FCFS |
| GPU memory utilization | 0.986, fixed |
| KV cache | calibrated `nvfp4_ds_mla` |
| Language-model attention | `B12X_MLA_SPARSE` |
| Vision attention | `TORCH_SDPA` |
| Loading | `safetensors` |
| Prefix cache | enabled |
| Speculation | built-in MTP, 3 probabilistic draft tokens |
| Served model | `glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7` |

The launcher accepts a long-prefill threshold only in `[1, 512]` and rejects values above the
configured batched-token budget. An operator override therefore cannot silently restore v5's
uncapped behavior. v5 remains unchanged with prefix caching disabled and the scheduler default
of zero.

v5's exact boot allocated 625,112 KV tokens, or 1.59× the 393,216-token request ceiling. That is
a baseline for v7, not proof of v7 capacity. Prefix-cache metadata or graph differences must be
measured from v7's own boot.

## Preparation without interrupting v5

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v7-image.sh

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v7" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v7.sh --preflight
```

These operations do not stop the active profile. The puller starts only a short CPU-side image
capability probe; preflight hashes the checkpoint, template, and local image.

## Attended launch

Only during an approved interruption:

```bash
systemctl stop comfyui.service
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v7" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v7.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v7
```

The switcher preflights before stopping any profile, requires authenticated discovery of
exactly `glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7`, and restores the previously running
repository-owned profile if launch or readiness fails.

## First-boot gates

Record before sending qualification traffic:

1. Allocated NVFP4 KV token capacity and whether it is global or per worker.
2. Effective 393,216 context, four-sequence limit, 2,072 batched-token budget, and 512-token
   long-prefill threshold.
3. Calibrated NVFP4 DS MLA KV, B12X sparse MLA, TORCH_SDPA vision, prefix-cache, and MTP3 state.
4. Per-GPU model, vision encoder, activation, non-torch, and KV memory.
5. Container restart count, GPU Xids, corrected errors, thermals, power limits, and host RAM.

Reject the boot if the served-model identity differs, either requested fix is absent, an
unexpected cache/backend is selected, checkpoint/image/template identity differs, or one
393,216-token request cannot fit.

## Prefix-cache correctness gates

Run cold and warm pairs with deterministic request settings and compare complete semantic
outputs, not just cache counters:

1. Text-only exact-prefix continuation: require prefix-cache query/hit growth on the warm run.
2. Same image bytes and same text prefix: require identical image understanding and a cache hit
   only where the runtime considers the multimodal prefix reusable.
3. Same text with changed image bytes: require no stale visual result or cross-image cache reuse.
4. Same image with changed preceding text: require output to reflect the changed prompt.
5. Parallel requests sharing a prefix: require isolation, correct tool/reasoning fields, and no
   hybrid-state corruption.
6. Restart and repeat a cold/warm pair; correctness must not depend on stale process state.

Any stale image result, divergent warm output, malformed reasoning/tool state, or cache-accounting
claim unsupported by metrics blocks promotion and requires rollback to v5.

## Fairness qualification

Use identical prompts and output limits when comparing v5 and v7. Capture vLLM metrics,
request timings, logs, and GPU telemetry for each run.

1. **Cold single request:** establish first-token latency and prefill throughput at 100K and
   256K tokens.
2. **Warm prefix reuse:** repeat an exact conversational prefix and measure cached-token ratio,
   TTFT, and output equivalence.
3. **Decode plus cold prefill:** begin a long streaming decode, then admit an unrelated 100K+
   cold prompt. Compare p50/p95/p99 inter-token latency, generation throughput, and the count
   of 400–500 ms gaps against v5.
4. **Two cold prefills plus decode:** verify bounded stalls, queue behavior, and no preemption
   or KV thrashing.
5. **Aggregate trade-off:** record prefill throughput and completion time; do not accept a
   latency improvement that causes an unexplained correctness or stability regression.
6. **Functional gates:** authenticate, stream, reason, call tools singly and in parallel,
   reject malformed requests, and validate usage fields.
7. **Vision gates:** single and four-image prompts, repeated-image warm-cache tests, mixed
   text/image long contexts, and explicit video rejection.
8. **Context gates:** retrieval at 98K, 128K, 256K, and 384K, including overflow rejection.
9. **Lifecycle gates:** restart twice, verify exact model discovery, then soak while monitoring
   Xids, clocks, power, temperature, host pressure, cache hit rate, queues, and MTP acceptance.

Promotion requires correct prefix reuse plus materially lower concurrent-decode p95/p99
inter-token latency than v5, without output corruption, startup instability, preemption, or
unacceptable total-throughput loss. Record actual results here before marking v7 qualified.

## Rollback

v5 is the unchanged multimodal NVFP4 rollback:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v7 2>/dev/null || true
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start
```

v6 remains the independent text-only FP8 profile and is not part of v7's fallback chain.

Pi selector for v7, only while v7 is actually serving:

```text
desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k-fair-v7:max
```

Canonical `glm` routing remains pinned to v5 until v7 completes runtime qualification.
