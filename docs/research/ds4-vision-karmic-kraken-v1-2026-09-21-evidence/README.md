# DS4 Vision Karmic Kraken v1 — upstream evidence

Vendored upstream references for the `ds4-flash-vision-karmic-kraken-v1`
deployment profile (DeepSeek V4 Flash Vision on the Karmic Kraken beta image,
`ds4-vision` profile):

| Upstream source | Vendored file | SHA-256 | Fetched |
|---|---|---|---|
| `rtx6kpro/blob/master/models/deepseek-v4-flash-vision.md` | `upstream-deepseek-v4-flash-vision.md` | `29b1d61978b73ce1cabc72721288bf56acbb2f21979452cedb1da00b84bebcc5` | 2026-09-21 |
| `rtx6kpro/blob/master/benchmarks/karmic-kraken-serving.md` | `upstream-karmic-kraken-serving.md` | `d5219cae19b9c7b9f2900d8eb60bf513335e6c0b74c3f4cd41d54f1c2c3a2ec2` | 2026-09-21 |
| `rtx6kpro/blob/master/benchmarks/karmic-kraken-serving-samples.json` | (not vendored; 532 KB machine-readable evidence) | `afa6643073b9db02c4477c586d9d58240ed354c86f7887a1bf1cd7bb70bcc5dd` | 2026-09-21 |

## The deployment contract the repository pins against

The contract is the upstream `ds4-vision` profile **plus the exact environment
of the benchmark's Vision arm** (samples JSON, `kk.docker_argv`), all verified
through the image's `--print-config` interface on the pinned image — not by
reading the docs:

