# GLM-5.3 v17 — upstream Hyperflare + row-sharded prefill (test profile), 2026-11-27

## What it is

A **test profile**, not a primary. v17 serves the same checkpoint as v16
(`nvidia/GLM-5.3-Flash-FP4-Local@76348ddb2be2e35e39ecfc00e75dc07703f4f3d5`, the
`glm53-fp4-local` directory) through **upstream** NVIDIA Hyperflare instead of the
AzallazA fork v16 runs, plus two open Local Inference Lab PRs:

- **hyperflare-recipes PR #55**, "GLM-5.3 TP2/TP4 row-sharded prefill, ZeRO-3 weight
  gather & MXFP8 attention". It adds `--row-shard-prefill` and `--row-shard-attention` to
  the GLM-5.3 recipe. On TP2/TP4, eligible prefill graphs run attention row-sharded across
  the GPUs, gathering attention weights on the fly. **Over PCIe that takes graphs of
  12,288+ tokens** (`ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE`; 4,096/8,192 are the RoCE
  thresholds). Smaller graphs stay head-sharded.
- **FlashInfer PR #151**: the b12x kernels PR #55 needs.
  - KDA segment summarize/finalize
  - GLM `ARBITRARY_FP32` prefill MLA fusion
  - cooperative MoE SM reservation
  - high-priority PCIe DMA streams

The question v17 answers: does row-sharded prefill speed up long-context TTFT on our
2× RTX PRO 6000 PCIe TP2 box, and at what cost in decode and KV room? The PRs' numbers
are for other hardware. Ours are unmeasured until the A/B below has run.

Nothing about v17 touches the primaries:
- It is not in `hyperflare-variants.sh`, `switch-primary.sh` or `pi/models.json`.
- It has its own container, served id, image and state root.
- `switch-primary.sh` refuses to act while v17 holds the GPUs, because it is a
  non-primary catalog profile. Going back is always deliberate (see Procedure).

