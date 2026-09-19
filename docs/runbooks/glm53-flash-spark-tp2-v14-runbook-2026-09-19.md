# GLM-5.3 Flash Spark TP2 v14 runbook — 2026-09-19

## Status

**Registered candidate, not yet served.** The workstation currently serves the
**DS4 Flash Vision r21** profile; the GLM rollback target is **v13**. v14 does
not run until its switch script is deliberately started (which quiesces the
serving profile transactionally). Until the pull script records the image id
in `run-glm53-flash-spark-tp2-v14.sh`, v14 is unlaunchable by construction.

## Immutable identities

- Image: `ghcr.io/local-inference-lab/vllm:karmic-kraken-beta` (upstream
  Karmic Kraken integration channel: CUDA 13.4.1, PyTorch 2.14, vLLM, B12X,
  FlashInfer, LMCache; linux/amd64)
- Image id: `sha256:7b5c335cc647b203aacd09e7513f19266846a8efeabdcaa8724524e51e04ff7a`
  (recorded as `IMAGE_CONFIG` in the run script; repo digest
  `ghcr.io/local-inference-lab/vllm@sha256:495b340eede3bbb348fd6c9662d1535e0d2f27e47c08cc71802fea6bc68caf40`,
  30.2 GB)
- Checkpoint: `local-inference-lab/GLM-5.3-Flash-NVFP4-Spark` (public;
  downloaded into the `lil-huggingface` volume on first boot)
- Preset: `glm53-spark-tp2` (deployment preset in the image, hardware
  `rtx-pro-6000-pcie`)
