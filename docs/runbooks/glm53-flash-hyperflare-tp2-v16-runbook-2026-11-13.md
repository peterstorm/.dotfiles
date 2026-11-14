# GLM-5.3 v16 — Hyperflare TP2 (FP4-Local) runbook, 2026-11-13

Profile `glm53-flash-hyperflare-tp2-v16`, served model id
`glm-5.3-flash-hyperflare-tp2-v16`, on desktop's two RTX PRO 6000 Blackwell
cards behind the shared `:8000` endpoint.

## What it is

GLM-5.3-Flash, as NVIDIA's FP4-Local checkpoint
(`nvidia/GLM-5.3-Flash-FP4-Local` @ `76348ddb2be2e35e39ecfc00e75dc07703f4f3d5`,
40 shards, ~178 GB), served by **NVIDIA Hyperflare** (formerly Flare): the
AzallazA fork at tag `hyperflare-glm-20261112`, commit
`ac9136b02c7c523f12d6e628e9d94f41006312ea` (upstream `cbf21a12` plus the TP3/TP2
GLM work, the TTFT guard and vision staging), with FlashInfer b12x
`85ea6e76` plus the recipe's `tp3-patches/`.

Source recipe: [AzallazA/RTX-PRO-6000-TP3-Inference-Recipes — GLM-5.3-Flash
Hyperflare-tp3-20261112](https://github.com/AzallazA/RTX-PRO-6000-TP3-Inference-Recipes/blob/main/GLM-5.3-Flash%20Hyperflare-tp3-20261112/README.md)
(recipe repo commit `9a57f78e`). Its `export-glm-tp2.sh` and `serve-glm-tp2.sh`
are vendored byte-for-byte in `scripts/inference/glm53/glm53-v16-hyperflare/`
and their git blob ids are asserted by the contract.

**TP2, not TP3.** The recipe's headline build is TP3/DCP3 on three cards;
desktop has two, so v16 is the recipe's TP2/DCP2 package (upstream's own rank
count): 8 request slots, 2 image slots, recipe-measured 2,231,808 KV tokens
served (2.1 × 1M), decode 248 / 512 / 727 tok/s at c1 / c4 / c8 (32K, 450 W),
prefill ~11,970 tok/s, 1,048,576-token context per request, MTP 5 drafts with
adaptive verification, token embedding and vision tower in host memory.

## How it differs from the recipe's test system

| | Recipe | desktop (v16) | Why |
| --- | --- | --- | --- |
| GPUs | 3 × RTX PRO 6000 (TP2 on 0,1) | 2 × RTX PRO 6000 | TP2 only |
| Power | 450 W, +75 core / +6000 mem | **400 W** (`gpuPowerLimitWatts`), no offsets | the package is exported here at 400 W so kernel tuning matches what serves; expect lower decode than the recipe table (the DeepSeek TP3 build lost 10-14% at 350 W) |
| Host RAM | 256 GB | 96 GB | `PREFIX_CACHE=16G` instead of 32G (recipe: 75 GiB resident at TP2 with 32G); host-RAM prompt reuse only, VRAM KV unchanged |
| Driver / CUDA | 615.71.09 / 13.1 | 595.112.07 / image CUDA 13.1.1 | NixOS has no `/usr/local/cuda-13.1`; the build runs in `nvidia/cuda:13.1.1-devel-ubuntu24.04` |
| Disk | ~550 GB free | checkpoint + one TP2 package (~346 GB) | only the TP2 package is exported |

## Layout on desktop

```
/models/glm53-hyperflare/
  glm53-fp4-local/        checkpoint (dir name = Hyperflare model name), .download-complete
  flare-home/             container $HOME: .cache/flare/cores (package store),
                          .cache/flare/kernels (tuning cache), .config/flare (signing key)
  brrr-ext/               torch extension builds (export)
  package-v16.txt         export receipt: package=glm53-fp4-local@gb202-tp2-<ts>
  export-v16-<ts>.log     export logs
```

Image: `peterstorm/glm53-hyperflare:ac9136b-cu131`, built locally (no published
image exists) from `glm53-v16-hyperflare/Dockerfile`, every input pinned
(base images by digest, fork by commit, `uv.lock`/`Cargo.lock` `--locked`,
rustc 1.97.0); labelled `ai.peterstorm.inference.hyperflare-commit`, which the
export and run scripts check.

## Procedure

1. **Build** (no GPU; safe while another profile serves):
   `scripts/inference/glm53/build-glm53-flash-hyperflare-tp2-v16-image.sh`
