# GLM-5.3 Flash EXL3 K4 v84 text FP8-DS-MLA + MTP3 384K v6

**Status:** immutable, prepared, and unqualified. Static contracts and remote image identity
checks are complete. The profile has not been launched. The currently running v5 multimodal
NVFP4 profile must remain online until an attended v6 qualification window.

## Purpose

v6 reproduces the supplied author's text-only recipe without modifying v5. In this profile,
“same KV cache” means the recipe's exact `fp8_ds_mla` mode. It does **not** mean v5's
`nvfp4_ds_mla`; the two profiles intentionally remain separate.

The author's statement that the configuration should expose approximately 700,000 KV tokens
is recorded only as an unverified expectation. Capacity is a boot-time result, not a launcher
constant. Do not mark v6 qualified until local logs on both RTX PRO 6000 cards report the
allocated token capacity.

## Immutable identities

| Artifact | Identity |
|---|---|
| Verified local checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Byte-identical TR3 publication named by the recipe | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| Supplied mutable image tag | `verdictai/glm53-flash-exl3-k4:r19-sm120-tp2-ep2-dcp2-v84-dflash2` |
| Observed image index | `sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692` |
| Runtime AMD64 manifest | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Embedded vLLM commit | `6dc2f516688fe6f84c6994dcd20fddf296853a6c` |
| Embedded B12X commit | `36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8` |

On 2026-08-28 the supplied tag resolved to the same manifest already serving v5. v6 uses only
the immutable manifest digest. The custom overlay remains unavailable as a fully
reconstructible public build; the digest and embedded source identities provide binary
provenance, not independent source reproducibility.

The dedicated v6 puller additionally proves that the image contains the
`FLASHINFER_MLA_SPARSE_SM120` backend and the `instanttensor` package.

## Envelope

| Setting | v6 value |
|---|---:|
| Inputs | text only (`--language-model-only`) |
| Context ceiling | 393,216 tokens |
| Parallelism | TP2 / EP2 / DCP2 |
| Maximum sequences | 4 |
| Batched tokens | 2,048 |
| GPU memory utilization | 0.986, fixed |
| KV cache | `fp8_ds_mla` |
| Attention | `FLASHINFER_MLA_SPARSE_SM120` |
| Loading | `instanttensor` |
| Prefix cache | enabled |
| Speculation | built-in MTP, 3 probabilistic draft tokens |
| Served model | `glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k` |

If the local pool is exactly 700,000 tokens, theoretical full-ceiling concurrency is only
`700000 / 393216 = 1.78×`. `--max-num-seqs 4` is a scheduler limit, not evidence that four
384K requests fit concurrently. Even two simultaneous full-length requests would exceed that
claimed pool.

## Differences from qualified v5

v6 is not a context-only variant. It changes all of the following together:

- multimodal → language-model-only;
- calibrated NVFP4 MLA KV → FP8 DS MLA KV;
- B12X sparse MLA attention → FlashInfer sparse MLA SM120;
- safetensors loader → InstantTensor;
- prefix cache disabled → enabled;
- 2,072 → 2,048 batched tokens;
- adds request-id, usage, per-request metrics, and prompt-token detail flags;
- adopts `clear_thinking: true` as a default template kwarg.

Results therefore compare whole runtime envelopes, not one isolated optimization.

## Intentional deviations from the pasted Docker command

- The launcher binds the already verified checkpoint at `/model` instead of resolving a mutable
  Hugging Face repo id from a hub cache. The local tensors are byte-identical to the named TR3
  publication.
- Placeholder parser/template mounts were not added. Their source paths and revisions were not
  supplied, and the command does not explicitly consume either mount. The digest-pinned image's
  embedded GLM parsers and checkpoint template remain authoritative.
- The served-model id is version-specific so Pi and readiness checks cannot confuse v6 with v5.
- Repository-standard authentication, profile labels, GPU checks, restart policy, and
  transactional rollback are retained. The API key is passed through a private env file, never
  Docker argv.

## Preparation without stopping v5

The following operations do not stop the active v5 container, but the puller starts a short
CPU-side capability probe and preflight hashes the checkpoint. Run them only when that I/O is
acceptable:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v6-image.sh

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v6" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v6.sh --preflight
```

Do **not** invoke `switch-glm53-exl3-profile-v6.sh start` while v5 is in use.

## Future attended launch

Only during an approved interruption:

```bash
systemctl stop comfyui.service
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v6" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v6.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v6
```

The switcher preflights before stopping anything, requires authenticated discovery of exactly
`glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k`, and restores the previous repository-owned
profile if launch or readiness fails.

## First-boot capacity gate

Capture the complete startup log and record:

1. total allocated KV token capacity and whether the log reports it globally or per worker;
2. per-GPU model, non-torch, activation, and KV memory;
3. effective max model length, maximum concurrency, KV dtype, attention backend, loader,
   prefix-cache state, and MTP configuration;
4. any InstantTensor cache materialization or fallback;
5. container restart count, GPU Xids, corrected errors, and host RAM pressure.

Treat approximately 700K as confirmed only if the exact v6 boot reports it. A materially lower
pool that cannot admit one 393,216-token request is a startup/qualification failure. A pool
between one and two full contexts requires concurrency tests to avoid overcommit.

## Runtime qualification

1. Authentication rejection and exact authenticated model discovery.
2. Exact text, reasoning, streaming, malformed request, and usage-field tests.
3. Single and parallel tool calls with `glm45`/`glm47` parsers.
4. Retrieval at 98K, 128K, 256K, and 384K.
5. Prefix-cache cold/warm equivalence and cache-hit accounting.
6. One 384K request, then representative four-way concurrency; attempt two full 384K requests
   only if measured capacity is at least 786,432 tokens.
7. Restart twice and soak while monitoring Xids, thermals, restart count, and correctness.
8. Confirm image input is rejected because v6 is intentionally text-only.

## Rollback

v5 remains the preferred rollback and is not modified by v6:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v6 2>/dev/null || true
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v5.sh start
```

Pi selector for v6, only while v6 is actually serving:

```text
desktop-vllm/glm-5.3-flash-exl3-k4-text-fp8kv-mtp-384k:max
```

The canonical `glm` routing target and Loom benchmark arm remain pinned to v5.
