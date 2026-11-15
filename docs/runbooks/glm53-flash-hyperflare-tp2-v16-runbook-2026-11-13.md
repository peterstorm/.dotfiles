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
rustc 1.97.0, `rustup-init` 1.29.3 by sha256); labelled
`ai.peterstorm.inference.hyperflare-commit`, which the
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
   First export on this box (2026-11-14, package `glm53-fp4-local@gb202-tp2-202611141415`):
   ~45 min wall — weights 101 s, graph catalog 56/56 in 77 s, cold kernel tuning
   1,144 s (1,176 kernels), core write 323 s. If tuning runs out of VRAM, the
   recipe's fix is one `CONC=4` export to fill the tuning cache, then the release
   `CONC=8` export. `VISION=0` gives the text-only package (+7.2% KV).
   Image prerequisites the recipe host had and the first exports lacked:
   `liburing-dev` + `seccomp=unconfined` (b12x's io_uring weight loader) and
   `ninja-build` (graph-catalog extensions).

   **Signing trust.** The export signs the core with a local development key it
   mints in `flare-home/.config/flare`. Unattended serving needs that key approved
   and the `local-development` publisher accepted, which also accepts the
   checkpoint's NVIDIA Open Model Agreement. The operator accepted on 2026-11-14;
   the run script pins exactly fingerprint
   `f2bca6f9fd072391b10fc6fbd7c2cafd2e0e518fde57e0b05f2d48a22ef1e052` (sha256 of
   the ed25519 public key). A re-export that mints a new key fails closed until
   the pin is updated. **Home directory:** the Rust `flare` CLI finds its store
   via `getpwuid`, the Python exporter via `$HOME`; the image points uid 1000's
   home at `/flare-home` and the scripts run only as uid 1000.
4. **Serve**: `switch-glm53-hyperflare-tp2-v16.sh start` — preflight, runtime-neutral
   idle gate (ds4 bridge :8010, Hyperflare bridge :8011, or vLLM/SGLang :8000),
   quiesce, launch at `--restart no`, accept (health, authenticated exact model
   id, **a decoded reply that says the asked-for word** — "Reply with the single
   word: ready", 64 tokens, `ready` in content or reasoning — and **the bridge on
   :8011 reporting the model**), boot receipt
   (`~/.local/state/glm53/flash-hyperflare-tp2-v16-boot-receipt.txt`, Plan/Allocate
   cache lines), promote to `unless-stopped`; any failure restores the previous
   profile set.
5. **Switching primaries** (GLM v16, its cyber hybrid, WARMIND and stock DeepSeek-V4.1 are the
   primaries): `scripts/inference/switch-primary.sh` toggles GLM or cyber
   to WARMIND (`GLM_TOGGLE_TARGET`) and either ds41 model back to GLM; `… glm|cyber|warmind|deepseek` picks one; `… status`
   reports. It idle-gates :8000, stops the active engine through its own launcher,
   starts the other, and restores the previous primary if the start fails. Both
   Hyperflare primaries go through this one switcher (`VARIANT=v16|cyber-hybrid`),
   which quiesces and rolls back across them like any other pair.

## Variant: cyber-hybrid (2026-11-15)

`VARIANT=cyber-hybrid` is v16's checkpoint with the dense tensors of
`dealignai/GLM-5.3-Flash-CYBERSECURITY-W4A16` (rev `4c2ee763…`) spliced in:
attention, shared experts, dense MLP, norms, `lm_head`, MTP. The routed experts
(163 GiB, where the abliteration is *not*), the vision tower and every
quantization declaration stay NVIDIA's, so the package has v16's shape (56 graphs,
same flags) and one launcher set serves both. `scripts/inference/glm53/hyperflare-variants.sh`
is the one table of names (checkpoint directory, container, served id, provenance);
the export, run and switch scripts derive from it and take no free `MODEL`.

- **Build** (once): `glm-hybrid-checkpoint.py plan | fetch | check | splice | verify` —
  fetch only the 854 dense tensors by HTTP range (16.9 GiB), requantize each to the
  format v16 already stores it in, reflink-copy v16's shards and patch in place.
  `check` scores the staged bytes against the base and `splice` refuses without a
  passing verdict. Result: `/models/glm53-hyperflare/glm53-cyber-hybrid`.
- **Export**: `VARIANT=cyber-hybrid scripts/inference/glm53/export-glm53-flash-hyperflare-tp2-v16.sh`
  (both GPUs idle; ~13 min with the warm kernel cache) → `package-cyber-hybrid.txt`,
  package `glm53-cyber-hybrid@gb202-tp2-<ts>`.
- **Serve**: the `cyber` primary until 2026-11-15, when `cyber` moved to
  cyber-hybrid-bf16 (below). Still launchable by hand:
  `VARIANT=cyber-hybrid scripts/inference/glm53/switch-glm53-hyperflare-tp2-v16.sh start`;
  `switch-primary.sh` then reports it as a foreign profile (`other:`) until stopped.
- **Disk**: a package is up to its checkpoint's size (168 GiB). Package blobs are
  content-addressed: cyber-hybrid's splice touches every layer and its package shared
  nothing with v16's (`/models` had 98 GiB free after it), while cyber-hybrid-bf16 is
  mostly v16's bytes and added 37 GiB (blobs 336 → 373 GiB).

## Variant: cyber-hybrid-bf16 (2026-11-15)

v16's checkpoint carrying only the splice's requantized dense tensors from layer 40
on plus `lm_head`, stored as the donor's plain BF16 (`glm53-bf16-dense.py`,
`--base glm53-fp4-local`). Layers 0–39 and the splice's copy/cast tensors stay v16's.
Hyperflare (ac9136b) refuses two projections as plain BF16, so they keep the splice's
FP8 (`kernel_fp8_prefixes`, recorded as `kept_fp8` in the plan): the KDA blocks'
q/k/v (the side-chain kernel, forced on by the recipe export, needs MXFP8 q/k/v + BF16
b/f_a) and every MLA `q_b_proj` (`PreparedGlmMLA` reads `.out_features`).

