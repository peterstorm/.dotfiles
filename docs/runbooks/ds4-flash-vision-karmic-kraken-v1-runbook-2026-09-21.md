# DS4 Vision Karmic Kraken v1 runbook — 2026-09-21

## Status

**READY — NOT BOOTED** (operator instruction: "don't boot it up, just ready
it"). GLM v14 (`glm53-flash-spark-tp2-v14`) remains the serving profile.

Done:
- Upstream contracts vendored + pinned (see
  `docs/research/ds4-vision-karmic-kraken-v1-2026-09-21-evidence/README.md`).
- Release set written: pull/prove, checkpoint download, run, probe, switch
  under `scripts/inference/deepseek/`, catalog entry added.
- Image pulled and pinned on the desktop: the **versioned** release tag
  `karmic-kraken-beta-20260920-443d9f815c57d23b` resolves to image id
  `sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee`
  with repo digest **exactly** the benchmark doc's
  `sha256:55e477ad62ae15a77c9b869e8fb8e2d958f6edcc4d95e306adfa89dee9ed19df`
  (30.2 GB; distinct from the floating-tag build `sha256:7b5c335c…` that v14
  serves — both stay installed, each profile pins its own).
- CPU-only `--print-config` proofs ran on the pinned image: stock
  `ds4-vision` contract (TP2/DCP1, DSpark K3, 4 slots, 4096 budget, 0.975
  util, fp8 KV/block 256, revision `6821d6ad…` profile-derived, GPU-only
  cache) and the benchmark-arm override pass (env aliases + native top-p 1
  override) all resolve with the expected sources. Status `implemented`.

Remaining (in order):
1. Checkpoint download (~170 GiB) — started detached; verify with
   `ds4-flash-vision-karmic-kraken-v1-checkpoint.sh --verify` once
   `/models/hf-cache/ds4-flash-vision-karmic-kraken-v1/.download-complete`
   appears.
2. `run-ds4-flash-vision-karmic-kraken-v1.sh --preflight` (static-only; safe
   while v14 serves).
3. `switch-ds4-flash-vision-karmic-kraken-v1.sh start` — the deliberate
   cutover (idle gate → stops v14 → CUDA probe → launch → accept → promote →
   probe; rollback restarts v14 on any failure). **Not executed.**

## Immutable identities

- Image: `ghcr.io/local-inference-lab/vllm:karmic-kraken-beta-20260920-443d9f815c57d23b`
  (upstream versioned Karmic Kraken beta release: CUDA 13.4.1, PyTorch 2.14,
  vLLM, B12X, FlashInfer, LMCache; linux/amd64)
- Repo digest: `sha256:55e477ad62ae15a77c9b869e8fb8e2d958f6edcc4d95e306adfa89dee9ed19df`
- Image id: `sha256:83f00757ff18f3c3c12de291319b1a3a5496056a3873834d0994160828a3c6ee`
  (recorded as `IMAGE_CONFIG` in the run, download and probe scripts)
- Checkpoint: `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp` @
  `6821d6ad3681a4b137b066b76094fa82ebd0a380` (HF tip, lastModified
  2026-09-01, 84 files, ~170 GiB; pre-downloaded into
  `/models/hf-cache/ds4-flash-vision-karmic-kraken-v1`; metadata hashes from
  `kk.checkpoint.metadata_sha256` verified at download + every preflight)
- Profile: `ds4-vision` (deployment profile in the image, hardware
  `rtx-pro-6000-pcie`)
- Served model: `deepseek-v4-flash-vision` (repository id, unchanged from
  r21 for Pi/catalog/reclaw compatibility; overrides the preset's
  `DeepSeek-V4-Flash-Vision-Exp` through `SERVED_MODEL_NAME`)
- Receipts: `~/.local/state/ds4-vision/{karmic-kraken-v1-image.identity,
  karmic-kraken-v1-checkpoint.txt, karmic-kraken-v1-boot-receipt.txt}`
- Upstream docs (vendored): `docs/research/ds4-vision-karmic-kraken-v1-2026-09-21-evidence/`

## Why this profile

v1 is the **upstream** Karmic Kraken deployment of DeepSeek V4 Flash Vision:
TP2/DCP1, DSpark K3 self-speculation, four request slots, 4096-token prefill
budget, fp8 target KV (block 256), B12X attention + MoE, instanttensor load,
a pinned 1,048,576-token context and GPU-only prefix caching — the exact
configuration of the benchmark doc's qualified Vision arm (its best measured
state: C1 193.9 tok/s +14.6%, C4 401.4 tok/s, 32K prefill 9,182 tok/s, C1
verifier 87.18 steps/s vs the saved R9 run). Unlike r21 there is no
repository-derived image or custom overlay: the served tree is the upstream
versioned release image and the deployment contract is the upstream profile +
the benchmark arm's environment. The repository adds only pinning,
credentialing, the workstation gates, and the transactional switcher.

