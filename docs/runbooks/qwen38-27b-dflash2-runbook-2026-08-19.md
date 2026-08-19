# Qwen3.8-27B DFlash 2 runbook — 2026-08-19

TL;DR — serve the DFlash 2 draft alongside the existing Qwen3.8-27B target:

```bash
# 1. download the draft (desktop user's Desktop folder)
bash scripts/inference/qwen38/download-qwen38-27b-dflash2.sh
# 2a. cut over to the surgery profile (pinned fork image, degraded v1 draft)
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2
# 2b. OR cut over to REAL DFlash 2 (full BF16, TP2, merge-commit image) once built
bash scripts/inference/qwen38/switch-qwen38-backend-v2.sh dflash2-native
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

## Engine support status (verified 2026-08-19)

| engine | status | detail |
|---|---|---|
| SGLang | **degraded on the pinned image; real support merged upstream 2026-08-19** | The pinned custom build (`lmsysorg/sglang:qwen38-27b@sha256:506525a5907ea22c9d445afb7c03603959b912de034d86915cf17da814f1a124`, `0.0.0.dev0+qwen38.27b.g561c8f3`, CUDA 13.0.3) carries the DFlash **v1** stack only: `SpeculativeAlgorithm.DFLASH` → `DFlashWorkerV2`, `DFlashDraftModel` (`models/dflash.py`, 589 lines). It does **not** carry DFlash 2's `DFlashGroupedConv` / `CandidateSelector` / `DFlash2DraftModel`. Consequence: the surgery loads the DFlash 2 checkpoint into the v1 class (23 conv/selector tensors dropped, silently) — lossless and functional, but ~2.0–2.7 acceptance instead of the card's 4.1–5.5. DFlash 2 proper is now **merged upstream**: [sgl-project/sglang#35371](https://github.com/sgl-project/sglang/pull/35371) → main at `c14312a66420b75ca9a11bf1817c4db1fa26b097` (merged 2026-08-19T00:07:28Z). Build it with `scripts/inference/qwen38/build-qwen38-dflash2-sglang-image.sh`; the launcher auto-detects native support and skips the surgery. See *Surgery reality*, *SGLang at the merged commit*, and `benchmarks/vllm-tps/2026-08-19-dflash2.md`. |
| vLLM | **PR-branch image (experimental, in build 2026-08-19)** | Upstream PR [vllm-project/vllm#52816](https://github.com/vllm-project/vllm/pull/52816) is **open** (checked via GitHub API 2026-08-19) — no released or nightly vLLM image carries DFlash 2, and this box had no vLLM image at all. Rather than wait, we build vLLM's own Dockerfile (`--target vllm-openai`, the same image variant as `nightly-aa99034`) from the pinned PR head: see *vLLM via the PR branch* below. |

Re-check before any re-pin:

```bash
curl -s https://api.github.com/repos/vllm-project/vllm/pulls/52816 | grep -E '"(merged_at|merge_commit_sha)"'
curl -s https://api.github.com/repos/sgl-project/sglang/pulls/35371 | grep -E '"(merged_at|merge_commit_sha)"'
```

**vLLM via the PR branch (experimental).** `scripts/inference/qwen38/build-qwen38-dflash2-vllm-image.sh` builds the pinned PR head — not the moving `refs/pull/52816/head`: head branch `subsir/upstream-dflash2` at commit `19c9351904df4c63042671bc67a866ca48dc7d6f` (base `main @ 9842d701`), commit check-runs **SUCCESS** at pin time, +755 lines across 11 files. The build reuses vLLM's own `docker/Dockerfile`, stage `vllm-openai` (`ENTRYPOINT ["vllm","serve"]`), with its own defaults: CUDA 13.0.3, Python 3.12, Ubuntu 24.04, NCCL 2.30.7, `torch==2.13.0` (the PR's pyproject pin), builder `pytorch/manylinux2_28-builder:cuda13.0`. Result: `peterstorm/vllm:qwen38-dflash2-pr52816-19c9351` — one-off pull + 1-2 h source build (Rust + C++/CUDA); idempotent, prints the manifest digest on completion. The post-build probe asserts the `DFlash2DraftModel` registry entry and imports `DFlash2Speculator`.

What the PR code fixes about the serving flags (verified at the pinned SHA):

- `vllm/model_executor/models/registry.py`: `"DFlash2DraftModel": ("qwen3_dflash2", "DFlash2Qwen3ForCausalLM")` — **native registration, so no draft-config surgery on the vLLM side**; the canonical Desktop tree is mounted as-is.
- `vllm/config/speculative.py`: `DFlashModelTypes = Literal["dflash"]` — the method string stays `"dflash"` for both generations.
- `vllm/config/vllm.py`: `_is_dflash2_draft()` selects v2 by the draft's `architectures` containing `DFlash2DraftModel` and "force[s] V2 as for dspark" when it does — the checkpoint's own config is the trigger.
- Speculative config, per the card: `{"method":"dflash","model":"<draft>","num_speculative_tokens":7}` (seven draft tokens per verification step, block size 8).

Status: first build attempt 2026-08-19 died (`buildx: Canceled: context canceled` — the
buildx client died with the launching ssh session); **relaunched detached (setsid+nohup)
2026-08-19**, buildkit cache warm. The manifest digest, the vLLM run script, and the
`dflash2-vllm` switcher mode land here as soon as the build verifies. This remains an **experimental profile**: unmerged, unreviewed engine code with no upstream release to bisect against, and the card's benchmark numbers are SGLang-only.

## SGLang at the merged commit (real DFlash 2)

PR #35371 **merged to SGLang main 2026-08-19** (merge commit `c14312a66420b75ca9a11bf1817c4db1fa26b097`,
base `87a09494fa3fbd685bd7c88d6a2dbdd3135de602`). No release or nightly carries it yet (v0.5.17 is
2026-08-08; the newest nightly at pin time, `20260818-c0b6474b`, predates the merge), so the concrete
pin is a build from the merge commit:

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
- Expectation check: if the 08-19 diagnosis holds (v1-class draft caps acceptance at ~2–2.7), the
  `c14312a6` image should approach the card's 4.1–5.5 under the card's conditions and beat DSpark's
  84.2 tok/s prose cell. If it doesn't, the diagnosis is wrong — re-investigate before believing
  either engine.

**Status 2026-08-19:** build queued behind the vLLM PR build (CPU contention); log at
`~/.local/state/qwen38/sglang-dflash2-build.log`. On completion: record the digest in this section,
flip the launcher defaults (`DFLASH2_IMAGE` / `DFLASH2_IMAGE_DIGEST` or the baked-in `IMAGE`/
`DIGEST` lines), re-run the validation gate, then A/B against the DSpark v2 profile.

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
| `.github/workflows/build-dflash2-vllm-image.yml` | `build-qwen38-dflash2-vllm-image.sh` (vLLM PR #52816 head) | `ghcr.io/<owner>/vllm:qwen38-dflash2-pr52816-19c9351` |

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
`DFLASH2_VLLM_IMAGE=ghcr.io/<owner>/vllm:qwen38-dflash2-pr52816-19c9351` (vLLM).

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
- Docker + two GPUs with power caps applied (the launcher fails closed above 450 W).
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