| | |
|---|---|
| container | `glm53-flash-hyperflare-tp2-v17` |
| served id | `glm-5.3-flash-hyperflare-tp2-v17` |
| image | `peterstorm/glm53-hyperflare-upstream:hfic9935887-hfr71c9830c-fi6d2f90c8-cu131` (re-pinned 2026-11-28) |
| state root | `V17_ROOT`, default `/models/glm53-hyperflare-v17` (`flare-home/`, `core-<mode>.txt`, export logs) |
| checkpoint | `CKPT_ROOT`, default `/models/glm53-hyperflare` (v16's; `glm53-fp4-local/`) |
| pins | `scripts/inference/glm53/glm53-v17-hyperflare/pins.sh`, the only place a commit is written |
| contract | `tests/glm53-flash-hyperflare-tp2-v17-contract.sh`, `tests/glm53-v17-hyperflare-unit.sh` |

## Pins, and why each is what it is

| source | commit | why |
|---|---|---|
| NVIDIA/hyperflare-inference (ignition, heliopause, `flare`) | `c99358879813f22557ac619044af514fafacecc6` | the commit PR #55 was validated with (upstream main 2026-11-28 06:23Z); carries #555 (batch capacities 6/12/24), #556 (lock-free TP DispatchRing), #557 (PreparedAllToAll) |
| local-inference-lab/hyperflare-recipes | `71c9830c5720e19bc6bb6b53c028810edc09fab0` | PR #55 head, open, rebased onto main `d1376bb4` (has recipes #46/#49, the 11-27 GLM decode and prefill wins) |
| local-inference-lab/flashinfer | `6d2f90c8670691c168d762cda294dcf2f4eb6dc6` | PR #151 head, open, rebased onto main `5d2a7107` (has #146–#149), the commit PR #55's lock pins |

Both PRs were **open** when pinned. The pins above are the second set (2026-11-28); the
first set and why it was replaced are in "Re-pin" below. Pinning head SHAs means a later force-push cannot
change what this profile builds. Moving to a newer head, or to the merged commits once
they land, is a pins.sh edit plus a rebuild. The contract then fails until the new
commits are also written into it, which is deliberate.

### The stale recipes lock (finding)

On the first pin (2026-11-27), the recipes' `uv.lock` resolved ignition and heliopause to
`425ab2d4696caee841b1fc8165ff8d806a5af7e9` (2026-11-23), on PR #55's head and on recipes
main alike. That commit has no `ignition.parameters` module, yet every recipe has imported
it since recipes #54 (2026-11-26). An image built with `uv sync --locked` as the repo stood
would have failed at the first `ignition` call. The rebased head's lock names
`5adb27f259d340231c384ed668bd68e2abc313c5`, which works but is four commits behind the
`c9935887` the PR was validated with. Either way the lock is not the authority; the pins
are. So the Dockerfile re-locks:

1. **ignition**: the recipes' root `[tool.uv.sources]` entry moves from `branch = "main"`
   to `rev = <pin>`. heliopause is a path dependency inside hyperflare-inference, so it
   follows.
2. **flashinfer-python**: the recipes do **not** declare it. It arrives through
   `ignition[prepare]` as `flashinfer-python[b12x]`, and ignition's own pyproject sources it
   from `branch = "main"`. uv honours that source for the transitive requirement. The
   recipes' root flashinfer source is therefore inert. The first build (2026-11-27) proved
   it: with the root source rewritten to PR #151's rev, the lock still resolved FlashInfer
   main `8bdfd6c9`. The fix deletes the inert line and adds
   `[tool.uv] override-dependencies = ["flashinfer-python[b12x] @ git+…flashinfer.git@<pin>"]`.
   An override replaces every declaration of a package, transitive ones included. The
   `[b12x]` extra is kept because the override replaces ignition's requirement whole.
3. `uv lock` re-resolves, and the build then asserts that every hyperflare-inference and
   flashinfer source in the lock is exactly the pin. These asserts caught item 2. Without
   them the image would have built on FlashInfer main and the A/B would have compared
   nothing.
4. The version moves the re-lock made are written to `/opt/hyperflare-recipes/relock.diff`
   in the image. Read it with
   `docker run --rm --entrypoint cat <image> /opt/hyperflare-recipes/relock.diff`.
5. Then `uv sync --locked --extra test`. The image verifies three things:
   - PR #151's `kda_prefill.segment_summarize` / `segment_finalize` import
   - `Glm53Parameters` has `row_shard_prefill` and `row_shard_attention`
   - `ignition export --help` runs

## How it differs from v16

| | v16 | v17 |
|---|---|---|
| engine | AzallazA fork `ac9136b0` (+ tp3 patches, b12x overlay `85ea6e76`) | upstream `c9935887`, recipes PR #55, FlashInfer PR #151 |
| export entry | vendored `export-glm-tp2.sh` | `ignition export` straight from the recipes' venv |
| prefill | head-sharded, 4096-token chunks | `PREFILL=rowshard` (default): row-shard flags, 12288 chunks; `PREFILL=baseline`: no flags, 4096 chunks (what would be served otherwise, so the chunk size is part of the comparison) |
| scheduler | `interactive` (the fork's TTFT guard) | `balanced` (default) or `throughput`. Upstream has no `interactive`; the run script refuses it |
| host embedding / vision staging | fork-only, keeps them out of VRAM | upstream keeps embedding and vision tower in VRAM, so KV room is unknown at TP2/96 GB. `VISION=0` (`--language-model-only`) is the fallback |
| core naming | receipt `package-<variant>.txt`, `model@gb202-tp2-<stamp>` | receipt `core-<mode>.txt`, whatever `model@<version>` the exporter printed (`Exported cache entry:` line) |
| signing key | minted by the first export | the same key: the v17 export seeds `V17_ROOT/flare-home/.config/flare` from v16's (`install -m 600`, never overwrites, `cmp`-checked), so the pinned fingerprint `f2bca6f9…` the operator accepted on 2026-11-14 still applies |
| metrics | `:8011` bridge | the same bridge: upstream Helios still exports every `flare_*` series it reads |

Shared rather than copied:
- **`hyperflare-switch.sh`**, the switch transaction. Launch at `--restart no`; accept on
  health, the authenticated exact id, a decoded `ready` and the bridge; record the boot
  receipt; promote; roll back on any failure.
- **`hyperflare-workstation.sh`**, the workstation gates:
  - ComfyUI is not running
  - two 97 GB+ RTX PRO 6000s, idle, at the declared `gpuPowerLimitWatts`
  - `:8000` is free

v16's switcher and run script were refactored onto the same two libraries in this change,
so a fix to acceptance reaches both profiles.

## Procedure

### Blocker: disk (2026-11-27)

The export needs about **350 GiB** at peak:
- ~165 GiB checkpoint (v16's shards were deleted on 2026-11-16, see
  `archive-receipt-fp4-local-shards.json`, and must be re-downloaded)
- ~170 GiB core
- ~20 GiB image

Desktop's `rpool` had **39 GiB** free. A new NVMe is arriving. Until it is mounted, only
step 1 can run. Both roots are overridable, so the checkpoint and v17 state can live
entirely on the new disk.

### Steps

1. **Build** (no GPU; safe while a primary serves):
   `scripts/inference/glm53/build-glm53-flash-hyperflare-tp2-v17-image.sh`.
   - It refuses when the Docker root has under `MIN_FREE_GIB` (30) free.
   - Caches live in tmpfs mounts and never land in a layer.
   - It ends `IMAGE OK: <image>` after checking the three labels against pins.sh and
     running `flare --version`.
2. **NVMe**: mount the new disk, for example at `/models2`, and choose roots on it:
   `export CKPT_ROOT=/models2/glm53-hyperflare V17_ROOT=/models2/glm53-hyperflare-v17`.
3. **Re-download the checkpoint** (no GPU):
   `ROOT_HOST="$CKPT_ROOT" scripts/inference/glm53/download-glm53-flash-hyperflare-tp2-v16-checkpoint.sh --wait`.
   It is the same pinned revision and the same verifier v16 uses. Pointing v16 at it
   later is a `ROOT_HOST` away.
4. **Export both cores** (needs **both GPUs idle**: stop the primary first; the script
   never stops anything):

   ```
   PREFILL=rowshard scripts/inference/glm53/export-glm53-flash-hyperflare-tp2-v17.sh
   PREFILL=baseline scripts/inference/glm53/export-glm53-flash-hyperflare-tp2-v17.sh
   ```

   Gates, in order:
   - uid 1000
   - checkpoint `--verify`
   - image labels
   - free disk ≥ 1.1× checkpoint size
   - signing key seeded and identical to v16's
   - GPUs idle

   Each export writes `V17_ROOT/core-<mode>.txt` and ends with `CORE OK: …`.
   `CONC=8` is the release capacity. If kernel tuning runs out of VRAM, export once with
   `CONC=4` to fill the tuning cache, as with v16. Use `VISION=0` if the vision tower
   leaves too little KV. v16's first cold export took ~45 min. Expect the first v17 export
   to tune kernels from cold too: its store is new.
5. **Serve**: `PREFILL=rowshard scripts/inference/glm53/switch-glm53-hyperflare-tp2-v17.sh start`.
   This is the same transaction as v16. The boot receipt is
   `~/.local/state/glm53/flash-hyperflare-tp2-v17-<mode>-boot-receipt.txt`.
   `--preflight` on the run script checks image, receipt and core without touching the
   GPUs. `SCHEDULER=throughput` and `PREFIX_CACHE` are run-time knobs.
6. **Benchmark** each mode with the same probe and settings used for v16:

   ```
   scripts/inference/shared/probe-hyperflare-throughput.py --rounds c1,c4,c8,prefill \
     --prefill-sentences 750 --out ~/glm53-v17-rowshard.json
   ```

   - Repeat with `--prefill-sentences` around 2,800 (~80K tokens) and around 5,600
     (~160K tokens). Over PCIe row-sharded attention only engages on 12,288-token
     graphs, so a 22K prompt is the floor, not the case it is for.
   - Then `switch-glm53-hyperflare-tp2-v17.sh stop`, export or switch to the other mode
     (`PREFILL=baseline … start`), and rerun the same probe commands.
   - Compare prefill tok/s and TTFT (the PR's claim) against c1/c4/c8 decode tok/s and
     MTP acceptance. Neither of those should regress. Also compare the `Allocate` KV lines
     in the two boot receipts: 12,288-token chunks cost activation memory.
7. **Back to a primary**: `switch-glm53-hyperflare-tp2-v17.sh stop`, then
   `scripts/inference/switch-primary.sh glm` (or `uncensored`). `switch-primary.sh`
   refuses while v17 runs, so the stop is never implied.

## First build on desktop (2026-11-27)

- **Attempt 1 failed** at the lock assert: FlashInfer stayed on main. This is the
  transitive-source finding above. The uv override fixed it.
- **Attempt 2** reported `IMAGE OK`. The image is
  `sha256:8bebc22b01b2097136c3ffd421ec2ea55069229b3b4b364d552760cd5f08df67`, 15 GB, and
  reports `flare 0.0.0`.
  - The lock's sources are exactly `hyperflare-inference.git?rev=6d74db3a…#6d74db3a…` and
    `flashinfer.git?rev=82f23e5e…#82f23e5e…`. The override is recorded in the lock's
    `[manifest] overrides`.
  - **`relock.diff` is empty**: re-locking moved no package version, only the two git
    sources.
  - The in-image checks passed: PR #151's KDA segment kernels import, PR #55's row-shard
    parameters exist, and `ignition export --help` runs.
- While building, v16 kept serving. Afterwards `rpool` had 35 GB free.
- That image (`hfi6d74db3a-hfr3009ec52-fi82f23e5e`) was superseded before any core was
  exported from it (see Re-pin).

## Re-pin (2026-11-28)

The first pin had three problems.

1. **PR #55 at `3009ec52` had a bug.** It was the head before
   `fix(glm53): fix ZeRO-3 KDA template corruption, collective ordering, …` (2026-11-27
   19:00Z). A rowshard core exported from it was likely broken.
2. **It missed main's 11-27 merges.** Both PRs sat on older bases, so v17 lacked:
   - recipes #46 and #49 (tagged `deepseek41, glm53`: decode launch/reduction wins,
     prefill collective overlap)
   - FlashInfer #146–#149 (SM120 W4A8 MoE, mHC AllReduce, `bf16_gemv` vocabulary)
   - Hyperflare #555–#557 (batch capacities 6/12/24, lock-free TP dispatch, prepared
     all-to-all)
3. **Its chunk was too small for PCIe.** The rebased PR thresholds row-sharded attention
   by transport. On PCIe it engages at **12,288** tokens, so the first pin's 8,192-token
   chunk would have kept attention head-sharded, and the A/B would have measured only the
   row-sharded MLP/residual path.

On 2026-11-28 both PRs were rebased onto main:
- PR #55 became `71c9830c` on `d1376bb4`, squashed with recipes #64 (MXFP8 attention).
- PR #151 became `6d2f90c8` on `5d2a7107`.

The PR states it was "paired with flashinfer#151 and hyperflare-inference@c9935887", so
that is the Hyperflare pin. Its validation is **TP4 only**, at `prefill12288`:
- 22,192 prefill tok/s with MXFP8 attention, 19,908 on FP4-Local
- decode 139–144 tok/s

TP2 on this box is our own experiment. The rowshard chunk is now 12,288 (pins.sh
`V17_ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE`, pinned by the unit test).

**Rebuilt on desktop (2026-11-28): `IMAGE OK`.**
- Image `sha256:72153189efda02b868cd0d6d6f9d716f35a5f1fb2a715789f04ab7561019e4f8`, 15 GB.
- The lock's sources are exactly the three pins (`rev=c9935887…`, heliopause with it, and
  `rev=6d2f90c8…`).
- `relock.diff` is empty again.
- The recipes checkout is at `71c9830c`, and its `glm53/stack.py` has
  `ROW_SHARD_ATTENTION_MIN_TOKENS_PCIE = 12288`.
- v16 kept serving. The first image was removed, and `rpool` has 31 GB free.

Not taken: PR #55's optional MXFP8 attention. It needs an offline-quantized checkpoint
(`scripts/quantize_glm53_attention.py`), and it is a third variable. A later mode, if the
row-shard A/B is worth pursuing.

## Not yet qualified (as of 2026-11-28)

- Export, serve and every benchmark wait on the NVMe.
- Whether PR #55 and PR #151 work together at TP2 on PCIe. The PRs were developed
  together, but not on this hardware.
- KV room at TP2 with upstream's in-VRAM embedding and vision tower.
- The exact version string upstream's exporter gives a core. The receipt parser accepts
  any one path segment of `[A-Za-z0-9._-]`.
- Whether upstream `flare run` parses `--prefix-cache-memory 16G` as the fork did.
- Whether the boot receipt's Plan/Allocate grep still matches upstream's log lines. The
  receipt is informational, not a gate.