- Served model: `glm-5.3-flash-spark-tp2-v14` (repository id; overrides the
  preset's `GLM-5.3-Flash` through `SERVED_MODEL_NAME`)
- Upstream doc (vendored): `upstream-glm-5.3-flash-spark-tp2.md` in
  `docs/research/glm53-spark-tp2-v14-2026-09-19-evidence/`

## Why this profile

v14 is the **upstream** Spark TP2 deployment: TP2/DCP2, MTP3, four request
slots, 3072-token prefill budget, fixed 3996 MiB/GPU FP8 target KV (FP32
recurrent state, BF16 target head + private NVFP4 MTP draft head), vision
without the one-image admission cap, and a memory-resolved context of about
983k tokens (GPU-only) or 924k (with the optional LMCache RAM+disk tier).
Unlike v10–v13 there is no repository-derived image or local checkpoint: the
served tree is the upstream integration image and the deployment contract is
the upstream preset. The repository adds only pinning, credentialing, the
workstation gates, and the transactional switcher.

Upstream measured (stock clocks, no VRAM OC, four slots): 186.5 tok/s decode
C1, 403.1 tok/s decode C4 total, 10,919 input tok/s 32K prefill. The Max-Q
server validates startup and cache recovery, not these speeds.

## Final candidate configuration

- TP2 / DCP2, MTP3 (probabilistic proposals)
- `PRESET=glm53-spark-tp2`, hardware `rtx-pro-6000-pcie`
- fixed KV: 4,190,109,696 bytes per GPU (3996 MiB; `kv-cache-memory-bytes:
  4190109696`), shared by requests
- `max-model-len: -1` — memory-resolved at boot; **not pinned** (upstream
  contract; the record of the exact value is the boot receipt)
- four request slots; 3072-token prefill budget
- GPU-only prefix caching by default (request-boundary checkpoints)
- vision enabled, no one-image admission cap; TORCH_SDPA not set (preset owns
  the vision path; do not add the EXL3 K4 era mm args)
- full and piecewise CUDA graphs: capture sizes 1, 2, 4, 8, 12, 16
- NFCs: `NCCL_SOCKET_IFNAME=lo`, `GLOO_SOCKET_IFNAME=lo`, two-channel NCCL,
  `VLLM_PCIE_TWOSHOT_ALLREDUCE_MAX_SIZE=off`, `CUBLAS_WORKSPACE_CONFIG=:4096:1`
- cache host dir: `/models/vllm-cache/glm53-flash-spark-tp2-v14` → `/cache`
- HF volume: `lil-huggingface` → `/root/.cache/huggingface`

Optional LMCache pass (`CACHE_MODE=lmcache`): 16 GiB L1 arena (+2 GiB init),
64 GiB disk tier in `/cache`, 4 CPU / 2 GPU workers; `LMCACHE_L2_ENABLED=0`
drops the disk tier. Sidecar reserves 18000–18002 (API port + 10000/10001/
10002). Context ceiling then reports about 924k.

## Build and static verification

```bash
bash tests/glm53-flash-spark-tp2-v14-contract.sh
bash scripts/inference/glm53/pull-glm53-flash-spark-tp2-v14-image.sh
```

The pull script (CPU-only, no GPU allocation, no model load) proves the pinned
image's stock spark preset resolves the documented contract
(`--print-config` JSON assertions), proves the `SERVED_MODEL_NAME` override is
honoured, and writes `~/.local/state/glm53/flash-spark-tp2-v14-image.identity`.
Record the printed image id as `IMAGE_CONFIG` in the run script (the pull
script ends by saying so; the run script fails closed while unrecorded).

## Preflight

```bash
bash scripts/inference/glm53/run-glm53-flash-spark-tp2-v14.sh --preflight
```

Checks (all machine-side, on `desktop`): exactly two RTX PRO 6000 Blackwell
cards ≥ 96 GB, memory idle, power limit equal to the declarative
`gpuPowerLimitWatts` pin in `machines/desktop/default.nix`, comfyui stopped,
port 8000 free, pinned image present and still resolving from the Karmic
Kraken channel, CPU-only `--print-config` proof, and (with `CACHE_MODE=lmcache`)
the sidecar ports free plus `/dev/shm` and RAM headroom for the pinned arena.

## Transactional swap (start)

```bash
bash scripts/inference/glm53/switch-glm53-spark-tp2-v14.sh status
bash scripts/inference/glm53/switch-glm53-spark-tp2-v14.sh start
```

The switcher records the running profile set, waits for an idle endpoint
(three samples, zero running/waiting requests), stops the previous profile,
launches v14, and accepts only when `/health` is up **and** `/v1/models`
authenticates exactly one model: `glm-5.3-flash-spark-tp2-v14`. First boot
downloads the Spark checkpoint into the HF volume and does kernel prep + graph
capture; `STARTUP_TIMEOUT_SECONDS` defaults to 5400 and can be raised. On any
failure the previous profile set is restored and the failed container is
quiesced. Acceptance writes
`~/.local/state/glm53/flash-spark-tp2-v14-boot-receipt.txt` (container, model,
image, cache mode, and every log line that reports capacity) and only then
promotes `restart=unless-stopped`.

## First-boot acceptance gate

1. `docker logs -f glm53-flash-spark-tp2-v14` — confirm the engine reports the
   resolved max model length and KV capacity (upstream: ~983k GPU-only).
2. If the resolved limit differs from the 983,040 registered in
   `pi/models.json`, update the catalog after aligning the receipt; the
   registered number is used for Pi's context handling and must match reality.
3. Verify vision and reasoning directly through Pi
   (`pi --model desktop-vllm/glm-5.3-flash-spark-tp2-v14:max`), then run the
   structured/tool-call + MTP3 mixed-traffic gate before relying on it (the
   upstream image carries the grammar redesign, but tool traffic remains a
   qualification item documented in the v13 profile notes).
4. Soak ≥ 24 h before promoting in any benchmark arm.

## Rollback

```bash
bash scripts/inference/glm53/switch-glm53-spark-tp2-v14.sh stop
bash scripts/inference/glm53/switch-glm53-exl3-profile-v13.sh start   # GLM rollback
# or: bash scripts/inference/deepseek/switch-ds4-flash-vision-r21-v1.sh start
```

Any failed acceptance restores the previous profile set automatically. The
stopped profiles keep their promoted restart policies.

## Pi usage

```bash
pi --list-models glm-5.3-flash-spark-tp2-v14
pi --model desktop-vllm/glm-5.3-flash-spark-tp2-v14:max
```

`model-routing.json` publishes `glm-v14` as a named target with a
subagents-use-max rule; the catalog registers 983,040 tokens (see
`pi/README.md` for the receipt-alignment note).

## Notes and deviations

- The upstream doc starts the container with `--restart unless-stopped`;
  v14 launches with `--restart no` and promotes after acceptance — the
  repository's transactional pattern (a crash-looping target must not fight
  the switcher's rollback).
- The upstream doc's `GLM-5.3-Flash` API name is replaced by the repository
  per-profile id (attestation; documented above).
- No `HF_HUB_OFFLINE`/`TRANSFORMERS_OFFLINE`: the checkpoint downloads on
  first boot. A local HF token (private, in the env file) is passed through if
  present.
- The old EXL3 K4 switch set (`VLLM_B12X_*`, `VLLM_DCP_GLOBAL_TOPK`, TRELLIS,
  ROUTE128, PCIE_ALLREDUCE, `GLM_NOPE_*`) must not be carried; the run script
  fails closed on any of them.
- GPU-only caching is the default; enabling LMCache changes the context
  ceiling (∼924k) and reserves the sidecar ports, so it is an operator choice,
  not a default.