2. **Download** (no GPU): `download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh`
   (`--wait` to block and verify, `--verify` to re-check). xet is disabled and the
   container is capped at 3 GiB: on the first attempt hf_xet reassembled shards in
   RAM (4+ GiB RSS and climbing) on a host where ds41 holds ~85 GiB, which would
   have OOM-killed the serving engine. Plain HTTPS streams to disk at constant
   memory; the Wi-Fi link (~22 MB/s) is the bottleneck either way.
3. **Export** (needs **both GPUs idle** — stop the serving profile first; the
   script never stops anything): `export-glm53-flash-hyperflare-tp2-v16.sh`.
   First export on this box runs with a cold kernel-tuning cache (recipe: 22 min
   warm, 33 min first GLM export; longer here). If tuning runs out of VRAM, the
   recipe's fix is one `CONC=4` export to fill the tuning cache, then the release
   `CONC=8` export. `VISION=0` gives the text-only package (+7.2% KV).
4. **Serve**: `switch-glm53-hyperflare-tp2-v16.sh start` — preflight, runtime-neutral
   idle gate (ds4 bridge :8010, Hyperflare bridge :8011, or vLLM/SGLang :8000),
   quiesce, launch at `--restart no`, accept (health, authenticated exact model
   id, **bridge on :8011 reporting the model**), boot receipt
   (`~/.local/state/glm53/flash-hyperflare-tp2-v16-boot-receipt.txt`, Plan/Allocate
   cache lines), promote to `unless-stopped`; any failure restores the previous
   profile set.
5. **Back to ds41**: `switch-glm53-hyperflare-tp2-v16.sh stop`, then
   `docker start ds41-1017-native` (ds41-native has no switcher of its own).

## Monitoring

Hyperflare's `:8000/metrics` is unauthenticated Prometheus text, but `flare_*`
series carry no model label and `flare_prefill_tokens_total` **excludes** prefix
reuse (unlike vLLM's prompt counter). `scripts/inference/shared/hyperflare-metrics.py`
(systemd `hyperflare-metrics`, `:8011`) translates per scrape — stateless, no poll
loop — into model-labelled `hyperflare:*` series with
`prompt = prefilled + GPU-reused + host-reused`. It answers 503 whenever another
runtime owns `:8000`.

- Ledger / vllm-stats site: `vllm-stats-record` scrapes `:8011`; rows land as
  engine `hyperflare`, model `glm-5.3-flash-hyperflare-tp2-v16`.
- Prometheus job `hyperflare-desktop` scrapes `192.168.0.80:8011`; the
  `local-inference-runtime-normalization` rules map it into `inference:*`
  (tokens, requests, running/waiting, KV page usage, prefix-hit ratio, MTP
  acceptance length = 1 + accepted / draft-offering rounds, acceptance rate).
- Hyperflare exports **no latency histograms**: TTFT p50 falls back to its
  server-side rolling `flare_first_response_median_seconds`; p95/p99, ITL and
  e2e panels stay empty for this engine.

## Disk changes made for v16 (2026-11-13)

rpool had 59.5 GB free. To fit checkpoint + package:

- Deleted the v15 qad2 checkpoint cache (`/models/hf-cache/glm53-flash-qad2-tp2-v15`,
  165 GB) and its JIT cache. **v15 needs its download before it can serve again.**
- Deleted `/models/ds41/engram/model-0004{7,8}-of-00048.safetensors` (203 GB).
  These were checked only against the live `ds41-1017-native` process (which
  reads only the `.gguf` beside them) and wrongly called orphans: they were the
  Engram tables of the **`ds41-1017-maya-exl35`** profile, symlinked into
  `DeepSeek-V4.1-Flash-1017-3.5bpw/`. With them gone that profile could not
  serve, so — by decision — it was **retired**: `DeepSeek-V4.1-Flash-1017-3.5bpw/`
  (241 GB) was deleted too. Restoring it means re-running
  `download-ds41-1017-maya-exl35.sh` (~444 GB). `ds41-1017-native` is unaffected.

Lesson for the next cleanup: check `disks.nix` comments, symlinks
(`find -lname`) and every profile's run script, not just the running process.

## Not yet qualified

The recipe's qualification (corruption check, eval-43, tool calls 60/60,
GPQA, KV stress) ran on its hardware. On desktop, after the first export:
the `Allocate cache` KV count, a decode bench at c1/c4/c8, the recipe's
`tools/verify_fix.py 20` (must report `TRUE corruptions 0`) and
`tools/tool_calls.py 60 8` are the gates before this replaces ds41 as default.
