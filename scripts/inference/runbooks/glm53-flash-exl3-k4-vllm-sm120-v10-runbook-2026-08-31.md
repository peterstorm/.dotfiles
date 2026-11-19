# GLM-5.3 Flash EXL3 K4 v10 DCP2 runbook — 2026-08-31

## Status

**Unpromoted candidate.** Keep `restart=no`. The v9 container/image remains available but does not need to run between v10 qualification attempts.

## Immutable identities

- Parent v9 image: `sha256:82ea6cb3874e4869d43993146bf52b2522f010c1206c7a5f7bd3ec04bc2bcdf2`
- Candidate v10 image: `sha256:ef5f2fcb25d16abdcd800ff70b158e077780f2cb550a0ebf5bd1fe12e9f44553`
- DCP geometry patch: `7ebef333c9ef4f363136fb0f78a622edbf886e0b62bd2e87fba11b17164c705a`
- MTP position-zero patch: `0e723d2978ac6d42ce7963727638a80c984a6111cfbe304d507444005362d253`
- B12X GLM_NEXT adapter patch: `60bf08b17169dfe65105460790b371035b0109098dce69107edc868b3e70b4e4`
- GLM_NEXT FP8 allocator-spec patch: `c2f4e4724da7c3f3306030a3ac1406a8d3e304301de92a753df4d56d574f3fbc`
- Hybrid coordinator page-padding patch: `c6098ffef5b662dd91820f14485642e8cb94662544e2f18a877ebfc5d6d0eec5`
- B12X packed-page/writer-precompile patch: `fc6ae25924cca96c652044abd52166970e9f8057264daa6625e0ff1aa8ab84b8`
- B12X sparse-attention snapshot: `903667d36aee19320776019a31dd06d1e9255b6a`, artifact SHA-256 `4a9eafc91967d6e88169522c0db6e234025cc372e205ffa0f354d74e210dba57`
- Rebuilt stable extension inherited from v9: `b144bf4e1f0d2455e016191de4bca50bc72cdf517593b374940f9cb2fc68e415`

The v10 rootfs must retain all 115 v9 layers as an exact prefix. Its two additional layers contain only the byte-pinned patches/source snapshot and their deterministic application.

## Why this lineage

The candidate retains v9’s proven EXL3, FP8 DS-MLA, vision, persistent KPool, exact top-k, overlap-safe recurrent-state, and bounded-slot implementation. It adds:

1. An adaptation of upstream vLLM #50287: `MambaSpec` tables remain fully replicated under DCP while attention KV remains DCP-sharded; oversized staged table writes fail closed.
2. An adaptation of `local-inference-lab/vllm` #539 at `4c1f7b2c37b75d4e8fefed337e82c3771dc5f8a7`: GLM MTP preserves the shifted live embedding at absolute position zero.
3. A matched B12X/vLLM adapter: the pinned B12X commit gives GLM-5.3 an explicit `ModelType.GLM_NEXT` FP8 ABI with a 528-byte record; selector, `MLAAttentionSpec` allocator, cache writer, planner, gathered-cache append, and prewarm all use that same representation. The hybrid manager allocates a 656-byte/token physical page while exposing packed 528-byte records at stride `(41984,528,1)`; one fail-closed validator owns this contract for attention and optional CKV gather, and the writer is explicitly compiled before graph capture.

PR 546 in that repository is a non-DP prefill-cadence fix and is not required unless `--prefill-schedule-interval > 1` is enabled. Its `dev/jovian-judgement` base was still audited because it contains targeted GLM work. A whole-tree replacement was rejected: v9’s B12X backend already contains a broader DCP implementation (global top-k merge/local filtering, rank-local LSE merge, optional full-CKV gather) plus the required EXL3 integration. Replacing it with the current Jovian branch would discard those release-specific seams.

The first source-safe v10 image, `sha256:9664d00f…`, failed its cold server boot before serving because v9’s B12X commit rejected GLM NoPE with `fp8_ds_mla`. A second experiment, `sha256:ed219cec…`, replaced all of B12X and proved the attention ABI, but correctly failed model load because the newer MoE API dropped EXL3’s `trellis_rate_structure` contract. Later fail-closed attempts successively exposed the old allocator’s 656-byte logical default, the hybrid manager’s requirement that MLA pages fit replicated Mamba state, the old GLM coordinator’s no-padding assertion, and the inherited backend’s blanket contiguity check. Each failed before serving and restored v9.

Before the current build, the complete cache lifecycle was audited against B12X `903667d`: writer, decode, extend, and raw CKV gather all use explicit page and record strides and safely support packed 528-byte rows with a widened page stride. Jovian’s newer combined C4-tail allocator and generic 576-wide FP8 gather were deliberately not imported because v9/v10 retain separate `KPoolTailSpec` tensors and custom DCP top-k/LSE behavior. The current image upgrades only `attention/sparse_mla` plus its private MLA implementation; v9’s MoE, trellis, communication, and NSA indexer modules remain byte-exact. Its GPU verifier now proves the exact `(41984,528,1)` runtime view through page-boundary writes, untouched page padding, precompiled CUDA-graph writer capture/replay, decode, extend, and stride-aware CKV gather.

