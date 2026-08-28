# GLM-5.3 Flash EXL3 K4 v84 multimodal + MTP3 384K v5

**Status:** immutable long-context candidate; static contract complete; local startup and runtime
qualification recorded below as it is performed. The qualified 98,304-token v4 profile remains
unchanged and is the automatic rollback target.

## Why this is a separate profile

v5 raises the multimodal MTP profile's request ceiling from 98,304 to 393,216 tokens. It does
not replace or modify v4. The image, target tensors, quantization, vision path, template,
parallelism, speculation, and GPU utilization remain identical, making the context ceiling the
only intended runtime-behavior change.

The v4 startup supplied direct local capacity evidence:

- checkpoint native context: 1,048,576 tokens;
- vision encoder cache budget: 7,921 tokens, profiled with one maximum-size image;
- available KV memory: 4.74 GiB per worker;
- allocated calibrated NVFP4 MLA KV capacity: 830,668 tokens;
- maximum full-length concurrency at 98,304: 8.45×.

A 393,216-token ceiling therefore has a theoretical KV concurrency of 2.11× without changing
the already allocated KV pool. That is capacity evidence, not correctness qualification:
retrieval, image behavior, tools, concurrency, restart, and soak must still pass locally.

## Immutable identities

| Artifact | Identity |
|---|---|
| Target checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Byte-identical TR3 publication | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| AMD64 image | `verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Embedded vLLM commit | `6dc2f516688fe6f84c6994dcd20fddf296853a6c` |
| Embedded B12X commit | `36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8` |
| Official multimodal template SHA-256 | `34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891` |
| Runtime provenance SHA-256 | `cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907` |

The image is exactly the digest already verified and exercised by v4. Its complete custom
overlay remains unavailable as a publicly reconstructible build; digest and embedded source
hashes are strong identity evidence, not independent supply-chain reproducibility.

## Immutable envelope

| Setting | v5 value |
|---|---:|
| Inputs | text and up to four images; video disabled |
| Context ceiling | 393,216 tokens |
| Target parallelism | TP2 / EP2 / DCP2 |
| Maximum sequences | 4; only about two can simultaneously occupy the full ceiling |
| Batched tokens | 2,072 |
| GPU memory utilization | 0.986, fixed |
| Target KV | calibrated `nvfp4_ds_mla` |
| Attention | `B12X_MLA_SPARSE` |
| Vision encoder attention | `TORCH_SDPA` |
| Speculation | built-in MTP, 3 draft tokens, probabilistic |
| Prefix cache | disabled |
| Template | exact official Z.ai multimodal template embedded in v84 |
| Served model | `glm-5.3-flash-exl3-k4-vision-mtp-384k` |

v5 deliberately does not adopt the separate text-only FP8 recipe. FP8 KV, language-model-only,
FlashInfer attention, InstantTensor loading, and prefix caching would confound context and
vision qualification. v5 changes only the accepted maximum sequence length.

## Pull, preflight, and launch

The shared image puller proves image and embedded runtime identity:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh
```

Preflight without touching the running profile:

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v5" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v5.sh --preflight
```

Transactional attended launch:

```bash
systemctl stop comfyui.service
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v5" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v5
```

The switcher preflights before stopping v4, waits for health plus authenticated model discovery,
and automatically restarts the previous repository-owned profile if launch or readiness fails.
The API key remains in a private env file and never appears in Docker argv.

## Qualification gates

1. Confirm unauthenticated rejection and authenticated discovery of exactly
   `glm-5.3-flash-exl3-k4-vision-mtp-384k`.
2. Confirm logs report max model length 393,216, native 1,048,576 MTP support, TP2/EP2/DCP2,
   calibrated NVFP4 MLA, MTP3, `TORCH_SDPA`, and at least 393,216 KV tokens.
3. Repeat exact text, reasoning, streaming, single/parallel tool-call, and malformed-tool tests.
4. Repeat local image, remote image, four-image, malformed-media, video-rejection, and
   image-plus-tool tests.
5. Exercise retrieval at 98K, 128K, 256K, and at least 384K while recording TTFT, prefill,
   decode, queueing, KV usage, and output correctness.
6. Exercise two concurrent long requests and four representative concurrent requests; do not
   claim four simultaneous 384K requests from an 830,668-token pool.
7. Restart twice and soak while monitoring Xids, corrected errors, thermals, GPU memory, and
   host RAM.

## Rollback

Automatic rollback is built into the v5 switcher. Manual rollback preserves both containers:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v5 2>/dev/null || true
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v4.sh start
```

Pi keeps both IDs. Use `desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp:max` for the qualified
98K rollback and `desktop-vllm/glm-5.3-flash-exl3-k4-vision-mtp-384k:max` only while v5 is
serving.