Upstream measured on Max-Q cards at 325 W. This workstation pins 400 W
(declarative) on stock Workstation Edition cards: expect different absolute
numbers, same geometry. Re-measure at acceptance if the numbers matter
(`probe-inference-throughput.sh` exists for that).

## Prerequisites

- Desktop host, both GPUs idle, `comfyui.service` stopped (the launch gates
  enforce all of this; the switcher quiesces other profiles itself).
- `docker` + `jq` (both present).
- Disk: the models pool had 193 GiB free before the download; the checkpoint
  needs ~170 GiB (the download script fails closed below 180 GiB free).
  Cleanup candidates if tight: `/models/vllm-cache/ds4-vision-infernal-invocation-cu133-r21{,-v1}`
  (retired r21 runtime caches) — never deleted by these scripts.
- HF token optional at `~/.config/hf/token` (public repo; buys rate headroom).

## Steps

```bash
# 1. Pull + prove (idempotent; re-runnable any time)
scripts/inference/deepseek/pull-ds4-flash-vision-karmic-kraken-v1-image.sh

# 2. Download the pinned checkpoint (~170 GiB; resumable)
scripts/inference/deepseek/download-ds4-flash-vision-karmic-kraken-v1-checkpoint.sh --detach
docker logs -f ds4-flash-vision-karmic-kraken-v1-dl
# ... when the marker appears:
scripts/inference/deepseek/download-ds4-flash-vision-karmic-kraken-v1-checkpoint.sh --verify

# 3. Static preflight (safe while v14 serves: no GPU/port gates)
scripts/inference/deepseek/run-ds4-flash-vision-karmic-kraken-v1.sh --preflight

# 4. The cutover (deliberate; transactional with rollback to the previous set)
scripts/inference/deepseek/switch-ds4-flash-vision-karmic-kraken-v1.sh start
#    status/stop subcommands behave like the v14 switcher.

# 5. Smoke (already part of the switch's acceptance)
scripts/inference/deepseek/probe-ds4-flash-vision-karmic-kraken-v1.sh
```

First boot does kernel preparation and graph capture on the pre-downloaded
checkpoint (`HF_HUB_OFFLINE=1`); expect a long startup similar to v14's
(5400 s switch timeout). The switcher records the boot receipt with the
resolved capacity lines.

## Acceptance chain (what `switch … start` runs)

preflight (static) → idle gate on the active profile → previous profiles
quiesced (v14) → CUDA runtime probe (cuBLAS + cuDNN on GPU0, deterministic
two-GPU NCCL allreduce) → launch (restart=no) → `HEALTHY +
AUTHENTICATED + EXACT MODEL` (`/v1/models` must serve exactly
`deepseek-v4-flash-vision` behind the bearer key) → profile/speculation/
checkpoint label checks + zero restarts → boot receipt → vision+text probe →
promote to `restart=unless-stopped`. Any failure: quiesce the failed
container, restart the previous profile set, exit non-zero.

## Rollback

```bash
scripts/inference/deepseek/switch-ds4-flash-vision-karmic-kraken-v1.sh stop
scripts/inference/glm53/switch-glm53-spark-tp2-v14.sh start      # back to v14
# or, for the previous DS4 Vision runtime:
scripts/inference/deepseek/switch-ds4-flash-vision-r21-v1.sh start
```

## Pi / catalog alignment (at acceptance time, not before)

The served id stays `deepseek-v4-flash-vision`, so the Pi provider, settings
and reclaw routing need no changes. The session cap in `pi/models.json`
should be re-decided from the boot receipt: the benchmark host measured
**1,291,085 logical KV tokens** with this configuration (r21 served 312k
context / 8 slots; v1 serves 1,048,576 context / 4 slots). Following the v14
precedent (KV / cap ≈ parallel slots), caps of **256,000** tokens (~5 slots)
or **312,000** tokens (~4 slots) are the candidates; the server still accepts
up to 1,048,576 per request for benchmarks/curl. Also verify the host driver
line in the boot receipt and, if throughput numbers matter, re-run
`scripts/inference/shared/probe-inference-throughput.sh` against the
authenticated endpoint (absolute numbers will differ from the Max-Q table).

## Known differences from the upstream record

See the evidence README's deviations list (image identity, served id, offline
checkpoint, auth, restart policy, port/GPUs, sampling override, benchmark
instrumentation). None of them change the engine contract; all are pinned by
`--print-config` proofs or container labels.