## Final candidate configuration

- TP2 / EP2 / DCP2
- `B12X_MLA_SPARSE`
- `--dcp-comm-backend ag_rs`
- FP8 DS-MLA KV
- built-in MTP3; no ReplaySSM and no external DFlash
- prefix caching and chunked prefill
- vision via `TORCH_SDPA`
- FULL + PIECEWISE CUDA graphs with capture sizes `1,2,3,4,8,12,16`
- maximum model length 359,000
- fixed KV budget: 3,758,096,384 bytes (3.5 GiB) per GPU; this overrides profiler-derived allocation and preserves DCP2 prefill all-gather headroom
- isolated cache: `/models/vllm-cache/glm53-flash-exl3-k4-sm120-v10`

## Build and static verification

```bash
bash tests/glm53-flash-exl3-k4-vllm-sm120-v10-contract.sh
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v10-image.sh
bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v10.sh --preflight
```

The image verifier requires free GPUs. It checks exact source/extension hashes, B12X availability, the exact logical/physical cache stride through writer/decode/extend/gather and CUDA capture, Mamba-vs-attention DCP shard geometry, fail-closed table overflow, live position-zero MTP embeddings, exact sparse top-k, overlap-safe Mamba copies, slot bounds, and graph-stable KPool output addresses.

## Runtime headroom repair

The first serving image passed cold and warm startup, text completion, and 10/10 complete-message determinism. Its profiler-derived warm allocation was unsafe: 4.92 GiB/GPU left about 102 MiB free on one rank, then the first 2,048-token DCP2 prefill chunk of a 22,418-token request required a 128 MiB query all-gather and raised `torch.OutOfMemoryError`. The engine failed closed. This was runtime-headroom starvation, not a GLM_NEXT cache-layout failure.

The launcher now fixes `--kv-cache-memory-bytes` at 3.5 GiB/GPU. This makes allocation independent of compiled-cache warmth and returns about 1.42 GiB/GPU relative to the failed warm allocation. A new capacity receipt and the same 22,418-token boundary probe are required before continuing qualification.

## Cold and warm capacity protocol

Never compare a cache-warmed boot to a clean-cache boot. With the fixed KV budget, both boots must report the same logical capacity.

1. Ensure every other GPU workload is stopped; v9 may remain stopped.
2. Remove **only** the isolated v10 cache directory contents when a cold receipt is required.
3. Start v10:
   ```bash
   bash scripts/inference/glm53/switch-glm53-exl3-profile-v10.sh start
   ```
4. Preserve the emitted cold receipt from `~/.local/state/glm53/exl3-k4-vllm-sm120-v10-kv-capacity.txt` under a cold-specific benchmark artifact.
5. Stop and restart v10 without clearing its cache.
6. Preserve the second receipt as warm evidence.
7. Record graph pool size, logical KV tokens, GiB/GPU, startup duration, image ID, cache state, and free runtime memory for both boots.

## Qualification gates

All gates must pass before promotion:

- authenticated health and exact model ID
- text completion and complete-message hash comparison against DCP1
- ten repeated `temperature=0`, `seed=0` requests
- vision red-image smoke
- MTP acceptance counters and no fallback to ReplaySSM/DFlash
- aligned prefix-cache reuse
- retrieval at 128K, 261.9K, and 359K
- C1 and 32K/128K/256K throughput cells
- concurrent decode plus long prefill
- shared-prefix mixed traffic
- sustained soak with zero restarts, fatal logs, Xid/SXid/MMU faults, table-overflow errors, or EngineCore failures

The initial request probe resolved the prior blocker: ten identical `temperature=0`, `seed=0` requests produced one complete-message SHA-256 hash. This must remain green after the fixed-budget restart and under mixed traffic.

## Qualification receipt

The fixed-budget candidate is **benchmark-ready**. Cold and warm boots both exposed 691,602 logical KV tokens and 1.93× concurrency at 359K. It passed exact text and vision, 10/10 complete-message determinism, MTP counters, aligned prefix reuse, exact retrieval at 128,000 / 261,900 / 358,900 prompt tokens, 32K / 128K / 256K throughput cells, overlapping 256K prefill plus decode, three-way shared-prefix traffic, and a 30-minute four-sequence soak.

The final soak completed 661 requests, 6,970,868 prompt tokens, and 141,440 completion tokens with zero request errors, restarts, fatal logs, Xid/SXid/MMU faults, table overflows, or EngineCore failures. Full measurements live in `benchmarks/vllm-tps/2026-08-31-glm53-v10-dcp2-safe.md`.

Production promotion remains separate from benchmark readiness; retain `restart=no` until any required cross-profile DCP1/DCP2 comparison and release-policy checks are complete.

## Rollback

Rollback is optional during dedicated v10 iteration. If an older profile is required, manual rollback is:

```bash
bash scripts/inference/glm53/switch-glm53-exl3-profile-v10.sh stop
docker start glm53-flash-exl3-k4-vllm-sm120-v9
```

Confirm v9 serves `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v9` and retains its existing restart policy. Do not delete the v9 image or cache during v10 qualification.
