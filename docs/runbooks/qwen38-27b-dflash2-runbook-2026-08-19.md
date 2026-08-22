# Qwen3.8-27B DFlash 2 runbook — 2026-08-19

> **Historical profile.** SGLang now publishes an official Qwen3.8 DFlash2 cookbook
> and image. For new deployments use
> [`qwen38-27b-dflash2-official-runbook-2026-08-22.md`](qwen38-27b-dflash2-official-runbook-2026-08-22.md)
> and the versioned `...dflash2-sglang-v2.sh` / `switch-qwen38-backend-v3.sh`
> scripts. This document remains the local TP2 and degraded-surgery receipt.

TL;DR — serve the DFlash 2 draft alongside the existing Qwen3.8-27B target:

```bash
# 1. download the draft (desktop user's Desktop folder)
bash scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
# 2a. cut over to the surgery profile (pinned fork image, degraded v1 draft)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2
# 2b. OR cut over to REAL DFlash 2 on SGLang (full BF16, TP2) once its image is built
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native
# 2c. OR cut over to the verified local vLLM PR image (full BF16, TP2)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-vllm
# 3. rollback if anything is off
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh sglang
```

The **`dflash2-native`** mode is the "make DFlash 2 actually work" profile:
full BF16 (no FP8 anywhere — body, lm_head, KV cache, and draft are all
BF16), TP2, running the genuine DFlash 2 engine (`DFlash2DraftModel` +
`CandidateSelector` + `DFlashGroupedConv`) from the PR #35371 merge-commit
image. See *Native DFlash 2 profile (full BF16, TP2)* below.

## What DFlash 2 is

