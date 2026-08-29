# GLM-5.3 Flash EXL3 K4 v84 vision FP8-DS-MLA + MTP3 359K v8

**Status:** immutable, booted, authenticated, capacity-receipted, and basic-smoke-qualified on
2026-08-29. The supplied 524,288-token envelope was rejected at both 0.953 and 0.986 GPU
utilization; the accepted profile fixes a conservative 359,000-token ceiling. Full long-context,
prefix-cache, tool, concurrency, restart, and soak qualification remains pending.

## Purpose

v8 converts the supplied Compose recipe into a repository-owned, digest-pinned workstation
profile. It keeps the requested TP2/EP2/DCP2, B12X MoE, FlashInfer SM120 sparse MLA, FP8 DS MLA
KV, chunked prefill, prefix caching, multimodal template, and routing/Trellis settings. Local
boot evidence required reducing the requested 524,288-token ceiling to 359,000 tokens. Two
requirements are explicit rather than commented:

```text
vision: enabled (no --language-model-only)
MTP:    {"method":"mtp","num_speculative_tokens":3,"draft_sample_method":"probabilistic"}
```

The profile accepts text and up to four images; video is disabled. Prefix-cache correctness for
hybrid GLM state remains a qualification gate and is not inferred from cache-hit counters.

## Immutable identities

| Artifact | Identity |
|---|---|
| Verified local checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Byte-identical TR3 target | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| Supplied source tag | `verdictai/glm53-flash-exl3-k4:r19-sm120-tp2-ep2-dcp2-v84-language-only` |
| Supplied image index | `sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692` |
| Runtime AMD64 manifest | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Embedded vLLM commit | `6dc2f516688fe6f84c6994dcd20fddf296853a6c` |
| Embedded B12X commit | `36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8` |
| Multimodal template SHA-256 | `34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891` |

The source tag says `language-only`, but the pinned runtime manifest identifies itself as the
vision build and contains the validated multimodal template, native vision-RoPE fallback,
`Glm5NextForConditionalGeneration`, and `TORCH_SDPA`. v8 relies on the immutable manifest and
verified embedded capabilities, not the mutable tag name.

## Runtime envelope

| Setting | v8 value |
|---|---:|
| Inputs | text and image |
| Image limit | 4 |
| Video limit | 0 |
| Context ceiling | 359,000 tokens |
| Parallelism | TP2 / EP2 / DCP2 |
| Expert parallelism | enabled |
| Maximum sequences | 4 |
| Batched-token budget | 2,048 |
| GPU memory utilization | 0.986, fixed |
| KV cache | `fp8_ds_mla` |
| Language-model attention | `FLASHINFER_MLA_SPARSE_SM120` |
| Vision attention | `TORCH_SDPA` |
| Loading | `safetensors` |
| Prefix cache | enabled |
| Speculation | built-in MTP, 3 probabilistic draft tokens |
| Served model | `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8` |

The launcher also fixes `VLLM_B12X_GLM_NOPE_NVFP4=0`, EXL3 prefill block M 128, EXL3 Trellis,
wide and hybrid-tail route-128 paths, B12X DCP A2A, PCIe C++ all-reduce, NCCL P2P level 4,
and two OpenMP threads.

## Deliberate repository adaptations

- The runtime uses the immutable AMD64 manifest digest rather than the mutable Compose tag.
- The verified checkpoint is mounted read-only at `/model`; no online Hub resolution is needed.
- Repository-standard API-key handling, GPU preflight, exact-model readiness, profile labels,
  and transactional rollback are retained.
- The repository uses host port 8000 while a profile is active rather than Compose port 8118.
- Vision support is explicit: the launcher omits `--language-model-only`, selects the embedded
  multimodal template and `TORCH_SDPA`, and caps images at four.
- MTP3 is mandatory and contract-tested, not an operator comment.

## Preflight

