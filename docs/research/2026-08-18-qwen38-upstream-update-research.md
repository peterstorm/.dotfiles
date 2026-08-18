# Qwen3.8-27B runbook upstream-update research — 2026-08-18

**Scope.** Both Qwen3.8-27B runbook profiles (vLLM and SGLang), the two
experimental DSpark profiles, and everything they pin: images, model/draft
revisions, engine issue/PR state, recipes/cookbook docs, and community
evidence. The runbook pins date from 2026-08-16; this research covers
upstream movement from that date to 2026-08-18 (~18:00 UTC), plus the
broader 08-14→08-18 window where it matters.

**Method.** Direct queries against the GitHub API (vllm-project/vllm,
vllm-project/recipes, sgl-project/sglang), the Docker Hub registry API
(manifest-level, not just tag push dates), the Hugging Face API (repo heads,
commits, per-file tree diffs), the SGLang cookbook, HN Algolia,
discuss.vllm.ai, TheTom/offlabel, and fakoli/anvil-serving. Raw responses are
kept under `qwen38-2026-08-18-evidence/`. Reddit blocked unauthenticated
JSON access (both www/old and pullpush) — noted, not a silent gap.

---

## 1. Verified unchanged — the current pins still hold

| Pin (as of the 08-16 runbook) | Status on 08-18 |
|---|---|
| `Qwen/Qwen3.8-27B` @ `1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` | Still the repo HEAD (lastModified 08-14). No new Qwen3.8 checkpoint of any kind: the org publishes only `Qwen3.8-27B`, `-FP8`, `Qwen3.8-2.4T-A95B`, `-FP8`. |
| `vllm/vllm-openai:qwen38` — AMD64 manifest `sha256:d392f621…` | Unchanged; tag last push 08-12. (The bare tag's multi-arch *list* digest differs from the pinned manifest digest — same pattern the vLLM DSpark pin already follows; the arch manifest is what we pin and it is byte-identical.) |
| `lmsysorg/sglang:qwen38-27b` — AMD64 manifest `sha256:506525a5…` (base `c4271c3fe`) | Unchanged; tag last push 08-14. Same list-vs-manifest distinction. |
| vLLM release line | **v0.27.1 (2026-08-11) is still the newest release.** No v0.27.2, no v0.28. |
| SGLang release line | **v0.5.17 (2026-08-08) is still the newest release.** |
| SGLang PR #31195 (cross-TP compact verify-budget hang — the reason the DSpark profile runs `SGLANG_RAGGED_VERIFY_MODE=static`) | Still open; no activity since 08-10. **Static verify remains mandatory at TP2.** |
| SGLang PR #33795 (CUDA-graph capture JIT race) | Still open; no activity since 08-11. |
| SGLang #32467 (ragged-plan race) | Merged 08-12 as the runbook records. |
| vLLM #50021 (original GDN spec-decode safety PR) | Still open (superseded in practice by merged #51812 + #51674, as the runbook already states). |
| vLLM #52475 (MTP + turboquant KV collapse), #52481 (MTP multimodal warning) + fix #52485 | All still open. The "keep BF16 KV while MTP is on" guidance stands. |
| vLLM #51884 (SM120 block-FP8 loader) | Still open, and **re-reproduced 08-17 on 4× RTX PRO 6000 Server Edition (SM120), vLLM 0.27.1**. The dual-profile "disable DeepGEMM" workaround stays correct for 0.27.1-era images. (The vLLM recipe's new sm120 claim that FP8 "loads unaided" was measured on `0.26.1rc1.dev608+g99a10304d` — a different, older dev build. Treat as build-specific.) |

---

## 2. vLLM baseline runbook (BF16 TP2, MTP-gated)

### 2.1 #52469 is resolved — the "streamed-delta corruption" risk was a harness artifact

Closed **2026-08-16 04:16 UTC, `not_planned`**, with a full root-cause write-up
from the reporter (`commdata2338`). The "corruption" was their own SSE
extraction: `grep -o '"content":"[^"]*"'` truncates a JSON string at the first
escaped quote, and MTP's multi-token deltas put quote-bearing text in single
deltas — so whole words appeared to vanish *only with MTP on*, mimicking a
streaming bug (evidence in `qwen38-2026-08-18-evidence/vllm/vllm-52469-comments.json`).
Instrumented verification across 3 boots, sequential + 8-way concurrent, chat
and raw `/v1/completions`: streamed output **byte-identical to non-streamed at
every hop** (detokenizer, collector, wire).

**Runbook consequence.** Remove #52469 from the open-risks list. If the
streamed-vs-non-streamed canary survives in the MTP gate, it must parse SSE
with a real JSON parser (`jq`), never a regex/grep pipeline.

### 2.2 #52480 (the TP≥2 MTP blocker) — still open, now actively worked

`jungjiyu` took it on 08-16 ("I'll work on a fix today") and posted substantive
debugging (evidence: `vllm/vllm-52480-comments.json`). Key development: the
failing drafter shape `[5120, 4352]` is exactly the **TP2 NVFP4-packed**
`down_proj` storage shape (`17408 / 2 (TP) / 2 (FP4 per byte)`); with the MTP
exclusions applied the linears resolve to `UnquantizedLinearMethod` and load
fine — pointing at the ModelOpt exclusion path. No fix PR exists yet (searched
`is:pr "52480"`: only unrelated hits).

**Runbook consequence.** "No fix PR exists as of this writing" →
"assigned and root-causing since 08-16 (NVFP4 exclusion hypothesis)". The
gate itself is unchanged: MTP stays off at TP≥2 until the fix lands (or the
TP1 profile is accepted).

### 2.3 Newer vLLM nightlies (MTP-gate item #2: "pin an image that demonstrably contains #51812 and #51674")

Older than our DSpark pin `ac7509e2` (08-14) is now several commits stale.
Current candidates (evidence: `docker/docker-hub-snapshot-2026-08-18.txt`):

- **`vllm/vllm-openai:nightly-aa9903490c616dc6871e5acc62cec7bb1e5e9434`** —
  pushed 08-18 06:12 UTC, source commit `aa99034` dated 08-18 04:59 UTC,
  **AMD64 digest `sha256:7eb4028507367e69cb0abfa213042d1814c27c1b499af45fbffec8f16d9cbc6f`**.
  Post-dates every merge below. **This is the proposed v2 pin.**
- `nightly-dev-x86_64-cu13.0.1-d62ad46` — pushed 08-18 11:18 UTC (newer still,
  but a `-dev` build; `aa99034` is the plain `nightly`-line tag).
- `#52480` is **not** fixed in any of them.

Merged vLLM PRs since the 08-14 pin (all nightly-only; none in a release):

| PR | Merged | Why it matters here |
|---|---|---|
| **#52197** | 08-17 16:48 | DSpark drafts with `architectures=DSparkDraftModel` + `model_type=qwen3` are now **natively normalized to `Qwen3DSparkModel`** in `vllm/config/speculative.py` (method auto-detect + architecture rewrite). See §4.1. |
| **#52539** | 08-18 01:17 | Fused GDN MTP decode kernel now supports Qwen's head ratios — direct perf on the MTP path we're gated on. |
| **#50729** | 08-17 06:29 | `[Bugfix][Mamba] Fix overlapping state copy race` — hybrid-GDN concurrency robustness (our 8-request soak). |
| **#50685** | 08-14 03:58 | Keeps Qwen3Next layer boundaries sequence-parallel (TP bugfix). |
| #51395 | 08-17 23:58 | SM120 MLA FlashInfer sparse-prefill fix (MLA-only; not our architecture). |

### 2.4 vLLM recipes repo moved past the runbook's pinned commit (`0025768` → `62a146b`)

Full diff in `qwen38-2026-08-18-evidence/recipes/`. Three commits touch
`models/Qwen` since the pin:

- **`f69631f` (08-17) — "Verify Qwen3.8-27B on RTX 5090 (1x and 2x, sm120)"
  (PR #810).** Our exact card class, consumer Blackwell sm120, verified
  08-15 on vLLM `0.26.1rc1.dev608+g99a10304d`. New "2× RTX 5090" section:
  at 262K, MTP acceptance **0.771 (FP8) / 0.897 (Inferact NVFP4) /
  0.788 (unsloth NVFP4)** on TP2; NVFP4 runs the real
  `FlashInferCutlassNvFp4LinearKernel` (not an emulation fallback); KV pools
  377K–920K tokens; unsloth's mixed-precision NVFP4 leaves ~2× the KV of
  Inferact's uniform W4A4 (the two builds are not interchangeable on 32 GB
  cards). Also: 1×5090 NVFP4 needs `--enforce-eager` (graph capture OOMs
  outside the memory budget; `--gpu-memory-utilization` does not help).
- **`62a146b` (08-18, today) — Ascend 950PR support (PR #819):** new W8A8
  Ascend variant (`Eco-Tech/Qwen3.8-27B-w8a8`), a `qwen3_5_mtp` recipe mode
  (Ascend-only; `qwen3_5_mtp` aliases `mtp` and logs a deprecation warning).
  Not applicable to this box; confirms the aliasing fact.
- The recipe's own comment reaffirms: the GDN spec fixes (#51812/#51674) are
  in **no released tag** — still true.

### 2.5 New upstream issues to watch (filed 08-16 → 08-18, Qwen3.8-relevant)

- **#52583** — prefix caching hangs with large multimodal inputs (Qwen3.8-VL);
  CPU-bound hash alignment blocks prefill. We run prefix caching + vision:
  keep an eye on the 262K image ladder.
- **#52540** — ModelOpt NVFP4 on SM120 dies or wedges under sustained load with
  CUDA graphs. Relevant only if we ever adopt an NVFP4 profile.
- **#52564** — qwen3.8-27b-**fp8** toolcall auto-stop; we're BF16, but the
  family quirk is worth knowing.
- **#52654** — `--mm-encoder-tp-mode data` crashes on multi-image (NVFP4, TP4,
  sm120). We don't pass that flag.
- **#52767** — MTP spec decode still advances the grammar matcher after
  termination (residual after #44297). MTP + structured decoding edge.
- **#52756** — V1 MTP max_model_len skip emits zero-token drafts → 0%
  acceptance. MTP edge case.
- **#52520** — hybrid Mamba + `--mamba-cache-mode align`: request near the
  KV-pool ceiling re-prefills forever, zero output, zero preemption
  accounting. We don't set `mamba-cache-mode`.
- **#52479** — sleep-mode Level 2 wake does not reload draft weights. Only if
  we ever use sleep mode.

---

## 3. SGLang DSpark runbook

### 3.1 The draft checkpoint changed after our pin — code fix, identical weights

`RadixArk/Qwen3.8-27B-DSpark` HEAD moved from our pin
`923ed3a8572615643f0137e424e4ce4edd7f1cda` to
**`85ef153be924f17ce4bf62726954eeaa4a73e854`** (lastModified 08-16 02:26 UTC).

Per-file tree diff between the two revisions (evidence:
`models/dflash.py-diff-923ed3a-vs-85ef153.txt`):

- `model.safetensors` — **byte-identical** (same LFS oid `9d26d5e6…`, 2,718,576,122 B)
- `README.md`, `config.json`, `dspark.py`, `.gitattributes` — unchanged
- **`dflash.py` — changed (20,347 → 20,651 B).** The draft's reference
  verify-loop had an off-by-one: it now consumes
  `verify_width = block_size + 1` (anchor + all 7 draft rows) and slices
  `draft_logits[:, -block_size:, :]` instead of `[:, -block_size + 1:, :]`,
  with the comment that draft row *j* predicts token `start+j+1`. That is
  precisely our 7-gamma / 8-verify-width geometry.
- The draft `config.json` on both revisions: `architectures:
  ["DSparkDraftModel"]`, `model_type: "qwen3"`, `block_size: 7`,
  `confidence_head_with_markov: true`, `markov_rank: 256`,
  `target_layer_ids: null` (the `[4,16,28,40,52]` aux layers live in the
  checkpoint's `dflash_config`, not the top-level config).
- License is still `license: other` with no license text — the runbook's
  redistribution warning stands.

**Consequence.** The v2 download re-pins `85ef153` into a separate
`/models/Qwen3.8-27B-DSpark-v2` directory (weights re-verified identical by
LFS oid) so the 08-16 profile keeps its exact tree.

### 3.2 The SGLang cookbook was reworked — the runbook's reference link is broken

The 08-14 URL `docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B.html`
**404s**. New URL: `https://docs.sglang.io/cookbook/autoregressive/Qwen/Qwen3.8-27B.md`
(PR #34860 added the page 08-14; #35065 reworked the deployment grid 08-17;
#35121 added DGX Spark configs 08-17; #35064 fixed the mamba ratio
calculator 08-17). Full current copy: `community/sglang-cookbook-Qwen3.8-27B-2026-08-18.md`.

Changes that matter to this profile:

- **Single-GPU positioning** for H200 / **RTX PRO 6000** / RTX 5090 / DGX
  Spark ("one operating point" per card), validated at ISL 8192/OSL 1024,
  concurrency 1 — including every Speculative × Serving-Strategy × SSM-dtype
  combination on the RTX PRO 6000. DGX Spark: all 36 combinations
  boot-and-serve verified on GB10 (aarch64) **on our exact image**
  `lmsysorg/sglang:qwen38-27b`.
- **SM120 guidance for our card family:** `--attention-backend flashinfer`
  (`trtllm_mha` is SM100-only). **MTP with FlashInfer requires a FlashInfer
  build whose prefill `plan` accepts `uniform_q_len` (newer than
  0.6.15.post1); otherwise run spec with `--attention-backend triton`.**
- **MTP is documented as EAGLE `3/1/4`** (`--speculative-algorithm EAGLE
  --speculative-num-steps 3 --speculative-eagle-topk 1
  --speculative-num-draft-tokens 4`, with `--enable-linear-replayssm-spec` on
  sm120 moving verify intermediates to a fixed ring). The runbook's
  `FROZEN_KV_MTP` alternative remains the in-image first-class path; the
  cookbook's is the generic one.
- **DSpark flags:** `--speculative-algorithm DSPARK
  --speculative-draft-model-path RadixArk/Qwen3.8-27B-DSpark
  --speculative-draft-attention-backend flashinfer`. **DSpark does not take
  `--speculative-num-draft-tokens`** — its verify window is
  `--speculative-dspark-block-size` (gamma) **+ 1**, gamma auto-inferred from
  the checkpoint (7 → D = 8). Our launcher already passes block size 7
  explicitly.
- **Mamba sizing (the #35064 fix).** The documented explicit pin is
  `--max-mamba-cache-size = target_concurrency × S` with **S only** (5 for
  `extra_buffer`, 4 for `extra_buffer_lazy`, 3 for `no_buffer`, 1 with the
  radix cache disabled; `SGLANG_OPT_MAMBA_SKIP_DECODE_LOCK=1` frees one
  slot): "the engine divides the state pool by S alone and sizes the
  speculative verify buffer separately, so folding D into the pin would
  over-provision the pool." **Our 08-16 pin of 104 = 8 × (5 + 7 + 1) folds
  D in**; the cookbook's balanced pin at 8 requests is **40**. The v2
  launcher implements the documented formula (with the env override kept);
  the boot-log `max_running_requests` line is the acceptance check.
- **Serving strategies** are now explicit tiers: `--mamba-radix-cache-strategy
  extra_buffer` (low-latency, our default) vs `extra_buffer_lazy`
  (high-throughput, S=4, "no accuracy cost" per the cookbook).
- **NVFP4 of record** for SGLang is now `RadixArk/Qwen3.8-27B-NVFP4`
  (new 08-16; W4A4 + FP8 projections; `kv_cache_quant_algo: FP8` → auto
  `fp8_e4m3` KV). The base cells use FP8 KV even on BF16 weights — a
  capacity choice, different from our reference-fidelity BF16 KV; cross-
  reference only, no change to the quality profile.
- New **agent-harness section** documents Pi provider registration for this
  exact endpoint (`api: "openai-completions"`, `apiKey: "$SGLANG_API_KEY"`
  env reference, `contextWindow: 262144`).

### 3.3 Merged SGLang DSpark work since the pin (all in nightly; no release, no new qwen38-27b image push)

- #34696 + #34478 (08-16/17) — logprobs with DSpark speculative decoding
- #34759 (08-14) — EP1 decode performance regression fix
- #34816 (08-14) — publish the WAR read-done event at DSpark verify
- #34844 (08-15) — MegaMoE for DSpark under dp attention
- #34763 (08-15) — `mamba-radix-cache-strategy extra_buffer_lazy` with DFLASH
- #34771 (08-15) — wire DFLASH aux-hidden capture into the Qwen3.5 text-only wrapper
- #34376 (08-15) — **per-runner linear-attn kernel choice + draft/target loader-hook parity** (directly in our DSpark load path)
- #33676 (08-17) — NPU DeepSeek-V4 DSpark (out of scope)

Roadmap #30344 now decomposes CUDA-graph robustness into tracking issue
**#34297** with layers: #31195 (cross-TP verify budget), #32183 (verifier
compressed-state rewrite), #32467/#32470 (ragged plan producer — fixed),
#33795/#34286 (Full/Breakable graph capture init), #32432 (runtime
contracts/observability). Useful structure for the runbook's "other DSpark
CUDA-graph hardening remains active" sentence.

---

## 4. vLLM DSpark runbook

### 4.1 #52197 (merged 08-17): our config surgery is now upstream

"[Spec] Support DSpark configs with `architectures=DSparkDraftModel` +
`model_type=qwen3`" (diff: `vllm/vllm-pr-52197.json` + `vllm/pr52197-files.json`):

1. `config/speculative.py` auto-detects `method = "dspark"` when the draft has
   `DSparkDraftModel` **and** `hf_config.model_type == "qwen3"`.
2. It then rewrites the draft's `hf_config.architectures` to
   `["Qwen3DSparkModel"]` and re-resolves — exactly the one-field surgery
   `run-qwen38-27b-bf16-dspark-vllm.sh` performs on an isolated copy.

The draft's on-disk config (§3.1) satisfies both conditions, so **the
normalization applies to our exact draft** on any build from 08-17 onward —
including the proposed `nightly-aa99034` pin. The surgery stays in the v2
launcher as a deliberate, image-independent fallback (it is idempotent and
still routes correctly on old images); the runbook's "necessary and
sufficient for routing" sentence becomes history with a date.

### 4.2 Consequences for the v2 profile

- Re-pin the vLLM DSpark image to
  `vllm/vllm-openai:nightly-aa9903490c616dc6871e5acc62cec7bb1e5e9434`
  (AMD64 `sha256:7eb4028507367e69cb0abfa213042d1814c27c1b499af45fbffec8f16d9cbc6f`)
  — brings #52197, #52539, #50729, #50685.
- Mount the v2 draft tree (`/models/Qwen3.8-27B-DSpark-v2`); the vLLM-side
  surgical copy becomes `/models/Qwen3.8-27B-DSpark-vllm-v2` so the 08-16
  profile's copies stay untouched.
- The runbook's claim that "the DSpark path is not blocked at TP≥2" (#52480)
  remains true.
- Startup checks unchanged: second `Resolved architecture:` line must read
  `Qwen3DSparkModel`; aux layers log as `(5, 17, 29, 41, 53)` (+1 offset by
  design).

---

## 5. Pi catalog — `medium` reasoning effort is a silent no-op

The offlabel operating guide (now a FINAL 889-line field guide, tested
08-14, updated ~08-17; evidence `community/TheTom-offlabel-qwen3.8-27b.md`)
verified against the server's own `/apply-template`:

| `reasoning_effort` | rendered prompt |
|---|---|
| (none) | 297 chars — "Reasoning effort is set to xhigh" |
| `low` | 226 chars — "…set to low" |
| `xhigh` | 297 chars — "…set to xhigh" |
| **`medium`** | **60 chars — NO effort line at all** |

The template has no `medium` branch (only `xhigh` and `elif low`). And it is
not inert: field notes (Defilan, issue #24) show the model reasoning
*more* than explicit `low` when no effort line renders (1,633 vs 1,031
reasoning chars on the explain probe at `max_tokens` 1024, temp 0).

**Applied:** `pi/models.json` now maps `medium → null` for `qwen3.8-27b`
(hidden, like off/minimal/high/max), and the release contract's
`thinkingLevelMap` assertion was updated in the same change. The runbook's
"low, medium, xhigh" template-contract line is corrected in the new
runbook.

Other offlabel findings worth keeping (beyond the runbook's existing #24
citation): the MTP draft GGUF (`mtp-Qwen3.8-27B-Q4_0`) exists **only in
`ggml-org/Qwen3.8-27B-GGUF`**, not the unsloth repo; independent GB10
cross-check of the vLLM/SGLang spec paths: 45–53 tok/s on structured
code/math, ~16 on free prose (acceptance *length*, not rate, tracks
throughput); Vulkan speculation is unstable (31% worst-case spread,
non-deterministic at temp 0); "more reasoning is a net cost" on integrity
and code judgment for this model.

---

## 6. Community evidence

### 6.1 fakoli/anvil-serving — a fleet on the identical card and image

Two RTX PRO 6000 Blackwell Max-Q (96 GB, sm120, PCIe, no P2P) on a WSL2/Docker
host. Their public benchmark docs (evidence:
`community/anvil-*` files) pin **our exact SGLang image**
(`lmsysorg/sglang@sha256:506525a5…`, base `c4271c3fe`) for Qwen3.8
qualification. Key receipts, 08-14 → 08-16:

- **08-15: human-approved promotion of official-FP8 SGLang TP1 / 393,216
  tokens with EAGLE MTP 3/1/4** — 111.4 decode tok/s, +131.9% vs the matched
  no-spec control (48.0), 0.577 s median TTFT, 6,261 effective prefill
  tok/s, 18/18 media corpus, 108K needle in 23.9 s, 20/20 tools. Admission:
  one running request, ≤2 images, then +1 video (14/14) after the 08-16
  expansion. **This supersedes the runbook's "(they did not promote it in
  their fleet)"** note about #412; on 08-16 the profile was itself
  superseded as *text* Primary by DeepSeek Infernal Invocation r15 but
  retained as a managed recipe.
- **MTP depth 4/5 gave no meaningful win over 3** — on the production lane
  MTP=3 still leads (93.6 vs 91.6 (MTP=5) / 90.4 (MTP=4) tok/s). Corroborates
  the runbook's depth-3 gate.
- **Their vLLM MTP=3 works at TP1** (93.6 tok/s, official FP8, 4K) —
  consistent with #52480 being TP≥2-specific.
- **TP2 on their box: no P2P, PyNCCL over the socket-backed local path** —
  matches this workstation's topology. 393K/600K/1.01M at TP2 passed through
  985,107 actual prompt tokens; 1M TTFT is 13+ minutes (offline/batch only).
  At 393K, TP2 cut control TTFT 38% (BF16) / 35% (FP8); MTP raised 4K decode
  1.76–2.40× and consumed 7–11% of the KV pool.
- **GPU-IPC multimodal transport fails in their WSL2/Docker combination;
  they force CPU feature transport** for spec + multimodal arms — a gotcha to
  pre-empt on any SGLang vision+spec profile here.
- SGLang 393K needed the explicit longer-context overwrite opt-in. Their
  image-label note matches ours: the label says `c4271c3`, the internal
  build string says `561c8f3`; the digest is the execution identity.
- Bounded agent evidence: agentic scout 16/18 (both failures in the
  debug-loop case), SWE-bench Verified 5/5 (bounded sample, not a full score).
- NVFP4 (Inferact, `6128240e…`) on SGLang: faster prefill/TTFT, −51.1% media
  latency vs BF16, but decode 12.3% slower than official FP8 — "no-promotion
  control" in their fleet.

### 6.2 vLLM recipes ecosystem note

The recipe's quantization table now spans official FP8,
`Inferact/Qwen3.8-27B-NVFP4`, `unsloth/Qwen3.8-27B-NVFP4`, and (SGLang-side)
`RadixArk/Qwen3.8-27B-NVFP4` (new 08-16, 214K downloads). Four third-party
NVFP4 builds of the same checkpoint is a signal the sm120 NVFP4 path is
getting crowd-tested — which also raises the profile of #52540 (SM120 NVFP4
sustained-load wedges).

### 6.3 Hacker News / other

- Release wave 08-14/15 ("Qwen3.8-27B", 298 pts; unsloth GGUF, 67 pts).
- 08-17: "Qwen3.8 27B scores 52 on Artificial Analysis" (364 pts); "Qwen3.8
  27B at 256K: 50 TPS on a 24 GB GPU" (38 pts); RTX 3090 crash-fix write-up.
- 08-18: "Running Qwen3.8-27B on DGX Spark" (matches cookbook #35121).
- discuss.vllm.ai: no Qwen3.8/DSpark topics. local-inference-lab/rtx6kpro:
  no Qwen3.8 runbook added (DeepSeek-only). Reddit: blocked (see Method).

---

## 7. What the new versions implement

Old (08-16, validated) files are **untouched** and remain the working
deployment. New versions, all additive:

| File | What changed vs the 08-16 version |
|---|---|
| `scripts/inference/qwen38/download-qwen38-27b-dspark-v2.sh` | Draft re-pinned `923ed3a` → **`85ef153`** (dflash.py verify-window fix; weights verified identical). Writes to a separate `/models/Qwen3.8-27B-DSpark-v2` tree. |
| `scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-vllm-v2.sh` | Image re-pinned `nightly-ac7509e2` → **`nightly-aa99034`** (AMD64 `7eb40285…`; carries #52197/#52539/#50729/#50685). Container `…-vllm-v2`. Draft surgery retained as an image-independent fallback (redundant upstream since #52197). Mounts the v2 draft tree. |
| `scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang-v2.sh` | `MAX_MAMBA_CACHE_SIZE` now follows the 08-17 cookbook formula: **concurrency × S (S=5, D excluded)** — 40 at the defaults instead of 104 — because the engine sizes the speculative verify buffer separately (folding D in over-provisions the state pool and shrinks KV). Env override kept; boot-log `max_running_requests` is the acceptance check. Container `…-sglang-v2`. Mounts the v2 draft tree. Everything else identical. |
| `tests/qwen38-dspark-v2-contract.sh` | Static contract for the v2 set: new pins, new container names, mamba formula present, surgery still present, **and the 08-16 files still carry the old pins** (old profile intact). |
| `pi/models.json` | `qwen3.8-27b` `thinkingLevelMap.medium` → `null` (silent no-op; see §5). Release contract updated in lockstep. |
| `docs/runbooks/qwen38-27b-runbook-2026-08-18.md` | New-version standalone Qwen3.8 runbook: updated MTP gate status, risk list, both DSpark profiles with v2 pins, corrected mamba sizing, fixed cookbook link, SM120 FlashInfer caveat, refreshed evidence sections, watch-list. |

**Before any v2 is promoted on the desktop**, the runbook's existing
validation gates apply (cold boot, parser/tool/image probes, acceptance
length vs the 08-16 baseline, needle ladder, 8-agent soak). The mamba-pin
change in particular makes the SGLang DSpark gate mandatory on first v2 boot
(check `max_running_requests` in the log).

## 8. Watch-list (open upstream, check before next re-pin)

1. vLLM **#52480** — MTP TP≥2; assigned, root-causing (NVFP4 exclusion hypothesis). The single gate on the vLLM MTP profile.
2. vLLM **#52539** follow-ups — GDN MTP kernel head-ratio support just landed; watch for sm120 reports.
3. vLLM **#52583** (prefix-cache + large multimodal), **#52767** / **#52756** (MTP edges), **#52540** (SM120 NVFP4 sustained load).
4. SGLang **#31195** (cross-TP compact budget — gates any move off static verify) and the **#34297** robustness roadmap layers (#33795, #34286).
5. SGLang release line — v0.5.17 is 10 days old; a new release would be the cleaner re-pin substrate than nightly for the SGLang profiles.
6. vLLM release line — #51812/#51674 are in no release yet; the first release containing them is the clean MTP substrate.
7. `RadixArk/Qwen3.8-27B-DSpark` license — still `other`; do not redistribute.
8. `RadixArk/Qwen3.8-27B-NVFP4` — only 2 days old; its SGLang cookbook status is "recommended", not fleet-validated on this card class.

## 9. Evidence index

```
qwen38-2026-08-18-evidence/
  vllm/      releases, issue 52480 (+comments), 52469 (+root-cause thread),
             52475/52481/52485/50021, PR 52197 (body + file diff),
             merged-PR and new-issue search results
  sglang/    releases, PRs 31195/33795/32467, issue 30344 (roadmap thread),
             merged-DSpark search
  recipes/   Qwen3.8-27B.yaml @ pinned 0025768 vs @ current 62a146b + unified diff
  models/    dflash.py @ 923ed3a and @ 85ef153 + unified diff
  docker/    Docker Hub snapshot 2026-08-18 (tag pushes + per-arch manifest digests)
  community/ TheTom/offlabel qwen3.8-27b.md (final field guide),
             anvil-serving: FP8 promotion finding, model dossier, RTX PRO 6000 page,
             SGLang cookbook (reworked, 08-18 copy)
```