DFlash 2 (Inco AI, [blog](https://inco.ai/blog/dflash2/), [code](https://github.com/z-lab/dflash)) is a
**block-diffusion drafter** for speculative decoding: it predicts a whole block of tokens in one
parallel pass, keeps the top-16 candidates at every position, and a lightweight low-rank selector
(rank 256) traces one coherent path through them; two-tap dynamic convolutions stop the draft from
decaying toward the end of the block. Decoding is lossless — greedy output matches the target
exactly, sampling preserves its distribution.

It replaces the DSpark draft (same target model, different drafter family). Card numbers (H200,
FlashAttention 3, Qwen3.8-recommended sampling, xhigh reasoning):

| | acceptance length (GSM8K→MT-Bench) | throughput vs autoregressive, concurrency 1 / 8 |
|---|---|---|
| MTP (built-in) | 5.02 → 3.74 | 2.59× / 2.19× |
| DSpark | 4.36 → 3.01 | 2.69× / 2.23× |
| **DFlash 2** | **5.46 → 4.10** | **3.43× / 2.84×** |

Those are the card's *benchmark-condition* numbers (H200/FA3, benchmark prompts). On this
box's **pinned SGLang image** the expected acceptance is lower — see the surgery section:
the image predates DFlash 2, so today's measured range is **~2.0–3.4** (verified 2026-08-19,
`benchmarks/vllm-tps/2026-08-19-dflash2.md`). An acceptance length near 1.0 *within that*
degrades further ⇒ miswired draft, not merely weak.

## Checkpoint

| field | value |
|---|---|
| repo | `z-lab/Qwen3.8-27B-DFlash2` (mirror of `incoai/Qwen3.8-27B-DFlash2`) |
| pinned revision | `ac04198556d7e8867853cbc356807b969f311b05` (last modified 2026-08-18T20:19:51Z) |
| license | Apache-2.0 |
| size | single `model.safetensors`, 1,924,404,480 params BF16 (≈3.6 GiB) |
| draft shape | 5 layers, all `sliding_attention` (window 2048), hidden 5120, vocab 248320 |
| `dflash_config` | `block_size 8`, `mask_token_id 248070`, `selector_rank 256`, `selector_top_k 16`, `conv_group_size 16`, `conv_kernel_size 2`, `target_layer_ids [5,19,33,47,61]` |
| base model | `Qwen/Qwen3.8-27B` — the same target every profile in this repo serves |

It is a draft model only; it never runs standalone.

## Engine support status (verified 2026-08-20)

| engine | status | detail |
|---|---|---|
| SGLang | **native merge image built and live-validated** | PR [sgl-project/sglang#35371](https://github.com/sgl-project/sglang/pull/35371) merged as `c14312a66420b75ca9a11bf1817c4db1fa26b097`. The immutable local image passed BF16 TP2 model load, native `DFlash2DraftModel` routing, selector/conv graph capture, authentication, speculative metrics, sequential and concurrency-eight cells, and GPU/error gates. At 350 W it measured 124.8–125.0 tok/s plain decode, 147.8–150.5 tok/s xhigh decode, and 722.2 aggregate tok/s at concurrency eight. The older pinned custom image (`lmsysorg/sglang:qwen38-27b@sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124`) remains only for rollback and carries the degraded DFlash v1 class. See *SGLang at the merged commit* and `benchmarks/vllm-tps/2026-08-20-dflash2-sglang-native.md`. |
| vLLM | **PR-branch image built and live-validated (experimental)** | Upstream PR [vllm-project/vllm#52816](https://github.com/vllm-project/vllm/pull/52816) remains **open**, unmerged, and `mergeable_state: unstable` (checked via GitHub API 2026-08-20). No released or nightly vLLM image carries DFlash 2. The local image was built from the immutable PR head with vLLM's own `vllm-openai` Dockerfile, passed target/draft registry plus speculator probes, then completed the live TP2 GPU gate: healthy/authenticated, native target/draft routing, moving speculative counters, repeatable TPS, and no OOM/NCCL/Xid failure. See `benchmarks/vllm-tps/2026-08-20-dflash2-vllm.md`. |

Re-check before any re-pin:

```bash
curl -s https://api.github.com/repos/vllm-project/vllm/pulls/52816 | grep -E '"(merged_at|merge_commit_sha)"'
curl -s https://api.github.com/repos/sgl-project/sglang/pulls/35371 | grep -E '"(merged_at|merge_commit_sha)"'
```

**vLLM via the PR branch (experimental).** `scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh` builds the pinned PR head — not the moving `refs/pull/52816/head`: head branch `subsir/upstream-dflash2` at commit `66e5414c6d75a8529473d977f7458c140bbab8a0` (base `main @ 9842d701`), +885/-44 lines across 13 files. At pin time, check-runs were **not fully green** (`pre-run-check` failure and DCO `action_required`), so this remains explicitly experimental. The build reuses vLLM's own `docker/Dockerfile`, stage `vllm-openai` (`ENTRYPOINT ["vllm","serve"]`), with its own defaults: CUDA 13.0.3, Python 3.12, Ubuntu 24.04, NCCL 2.30.7, `torch==2.13.0` (the PR's pyproject pin), builder `pytorch/manylinux2_28-builder:cuda13.0`. Result: `peterstorm/vllm:qwen38-dflash2-pr52816-66e5414` — one-off pull + 1-2 h source build (Rust + C++/CUDA). On this 32-thread/91-GiB host the script's CPU/RAM budget selects `max_jobs=16` and `nvcc_threads=2`; vLLM's setup then runs up to eight concurrent CUDA units. Both are overridable. It prints an immutable local image ID and, once pushed, a repository digest. The post-build probe resolves the installed `dist-packages` path through `vllm.__file__`, asserts both the Qwen3.8 target and `DFlash2DraftModel` registry entries, and imports `DFlash2Speculator`.

What the PR code fixes about the serving flags (verified at the pinned SHA):

- `vllm/model_executor/models/registry.py`: `"DFlash2DraftModel": ("qwen3_dflash2", "DFlash2Qwen3ForCausalLM")` — **native registration, so no draft-config surgery on the vLLM side**; the canonical Desktop tree is mounted as-is.
- `vllm/config/speculative.py`: `DFlashModelTypes = Literal["dflash"]` — the method string stays `"dflash"` for both generations.
- `vllm/config/vllm.py`: `_is_dflash2_draft()` selects v2 by the draft's `architectures` containing `DFlash2DraftModel` and "force[s] V2 as for dspark" when it does — the checkpoint's own config is the trigger.
- Follow-ups through `66e5414c`: greedy/probabilistic drafting now honors `draft_sample_method`; redundant token/logit buffers are removed; FP32 proposal logits and shared Gumbel-max preserve the proposal contract; unquantized linear LM heads are accepted; ROCm reduction typing is fixed; and the candidate selector has an isolated compile-cache namespace.
- Speculative config, per the card: `{"method":"dflash","model":"<draft>","num_speculative_tokens":7}` (seven draft tokens per verification step, block size 8).

**Built artifact (2026-08-20):** the older `19c9351` attempt was retired when the PR gained
eight correctness and memory follow-ups. The `66e5414` build completed after bypassing only
vLLM's generic CUDA-13 wheel-publication size gate: the local wheel is 642.13 MB because it
contains FA2/FA3 and Blackwell kernels, over the 500-MB publication limit. The final image is
20.4 GB, reports `vllm 0.26.1rc1.dev920+g66e5414c6`, and passed the no-GPU capability probes.

- tag: `peterstorm/vllm:qwen38-dflash2-pr52816-66e5414`
- immutable local image ID: `sha256:f07390e05b3bfccd4aa7494fa322a0077f72fbc8842f8b17dca96e57420218a6`
- repository digest: none (local-only images do not have one; use the image ID as
  `DFLASH2_VLLM_IMAGE` for a local immutable launch, or record the GHCR digest after push)

The source commit is immutable, but upstream Docker base tags and package indexes are not all
digest-pinned; the built image ID is the identity of the artifact actually verified here. The
live gate completed on 2026-08-20 at the active 350-W cap: 120.3–120.4 tok/s sequential prose,
144.2–144.4 blended xhigh decode TPS, 731.3 aggregate tok/s at concurrency 8, and effective
acceptance length ~3.1. Full evidence: `benchmarks/vllm-tps/2026-08-20-dflash2-vllm.md`.
This remains an **experimental profile** because the engine code is unmerged with no upstream
release to bisect against, and the card numbers came from SGLang/H200 rather than this PCIe-only
dual-Blackwell workstation.

## SGLang at the merged commit (real DFlash 2)

PR #35371 **merged to SGLang main 2026-08-19** as signed commit
`c14312a66420b75ca9a11bf1817c4db1fa26b097` (base
`87a09494fa3fbd685bd7c88d6a2dbdd3135de602`). Re-checked 2026-08-20: the latest release is still
v0.5.17 (2026-08-08), and the newest immutable Docker nightly,
`20260818-c0b6474b`, predates the merge. The moving `dev` tag is not an acceptable pin. The
concrete artifact is therefore built from the signed commit:

```bash
bash scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh
# -> peterstorm/sglang:qwen38-dflash2-c14312a (SGLang's own Dockerfile, stage `runtime`;
#    nvidia/cuda:13.0.3-cudnn-devel-ubuntu24.04, ~1-2 h — hpc-ops/CUTLASS compile is the long pole)
```

- Native `DFlash2DraftModel` + `CandidateSelector` + `DFlashGroupedConv`: the launcher probes the
  image and **skips the surgery** — the canonical Desktop tree is mounted as-is (the `-sglang`
  surgery copy is then unused; harmless to leave in place).
- Upstream `c14312a6` also carries `models/dspark.py`, so the image can host both speculative
  algorithms; the DSpark profile keeps its own pinned image (rollback preserved) — consolidating all
  profiles onto the merged-commit build is a later task, not a precondition.
- The pinned fork's dflash files differ from the PR base (69–231 changed lines each), so this is a
  full from-source build, not a thin overlay on `qwen38-27b`.
- Live result at 350 W: native SGLang reached 124.8–125.0 tok/s prose decode and 722.2
  aggregate tok/s at concurrency eight. Its windowed acceptance length was 3.075 after the
  sequential cells and 3.533 after concurrency eight: below the card's H200/FA3 range, but well
  above the miswiring threshold and materially faster than the pre-merge v1-class profile.

**Built artifact (2026-08-20):** upstream's own x86 image job for this commit failed because its
Dockerfile requested unpublished `nvidia-nccl-cu13==2.28.3-1`. The local builder repairs that pin
to **2.29.7**, exactly matching torch 2.13.0+cu130; passes `BRANCH_TYPE=local` so the final image
contains the pinned checkout rather than a released package; and patches a copied Dockerfile to
reduce hpc-ops' hardcoded `-j16` (the desktop build used `-j4`). The SHA-pinned source tree remains
clean. Build time was 25m57s.

- tag: `peterstorm/sglang:qwen38-dflash2-c14312a`
- immutable local image ID: `sha256:af311253309cebbd021d4f7cc4da695d30434182e89407818200754f0d788880`
- size: 26.7 GB
- runtime: `sglang 0.5.18.dev761+gc14312a66`, torch `2.13.0+cu130`, CUDA 13.0,
  NCCL package/runtime 2.29.7
- source proof: `/sgl-workspace/sglang` reports exactly `c14312a66420b75ca9a11bf1817c4db1fa26b097`
- capability probes: Qwen3.8 target class, `DFlash2DraftModel`, `CandidateSelector`,
  `DFlashGroupedConv`, DFlash2 `EntryClass`, and DSpark import all pass
- desktop GPU probe: RTX PRO 6000 Blackwell detected at compute capability 12.0;
  `sgl_kernel` and DFlash2 import successfully with the GPU runtime active
- repository digest: none (local-only image; use the image ID for an immutable local launch)

The image completed its first live model-load and benchmark gate on 2026-08-20 and is now the
active healthy/authenticated backend. It loaded native DFlash 2 on both TP ranks, captured the
selector and draft graphs, completed every sequential and concurrency-eight request, and remained
at zero restarts with no OOM, NCCL failure, or Xid. Full results:
`benchmarks/vllm-tps/2026-08-20-dflash2-sglang-native.md`. Relaunch immutably with:

```bash
DFLASH2_NATIVE_IMAGE=sha256:af311253309cebbd021d4f7cc4da695d30434182e89407818200754f0d788880 \
  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native
```

## Native DFlash 2 profile (full BF16, TP2)

`run-qwen38-27b-bf16-dflash2-sglang-native.sh` is the sibling of the surgery
launcher for the case where you have the real engine built. It is **full
BF16** — target body, `lm_head`, KV cache, and draft are all BF16, with **no
FP8 anywhere** — and **TP2**, matching the validated quality profile flag for
flag (262K context, eight running requests, FP32 GDN state, the 08-17 mamba
cookbook pin `MAX_MAMBA_CACHE_SIZE = 8 × 5`, flashinfer, checkpoint-native
template, secure entrypoint, power-cap gate). What differs is only the engine
wiring:

| | surgery launcher (`...-dflash2-sglang.sh`) | native launcher (`...-dflash2-sglang-native.sh`) |
|---|---|---|
| default image | pinned fork `lmsysorg/sglang:qwen38-27b` (DFlash **v1** class) | merge-commit `peterstorm/sglang:qwen38-dflash2-c14312a` (real DFlash 2) |
| image reference | mandatory `IMAGE@DIGEST` | `IMAGE` **by tag**; `@DIGEST` only when `DFLASH2_NATIVE_IMAGE_DIGEST` is set |
| draft weights | v1 class **drops 23 selector/conv tensors** (crippled, ~2.0–2.7 acceptance) | native `DFlash2DraftModel` — full selector + convs |
| missing-support behaviour | falls through to isolated-copy surgery | **fails closed** (no surgery fallback) |
| draft tree served | isolated `-sglang` surgery copy | **canonical** downloaded tree, mounted as-is |
| container / cache / env | `qwen38-27b-bf16-dflash2-sglang` | `qwen38-27b-bf16-dflash2-sglang-native` (isolated: own cache dir + env file) |

Why a tag, not a digest: the merge-commit image is built locally by
`build-qwen38-dflash2-sglang-image.sh` and is **never pushed**, so it has no
registry digest — the surgery launcher's mandatory `IMAGE@DIGEST` reference
cannot address it at all. The native launcher references the image by tag and
pins by digest only if you later push the image and export
`DFLASH2_NATIVE_IMAGE_DIGEST=sha256:…`.

Why fail closed: serving the DFlash 2 checkpoint through the v1 class is
lossless but silently drops the selector/convs (see *Surgery reality*),
which negates the entire point of this profile. Rather than degrade
quietly, the launcher probes the image at boot and refuses to start unless
`DFlash2DraftModel` is registered natively.

Prerequisite: build the engine once —
`bash scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh`
(`peterstorm/sglang:qwen38-dflash2-c14312a`), **or** build it in CI and pull
it (see *Building the engine images in CI* below). Contract:
`tests/qwen38-dflash2-native-contract.sh`.

## Building the engine images in CI (GitHub Actions)

The from-source builds are heavy (1–2 h, tens of GB) and need no GPU — the
compile is CPU-bound and both build scripts' verification probes are
import-only. So they run in GitHub Actions and publish to GHCR, letting the
desktop `docker pull` instead of compiling locally.

| workflow | builds | publishes |
|---|---|---|
| `.github/workflows/build-dflash2-sglang-image.yml` | `build-qwen38-dflash2-sglang-image.sh` (SGLang merge commit `c14312a6`) | `ghcr.io/<owner>/sglang:qwen38-dflash2-c14312a` |
| `.github/workflows/build-dflash2-vllm-image.yml` | `build-qwen38-dflash2-vllm-image.sh` (vLLM PR #52816 head) | `ghcr.io/<owner>/vllm:qwen38-dflash2-pr52816-66e5414` |

Both are **manual** (`workflow_dispatch`, `push` input defaults true) — SHA-pinned
heavy builds, not per-push. Each job reclaims disk (deletes preinstalled
toolchains, moves Docker's data-root to the larger `/mnt` volume), reuses the
checked-in build script verbatim (single source of truth for the pinned SHA,
Dockerfile stage, and verification), then tags + pushes to GHCR with the
run's `GITHUB_TOKEN` (`packages: write`). Optional Docker Hub login (secrets
`DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`) avoids base-image pull rate limits.

Run them from the Actions tab (or `gh workflow run build-dflash2-sglang-image.yml`).
Standard runners are 4 vCPU; the vLLM from-source build is the one most likely
to approach the job time cap — bump `runs-on` to a larger runner if it times
out. **Blackwell kernel coverage comes from the Dockerfiles, not the build
host**, so a GPU-less CI build is fine; the live acceptance gate below still
runs on the desktop after pull.

**Pull onto the desktop** (re-tags GHCR → the canonical `peterstorm/…` names
the launchers default to, so nothing else changes):

```bash
# GHCR needs auth unless the package is public:
#   export GHCR_TOKEN=<PAT with read:packages>   # GHCR_USER defaults to the owner
bash scripts/inference/qwen38/pull-qwen38-dflash2-images.sh          # both
bash scripts/inference/qwen38/pull-qwen38-dflash2-images.sh sglang   # SGLang only
```

Or skip the re-tag and point a launcher straight at GHCR via
`DFLASH2_NATIVE_IMAGE=ghcr.io/<owner>/sglang:qwen38-dflash2-c14312a` (SGLang) or
`DFLASH2_VLLM_IMAGE=ghcr.io/<owner>/vllm:qwen38-dflash2-pr52816-66e5414` (vLLM).

Serve once the image is local (both are hard-stop cutovers on :8000):

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native  # SGLang, real DFlash 2, BF16 TP2
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-vllm    # vLLM, DFlash 2 (PR #52816), BF16 TP2
```

## Draft-config surgery (why the launcher copies the draft)

The checkpoint declares `architectures: ["DFlash2DraftModel"]`. The image's model registry does
**not** know that name — it only has `DFlashDraftModel` (`sglang/srt/models/dflash.py`) and the
DSpark classes. The launcher therefore prepares an **isolated copy** at
`$HOME/Desktop/Qwen3.8-27B-DFlash2-sglang` — next to the canonical tree, because `/models` is
`root:root` on this box and the launcher runs unprivileged — with that one field rewritten to
`["DFlashDraftModel"]` (everything else byte-identical, idempotent, rebuilt only when stale). The
downloaded canonical tree is never modified — same pattern as the DSpark-on-vLLM launcher. **This
applies to the pinned pre-merge image only:** the launcher probes the image at boot and, when
`DFlash2DraftModel` is registered natively (any build at/after `c14312a6`), serves the canonical
tree as-is and skips the copy entirely (see *SGLang at the merged commit*).

**Surgery reality (verified 2026-08-19 — read before trusting this profile's speed):**
the pinned image's `DFlashDraftModel` is the **DFlash v1** class. PR #35371's `dflash.py`
(1000 lines) adds `DFlashGroupedConv`, `CandidateSelector`, and `DFlash2DraftModel`; the
image's (589 lines) has none of them. The checkpoint carries **23 DFlash 2-specific
tensors** the v1 class has no module for — `candidate_selector.{hidden_projection.weight,
predecessor_codebook, successor_codebook}` plus `layers.{0..4}.{attention,mlp}_conv.
{base_kernel, kernel_projection.weight}` — and the loader **silently drops all 23** (no
warning in the boot log). Result: a *crippled* draft (backbone + target-hidden projection
only, no dynamic convs, no candidate selector, v1 sampling). Measured 2026-08-19:
`spec_accept_length` 2.0–3.4 across all windows (DSpark on the same box: 3.45–3.575),
77.1 tok/s prose-decode and 19.2–19.9 s on the xhigh 1500-tok probe cell vs DSpark's
84.2 / 16.8 s — the card claims the opposite. It is **lossless and correct**, just not the
real DFlash 2. Do not use this profile as a DFlash 2 performance baseline; for real DFlash 2
use the vLLM PR image (native, no surgery) or the SGLang merge-commit build — PR #35371 is now
**merged to main as `c14312a6`** (2026-08-19). The compatibility check showed the pinned fork's
dflash files differ from the PR base (69–231 changed lines each), so the SGLang path is a **full
from-source build at the merge commit** (`build-qwen38-dflash2-sglang-image.sh`), not a thin
overlay — see *SGLang at the merged commit*.

## Prerequisites

- The Qwen3.8-27B target at `/models/Qwen3.8-27B` (`download-qwen38-27b.sh`).
- Docker + exactly two queryable GPUs with power caps applied (the launcher fails closed above
  450 W). The checked-in NixOS configuration declares 450 W, but the desktop's current boot
  generation applies **350 W**; that is safe for serving but does not reproduce the 450-W
  benchmark rows. Check `nvidia-smi --query-gpu=index,power.limit --format=csv` before comparing
  throughput.
- `jq` (core-apps package set) for the config surgery.
- The shared key helpers (`scripts/inference/shared/inference-api-key.sh`) — same as every other
  profile; the API key never appears in Docker args or `/proc` cmdline.

## 1. Download

```bash
bash scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
docker logs -f qwen38-dflash2-model-dl   # ...until DOWNLOAD_COMPLETE
```

- Destination: `$HOME/Desktop/Qwen3.8-27B-DFlash2` — deliberately the desktop user's Desktop
  folder for this checkpoint (override: `DFLASH2_DEST=/models/Qwen3.8-27B-DFlash2`). The
  launcher's default matches; if you move the tree later, set `DFLASH2_DRAFT_HOST`.
- Pinned to revision `ac04198`; idempotent and resumable (re-run after an interruption).
- Verify:

```bash
jq -e '.architectures == ["DFlash2DraftModel"] and .dflash_config.block_size == 8' \
  "$HOME/Desktop/Qwen3.8-27B-DFlash2/config.json"
ls -lh "$HOME/Desktop/Qwen3.8-27B-DFlash2/model.safetensors"   # 3,848,817,896 bytes on the 2026-08-19 download
```

The download container runs as root and hands the tree back to the desktop user via an
in-container `chown` (this host's user cannot sudo non-interactively). If an older run left the
tree root-owned, one-time fix: `sudo chown -R $USER:users "$HOME/Desktop/Qwen3.8-27B-DFlash2"`.

## 2. Serve

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2
```

The switcher performs the standard hard-stop cutover: stop the current :8000 server (as of
2026-08-19 that is `qwen38-27b-bf16-dspark-sglang-v2`), wait for the port to free, start
`qwen38-27b-bf16-dflash2-sglang`, wait for health, then verify the synchronized desktop-user key
is accepted. :8000 is **down between stop and first healthy response** — the first start compiles
kernels and CUDA graphs (budget: 20 min, `HEALTH_TIMEOUT` seconds). Anything mid-request during
the cutover: resend it.

Direct launch (bypasses the switcher's cutover/health logic):

```bash
bash scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang.sh
```

Launcher defaults: TP2 BF16, 262144 context, 8 running requests, FP32 GDN state,
`extra_buffer` mamba strategy with the 08-17 cookbook pin (`MAX_MAMBA_CACHE_SIZE = 8 × 5`),
flashinfer, checkpoint-native template (`enable_thinking`, `preserve_thinking`,
`reasoning_effort xhigh`), multimodal enabled, `DFLASH2_BLOCK_SIZE=8`
(`--speculative-algorithm DFLASH --speculative-num-draft-tokens 8`), secure entrypoint, crash
evidence archived to `~/.local/state/qwen38/container-archives/`.

Notes:

- No `SGLANG_RAGGED_VERIFY_MODE`: the DSpark v2 launcher exports it, but this image build has no
  consumer for that variable (verified by grep); it was not replicated.
- The DFLASH spec path takes the block size via `--speculative-num-draft-tokens` (the
  `--speculative-dflash-block-size` alias is equivalent); DFlash 2's window is 8 — seven draft
  tokens per verification step plus the bonus position.

## 3. Validation gate (first boot, and after any re-pin)

For the pinned/degraded SGLang profile:

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status
curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_' | head
nvidia-smi --query-gpu=index,power.draw,temperature.gpu --format=csv
```

- `status` must report `qwen38-27b-bf16-dflash2-sglang`, health OK, client authentication OK.
- `sglang:spec_*` counters must move. `spec_accept_length` is a **windowed** gauge (8-token
  blocks = 1 bonus + 7 drafts) and reads low for the first moments after boot — not a fault.
  On **this image** expect **~2.0–4.3** live / **~2.0–2.4** on the controlled
  probe cells (verified 2026-08-19, two probe runs; DSpark on the same box:
  3.45 cells / 3.575 live — see
  `benchmarks/vllm-tps/2026-08-19-dflash2.md`). The card's **4.1–5.5** needs
  PR #35371's code, which the pinned image lacks (see *Surgery reality*); on the
  `c14312a6` build (*SGLang at the merged commit*) the same gate expects the
  card's range under the card's conditions.
  If it sits near **1.0** under sustained traffic the draft is additionally
  miswired — check
  the log for `Initialized DFLASH draft runner ... block_size=8` and re-verify the surgery
  copy: `jq -c .architectures` must be `["DFlashDraftModel"]`, `jq -c .dflash_config` must
  keep `block_size: 8` + `mask_token_id: 248070`.
- Both GPUs within the 450 W cap; sustained load clean before benchmarking.
- A/B against the DSpark v2 profile (same target, same flags, one drafter apart) before
  promoting DFlash 2 as the default: switch `sglang` ⇄ `dflash2` and compare acceptance +
  throughput in the Grafana DSpark panels.

For the native SGLang merge image, launch by immutable local image ID and verify the engine-specific
startup evidence plus metrics:

```bash
DFLASH2_NATIVE_IMAGE=sha256:af311253309cebbd021d4f7cc4da695d30434182e89407818200754f0d788880 \
  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status
docker logs qwen38-27b-bf16-dflash2-sglang-native 2>&1 \
  | grep -E 'Load weight end.*DFlash2DraftModel|Initialized DFLASH|selector decode'
curl -fsS http://127.0.0.1:8000/metrics | grep -E '^sglang:spec_'
```

The status must name `qwen38-27b-bf16-dflash2-sglang-native`; health and authentication must be
OK. Logs must show `DFlash2DraftModel`, block size 8, fused KV materialization, and selector decode
inside the draft graph. On the controlled local probes the windowed acceptance length was 3.075
sequential and 3.533 at concurrency eight. Preserve and compare against
`benchmarks/vllm-tps/2026-08-20-dflash2-sglang-native.md` after every re-pin or tuning change.

For the vLLM PR image, use an immutable local reference for the first cutover and verify the
engine-specific architecture and metrics (the generic switcher output now prints the same gate):

```bash
DFLASH2_VLLM_IMAGE=sha256:f07390e05b3bfccd4aa7494fa322a0077f72fbc8842f8b17dca96e57420218a6 \
  bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-vllm
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh status
docker logs qwen38-27b-bf16-dflash2-vllm 2>&1 \
  | grep 'Resolved architecture' | head -2
curl -fsS http://127.0.0.1:8000/metrics \
  | grep -E '^vllm:spec_decode_num_(drafts|accepted)' | head
```

The resolved target must be `Qwen3_5ForConditionalGeneration`; the draft must be
`DFlash2Qwen3ForCausalLM` from `qwen3_dflash2`, not a DFlash v1 fallback. Health and client
authentication must be OK, draft/accepted counters must move under traffic, both GPUs must stay
free of Xid errors, and output must remain correct. Because these GPUs communicate through PCIe
PHB rather than NVLink, do not transplant the H200 throughput claim. The first local
concurrency-1 and concurrency-8 baseline passed at 350 W; preserve and compare against
`benchmarks/vllm-tps/2026-08-20-dflash2-vllm.md` after every re-pin or tuning change.

## Rollback

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh sglang    # DSpark v2 SGLang (same engine)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh v1-sglang # 08-16 SGLang
```

The DFlash 2 trees (Desktop canonical draft, Desktop `-sglang` surgery copy,
`/models/sglang-cache/qwen38-bf16-dflash2` cache) are side-by-side with every other profile's
trees; rolling back touches nothing of them.

## Watch-list

1. **sgl-project/sglang#35371 — MERGED 2026-08-19** (main at `c14312a6`) → the local
   merge-commit build (`peterstorm/sglang:qwen38-dflash2-c14312a`) is the pin for now; re-pin
   the dflash2 profile to the first official release/nightly that contains the merge, and
   re-validate on the box before dropping the custom image.
2. **vllm-project/vllm#52816 merge** → re-point the vLLM profile at the first
   official nightly that verifiably contains it (record tag + digest), retire
   the PR-branch image. Until then the PR image's pin is the head SHA above;
   if the PR head moves, decide deliberately whether to re-pin.
3. **First official SGLang release/nightly containing `c14312a6`** → re-pin the dflash2 profile
   from the local merge-commit build to the official image; the surgery path stays in the launcher
   (it self-disables on native images) until every profile is off the pinned fork image.
4. **Checkpoint revision drift** — the pinned sha is `ac04198`; if `z-lab` pushes new weights,
   decide deliberately whether to re-pin (weights are not byte-identical across revisions).
5. Concurrency-1 numbers (card's 3.43×) are the headline use case for Pi; the 8-request profile
   here will land lower (≈2.8× class) — benchmark both before judging.