| Setting | Upstream doc / benchmark arm | Pinned by v1 |
|---|---|---|
| Image | published `karmic-kraken-beta-20260920-443d9f815c57d23b`, digest `sha256:55e477ad62ae15a77c9b869e8fb8e2d958f6edcc4d95e306adfa89dee9ed19df` | resolved to image id `sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee` (pull script proves tag↔digest↔id) |
| Checkpoint | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp` @ `6821d6ad3681a4b137b066b76094fa82ebd0a380` (profile-derived; the revision the benchmark ran) | pre-downloaded, offline-pinned (`HF_HUB_OFFLINE=1` + `MODEL_REVISION`), metadata hashes verified against `kk.checkpoint.metadata_sha256` |
| Parallelism | TP2 / DCP1 | `tensor-parallel-size: 2`, `decode-context-parallel-size: 1` |
| Speculation | DSpark K3 | `mode: dspark`, `draft-tokens: 3`, speculative-config derived with the pinned revision |
| Request slots | 4 | `max-num-seqs: 4` (benchmark arm env) |
| Prefill budget | 4096 tokens | `max-num-batched-tokens: 4096` (benchmark arm env) |
| Context cap | 1,048,576 (benchmark arm env; profile default is memory-resolved -1) | `MAX_MODEL_LEN=1048576` |
| GPU memory util | 0.975 | `GPU_MEMORY_UTILIZATION=0.975` |
| KV cache | fp8, block 256 | profile default (kept) |
| Load / graphs / backends | instanttensor, cudagraph 16, B12X attention + MoE, FULL_AND_PIECEWISE | profile default (kept) |
| Cache storage | GPU-only prefix (`cache_service: null`); the Spark TP2 cache-recovery section of the benchmark doc is a separate text/image recovery record | `CACHE_MODE=vram` (LMCache RAM+disk tier available as an explicit pass) |
| Sampling | benchmark arm: temperature 1 / **top-p 1** via native `--override-generation-config` (profile default is top-p 0.95) | `GEN_OVERRIDES='{"temperature":1.0,"top_p":1.0}'` native arg (clearable to the preset default) |
| Hardware profile | `rtx-pro-6000-pcie` | kept |
| Vision | enabled, no artificial one/two-image cap | profile default (kept) |

`--print-config` proofs recorded by the pull script (base pass + benchmark-arm
override pass, both CPU-only with `--network none`): digests are in the
identity receipt `~/.local/state/ds4-vision/karmic-kraken-v1-image.identity`
on the serving host. The run script re-runs the override pass at every
preflight/launch against the pinned image id.

## Upstream qualification status (verbatim boundaries from the benchmark doc)

- The six-mode throughput table (Vision arm: C1 193.9 tok/s, C4 401.4 tok/s,
  32K prefill 9,182 tok/s, C1 verifier 87.18 steps/s, 1,291,085 logical KV
  tokens) was measured on a **local source-composition image**
  (`sha256:d351927666613339608da3ec6c6f227048a60cb7c2a46baff2edf8a4b1dbb84c`)
  that is **not published**. The published registry image this release set
  pins passed the Spark serving/cache checks; its equivalence to the
  composition image is documented upstream (481/481 B12X Python files
  identical; 2,749 vLLM Python files differ only in generated version
  metadata and one reviewed MoE docstring; torch/triton/flashinfer/LMCache/
  InstantTensor/ModelOpt versions match). The Vision throughput numbers were
  **not repeated on the registry digest** — absolute numbers on this
  workstation are expected to differ and are re-measured at acceptance.
- Benchmark hardware: RTX PRO 6000 Blackwell **Max-Q** Workstation Edition,
  VRAM +6000, automatic clocks, **325 W**. This workstation: stock Workstation
  Edition cards at the declarative **400 W** pin. Geometry is identical
  (TP2 across two RTX PRO 6000 Blackwell cards); power state is not.
- All six upstream arms pass factual/repeated-prefix/image checks; "these
  checks do not establish general checkpoint quality or arbitrary-context
  capacity."

## Driver / CUDA compatibility evidence (2026-09-21)

How we know the host driver can run this image — probes, not version tables
(the same evidence chain the v14 profile established on this host):

| Component | Host / image | Evidence |
|---|---|---|
| Host driver | **595.91.07** (nvidia-smi; flake pin) | nvidia-smi query |
| Image runtime | torch 2.14.0a0 built for **CUDA 13.4.1** | image env (`CUDA_VERSION: 13.4.1.012`) |
| cuBLAS + cuDNN | image build | finite matmul + conv on device 0 — re-probed at every launch |
| NCCL | 2.30.7 | real deterministic two-GPU allreduce — re-probed at every launch |
| Upstream tested driver | 615.65.02 (benchmark box) | doc reference; CUDA minor-version compatibility accepts older drivers |
| Prior art on this host | the floating-tag KK build (v14, GLM Spark TP2) has served behind the same driver since 2026-09-19 | v14 runbook |

## Repository deviations (all deliberate, documented in the runbook and scripts)

1. **Image identity** — the release set pins the **versioned release tag** and
   its doc-recorded digest instead of the floating `karmic-kraken-beta` tag
   the v14 pull used. The floating tag resolved to a different build on this
   host (`sha256:7b5c335c…`, repo digest `sha256:495b340e…`), which v14 keeps
   serving; the doc's identity is `sha256:55e477ad…` →
   `sha256:83f00757…`. "Floating deployment tags do not change the identities
   of measurements recorded here."
2. **Served model id** — `SERVED_MODEL_NAME=deepseek-v4-flash-vision`
   overrides the preset's `DeepSeek-V4-Flash-Vision-Exp` so the Pi provider,
   `pi/models.json`, reclaw routing and the r21-era clients keep working
   unchanged (launcher precedence: native arg > environment alias > preset;
   proven by `--print-config` in the pull script). The exact runtime profile
   is attested through container labels + the boot receipt instead.
3. **Checkpoint** — the docs resolve the checkpoint from Hugging Face into a
   named volume; v1 serves revision `6821d6ad…` offline from
   `/models/hf-cache/ds4-flash-vision-karmic-kraken-v1` with
   `HF_HUB_OFFLINE=1` + `MODEL_REVISION` (the engine can never fetch a
   different revision, and the cache stays verifiable from the host — the four
   metadata hashes the benchmark evidence records are verified at hydration
   and re-verified at every preflight/launch). The snapshot was **hydrated
   from the existing r21-era local copy** (`~/models/DeepSeek-V4-Flash-Vision-Exp`,
   revision `86f746b3`): all 48 weight shards are byte-identical (HF LFS oids
   == `kk.checkpoint.shards` blobs; every shard re-hashed locally against the
   vendored manifest), the per-file git-oid diff shows only README.md differs
   (fetched, 6.6 KiB), and the snapshot symlinks depend on the flat copy
   staying in place. A plain full download remains available via the same
   script's `--detach` mode.
4. **Sampling** — the benchmark arm's top-p 1.0 native override is kept as the
   default (`GEN_OVERRIDES`); clearing it serves the profile's top-p 0.95
   default. Both paths are `--print-config`-proven.
5. **API key** — `VLLM_API_KEY` flows through the repository's synchronized
   credential contract; the docs leave the API on a trusted network or ask for
   authentication, this deployment authenticates.
6. **Restart policy** — launch with `--restart no`, promote to
   `--restart=unless-stopped` only after an accepted boot (repository
   transactional pattern; the doc's unless-stopped is the promoted end state).
7. **Port/GPUs** — API on 8000 (benchmark box used 5068) and physical GPUs
   0,1 (benchmark box used 5,6) per the workstation's standard topology.
8. **Benchmark instrumentation not carried** — the benchmark arm's
   `VLLM_B12X_DUMP_QUERIES` / `B12X_PREPARATION_TRACE_DIR` query-dump envs are
   measurement tooling, not serving configuration, and are deliberately not
   set.

## Ready state (2026-09-21)

Built, pinned, checkpoint hydrated (48/48 shards sha256-verified against the
Karmic Kraken evidence, 6.6 KiB fetched), preflight **PASS** — and **not
booted** (operator instruction: "don't boot it up, just ready it"). GLM v14
remains the serving profile. The only remaining step is the transactional
switch, documented in the runbook.