These commands do not stop the active profile. The puller runs a short CPU-side capability
probe and the launcher hashes the local checkpoint:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v8-image.sh

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v8" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v8.sh --preflight
```

## Attended launch and mandatory KV-capacity receipt

```bash
systemctl stop comfyui.service
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v8" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v8.sh start
```

The switcher accepts the boot only after health, authentication, exact served-model identity,
and both startup log records are present:

```text
Available KV cache memory: <GiB>
GPU KV cache size: <tokens>, Maximum concurrency for 359,000 tokens per request: <ratio>x
```

It prints both records and atomically persists them with container start time and image ID at:

```text
~/.local/state/glm53/exl3-k4-vllm-sm120-v8-kv-capacity.txt
```

Manual verification:

```bash
grep -E 'Available KV cache memory:|GPU KV cache size:' \
  "$HOME/.local/state/glm53/exl3-k4-vllm-sm120-v8-kv-capacity.txt"
docker inspect glm53-flash-exl3-k4-vllm-sm120-v8 \
  --format 'restart={{.RestartCount}} image={{.Image}} args={{json .Args}}'
```

## First-boot receipt

Two rejected boots established the safe-envelope bound before the 359K retry:

| Attempt | Available FP8 KV memory | Result |
|---|---:|---|
| 524,288 at utilization 0.953 | -2.35 GiB | rejected: no cache blocks |
| 524,288 at utilization 0.986 | 2.09 GiB | rejected: 428,544-token estimated maximum |

The failed 0.986 boot required 2.45 GiB for one 524,288-token request. The switcher restored
Qwen after both failures; the hardened launcher now uses `restart=no` until acceptance, then
promotes the healthy container to `unless-stopped`.

| Measurement | Accepted 359K v8 boot |
|---|---:|
| Available FP8 KV memory | **3.79 GiB/GPU** |
| Engine KV token capacity | **749,676 tokens** |
| Full-359K concurrency | **2.09x** |
| Container restart count | **0** |
| Restart policy after acceptance | `unless-stopped` |
| Persistent-cache state | warm |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Container start | `2026-08-29T20:17:45.341661211Z` |

The authenticated text smoke returned exactly `V8_READY`. A generated 32x32 solid-red PNG
returned exactly `red` and reported 16 image tokens. MTP was active: the two smokes drafted six
tokens and accepted four, including accepted tokens at all three draft positions. Both GPUs
remained below 40 C at idle after boot, and no Xid/SXid was recorded during the accepted launch.

## Qualification gates

1. **Identity:** exact image, checkpoint, model ID, MTP3 config, FP8 DS MLA KV, FlashInfer MLA,
   multimodal template, and 359,000-token ceiling.
2. **Vision:** one-image and four-image understanding; changed image bytes must change the result;
   video must be rejected.
3. **Prefix cache:** compare complete deterministic cold/warm outputs for text and image prefixes,
   including changed-image and parallel shared-prefix cases. Cache-state-dependent trajectories
   block promotion.
4. **MTP:** verify acceptance metrics, output correctness, reasoning, and single/parallel tool
   calls with the `glm45` and `glm47` parsers.
5. **Context:** retrieval at 98K, 256K, and 350K plus 359K-boundary and overflow rejection.
6. **Concurrency:** test only within the measured boot pool; `--max-num-seqs 4` does not prove
   that four maximum-length requests fit.
7. **Lifecycle:** restart twice, require a fresh KV receipt each time, then soak while monitoring
   Xids, corrected errors, thermals, power, host pressure, preemption, and queueing.

## Rollback

The switcher automatically restores every previously running repository-owned profile if v8
launch, readiness, exact identity, or KV-capacity reporting fails. Manual Qwen rollback:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v8 2>/dev/null || true
docker start qwen38-flash-next-fp8-vllm-v1
```

Pi selector, only while v8 is actually serving:

```text
desktop-vllm/glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v8:max
```