- **Build**: `glm53-bf16-dense.py plan | build | verify` → 33 BF16 tensors (2.19 GB),
  14 kept FP8, 4 shards rewritten, 38 reflinked. `build` first reads each donor
  shard's header and refuses any planned range the header does not hold
  (`confirm_source`); `verify` checks every file the index names exists and that
  `total_size` equals the payload (Hyperflare's `inspect_indexed_checkpoint` refuses
  otherwise). Then run that inspect in the image on the CPU before spending a GPU export:

      docker run --rm --user 1000:1000 --entrypoint /opt/flare/.venv/bin/python3 -w /opt/flare \
        -v /models/glm53-hyperflare/glm53-cyber-hybrid-bf16:/ckpt:ro peterstorm/glm53-hyperflare:ac9136b-cu131 \
        -c 'from ignition.preparation.checkpoint import inspect_indexed_checkpoint as i; i("/ckpt"); print("ok")'

- **Export**: `launch-glm53-export.sh cyber-hybrid-bf16` → package
  `glm53-cyber-hybrid-bf16@gb202-tp2-202611151057`, 10 min (warm kernel cache; the
  first, cold export of the BF16 shapes took 26).
- **Serve**: the `cyber` primary since 2026-11-15: `switch-primary.sh cyber` (or
  `/switch cyber`) serves container `glm53-flash-hyperflare-tp2-cyber-hybrid-bf16` as
  `glm-5.3-flash-hyperflare-tp2-cyber-hybrid-bf16` (Pi's catalog entry replaced the
  original hybrid's). v16's package and container stay in place, so
  `switch-primary.sh glm` is the rollback. Smoke on `…1057`: acceptance `ready` in 5
  tokens; "09:40 → 13:15 in minutes" → `215`; a 586-token SQL-injection explanation with
  vulnerable and parameterized Python, `finish=stop`; `get_weather({"city":"Copenhagen"})`.

### Benchmarks on `…1057` (2026-11-15): it does not carry the uncensoring

Same fixtures, settings and seeds as the earlier runs; receipts on homelab in
`/tmp/refusal-cyber-bf16-{baseline4k,low4k}`, `/tmp/glm-bf16-{259,96,317}`,
`/tmp/glm-passkey-bf16`.

**Refusals** (`refusal-probe.py`, 21 prompts, temperature 0, `max_tokens 4000`):

| build | default effort | `low` |
|---|---|---|
| v16 (stock) | 3 refusals, 2 empty (15.8%) | — |
| cyber-hybrid (all layers, FP8) | 0 refusals, 12 empty | 0 / 21 |
| cyber-hybrid-bf16 (layers ≥ 40 + `lm_head`) | **6** refusals, 1 empty (30.0%) | **6** / 21 (28.6%) |

The BF16 build refuses drugs, weapons, explosives, ransomware and the system-prompt
probe in plain stock phrasing ("I'm not going to help with this"), where the all-layer
hybrid gave answers. Carrying only the late layers' requantized tensors and `lm_head`
does not reproduce the tune's behaviour; the edit evidently lives (at least also) in
layers 0–39 or in the copy/cast tensors this variant leaves as v16's. Not yet measured
per layer.

**Thinking spiral** (`probe-glm-drift.py replay`, the 2026-11-15 Pi session, 8 seeds;
degenerate = loop or script drift):

| turn | v16 | cyber-hybrid | cyber-hybrid-bf16 | bf16 with `clear_thinking` |
|---|---|---|---|---|
| 259 (216,539 tokens) | 0/8 | 8/8 | 8/8 loops | 0/8 |
| 96 (141,101 tokens) | 0/8 | 8/16 | 3/8 drifts | 0/8 |
| 317 (102,136 tokens) | 2/8 | 6/6 | 6/8 loops | 8/8 loops |

So the late-layer tensors alone bring the spiral back without the uncensoring; glm-guard's
`clear_thinking` fixes 259 and 96 as it does for the hybrid, and 317 loops either way
(as it did for the hybrid).

**Passkey** (8K–192K tokens, depths 0.1/0.5/0.9, 2 trials): 22/24 found; both misses are
refusals to repeat a key "embedded in the content of a vault note", not retrieval
failures (the hybrid found 24/24).

### The shifted-fetch bug (2026-11-15)

The first two packages were built from the wrong bytes. A safetensors header's
`data_offsets` are relative to the data section, which starts at `8 + header length`
(`data_start`). The hybrid plan records both; `glm53-bf16-dense.py plan` copied
`begin`/`end` but dropped `data_start`, and the fetch sent them as HTTP file ranges. Every
donor tensor came from 47–126 KiB early: the shard header and the previous tensor's tail,
plausible BF16 values that pass any finiteness check.

- `…202611150903` (all 33): loaded, then every request failed with HTTP 500 "prepared
  model reported device error 1" (non-finite logits), while health, `/v1/models` and the
  bridge all passed. Acceptance gained a generated-token check.
- `…202611151034` (22 tensors in layers 40–44; `lm_head` and layer 45 held FP8 with
  `--keep-fp8` to bisect): finite, passed the token check, and decoded fluent
  multilingual token salad. Acceptance now requires the asked-for word.
- Fix (`d74cd2f2`): the plan carries `data_start`, `parse_source` refuses a plan source
  without it, `confirm_source` proves every range against the donor shard's own header
  before a byte is fetched, and the cache is keyed by the file range (bytes cached from
  the old window are never reused). The unit fixture now serves real safetensors files
  by file range; reverting the fetch to data-relative ranges fails the suite.

Cleanup, by decision: both broken packages were removed from the store
(`flare models remove --clear-default`, `flare models gc`), and the three checkpoints
built from shifted bytes (`glm53-cyber-hybrid-bf16.all33-nan`, `.r1-shifted`,
`.qkv-bf16-superseded`) were deleted with the 47 pre-fix cache files named
`<tensor>.bf16` (`/models` 147 → 175 GiB free). The fixed cache files, named
`<tensor>@<shard>@<begin>-<end>.bf16`, stay in `/tmp/hybrid-work/bf16-cache`.

## Exporting while a primary serves: launch-glm53-export.sh (2026-11-15)

The export needs both GPUs, so a Hyperflare primary has to stop first, and doing
"stop, then export" over ssh dies with the session. From the repository:

    scripts/inference/glm53/launch-glm53-export.sh cyber-hybrid-bf16
    ssh desktop cat /tmp/glm-export-cyber-hybrid-bf16.status   # poll

It refuses uncommitted changes in `scripts/inference/glm53/`, ships
`git archive HEAD` of that directory to `desktop:/tmp/glm53-export-<sha>/`, and
starts `stop-and-export-glm53-hyperflare.sh` there under `setsid`, which runs
**preflight before any stop**: the variant resolves in the variant table beside the
export wrapper, the checkpoint exists, and `/models` has the checkpoint's size free
plus 10% (a package is checkpoint-sized). The launcher waits for that verdict and
exits non-zero on a refusal, with the serving primary untouched. Only then does the
driver stop the `glm53-flash-hyperflare-tp2-*` containers (never ds4 or comfyui),
wait for idle GPUs, and run the export wrapper; `.status` gets one line per phase,
`.log` the wrapper's output. **It does not restart the primary** — afterwards
`switch-primary.sh glm` (or the new variant) brings serving back.

**Never copy the driver on its own.** 2026-11-15, 07:39Z: a lone copy in `/tmp`
picked up a stale pre-variant `export-…-v16.sh` beside it (mode 644, which reads
`MODEL`, default `glm53-fp4-local`, and only labels with `VARIANT`), stopped v16 and
failed with exit 126. Executable, it would have exported v16's checkpoint under the
`cyber-hybrid-bf16` receipt; and at 142 GiB free against a 167 GiB checkpoint, a
correct wrapper would have hit ENOSPC mid-export. Both now fail in preflight.

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

## First boot on desktop (2026-11-14)

Accepted on the third start (the first two exposed the store-path and
signing-trust issues fixed above). Switch-to-promoted **45 s**: weights
167.9 GiB in 22.7 s (warm page cache right after the export), 7,274 kernels,
`Plan cache. per GPU: 86.46 GiB loaded · 7.72–7.75 GiB cache budget`,
`Allocate cache. 15.4 GiB · 2240000 KV tokens · 86 shared snapshot slots`
(recipe served 2,231,808), host prefix cache 16.9 GiB.

Smoke results, served through `:8000` with the shared key:

| Check | Result |
| --- | --- |
| Chat, `reasoning_effort: low` | coherent 373-token answer, `finish=stop` |
| Chat, `reasoning_effort: high` | reasoning in `reasoning_content` (pi's `thinkingFormat: deepseek`), `reasoning_tokens` reported |
| Tool call | `finish=tool_calls`, `get_weather({"city":"Copenhagen"})` |
| c1 decode, 2,500-token story incl. prefill | 175 tok/s average (recipe c1 248 tok/s is ignore-EOS at 450 W) |
| MTP acceptance length (Grafana) | 1.78 (recipe: ~1.8 drafts per round) |
| TTFT server median | 0.57 s |
| Bridge / ledger / Prometheus | `:8011` model-labelled; ledger row engine `hyperflare`; target `desktop:8011` up; every `inference:*` panel except the histogram-based ones has data |

## Not yet qualified

The recipe's qualification (corruption check, eval-43, tool calls 60/60,
GPQA, KV stress) ran on its hardware. Still to run on desktop before this
replaces ds41 as the default: a decode bench at c1/c4/c8, the recipe's
`tools/verify_fix.py 20` (must report `TRUE corruptions 0`) and
`tools/tool_calls.py 60 8`.
