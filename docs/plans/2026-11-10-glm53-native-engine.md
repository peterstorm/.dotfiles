# Plan: a native engine for GLM-5.3 (744B) — feasibility and phases (2026-11-10)

**Ask:** a native engine for **zai-org/GLM-5.3** at full quant, built the way `~/dev/ds4-native` was built for
DeepSeek-V4.1-Flash-1017 (released precision, experts streamed from NVMe into a VRAM Expert cache, 2-way tensor
parallelism on the desktop's two RTX PRO 6000s), drawing on everything that inspired ds4-native, plus Project Maya's
new GLM-5.3 port (mw00/project-maya `0065548`, v1.1.57, 2026-11-09).

Everything marked **est.** is derived, not measured. Phase 0 exists to replace it. The desktop was unreachable while
this was written (`No route to host`), so its disk headroom is unmeasured.

## Verdict

| Question | Answer |
|---|---|
| Can the engine be built? | **Yes, with high confidence.** About half of ds4-native carries over as is: the Expert store, io_uring Misses, Ledger, Expert cache + victim RAM tier, Exchange, Rounds, prompt sweeps, sampler/Reply, adaptive DSpark verification, KV checkpoints, `ds4n-serve` behind Maya's server, the metrics bridge. GLM-5.3 also drops three of DS4's hardest parts: mHC, Engram, and the compressor rings with their Rewind points. |
| Can **FP8 (the released "full" precision)** be *served* on this box? | **No.** The FP8 experts are 725 GB, and only about 20 % fit in VRAM. Estimated **3–5 tok/s** decode and **~40 s per tool turn**. The store also cannot fit on the 2 TB NVMe beside the DS4 artifacts. FP8 is useful only as the offline quality reference. |
| What is the closest *servable* "full quant"? | **RedHatAI/GLM-5.3-MXFP4xFP8** (`a5cf193`). It uses MXFP4 g32/E8M0 routed experts with FP8 dynamic activations, plus FP8 128×128 attention, shared experts and NextN; embedding, head and router stay BF16. On RedHat's reproduction it matches FP8 on agentic evals: DeepSWE 1.1 67.3 vs 66.9, Terminal-Bench 2.1 88.8 vs 88.2. This is **the same structure as DS4.1's release**, so ds4-native's MXFP4 kernels and Miss costs transfer directly. |
| How fast would that be here? | **est. 11–19 tok/s** exact. **est. 25–40 tok/s** with cache-conditional routing (CCR) and DSpark. A short tool-turn Append would take about **10–16 s to first token**. For comparison, ds4-native does 77–135 tok/s. llama.cpp runs GLM-5.3 UD-IQ2_M on 2× RTX PRO 6000 at 11–12 tok/s and 83 tok/s prefill. |
| Is that useful? | **Marginal as the tool-loop workhorse. Plausible as a deep planner/reviewer** (long thinking, few short Appends). That gives roughly the quality of the full model at about 1.5–3× the llama.cpp 2-bit speed. Whether it clears the bar depends on one measurement no one has: **GLM-5.3's Expert cache hit rate on our traffic** (Phase 0). |
| What would flip it to "comfortable"? | RAM 96 → 192 GB raises VRAM+RAM residency from about 50 % to about 73 %, the same regime as ds4-native. A second CPU-attached Gen5 NVMe would double Miss bandwidth, if the board has the lanes. Both need hardware checks. |

## GLM-5.3 against DS4.1-Flash (what changes for the engine)

From `config.json` at `zai-org/GLM-5.3@ba32f8c` (`GlmMoeDsaForCausalLM`, `glm_moe_dsa`):

| | DS4.1-Flash-1017 (ds4-native) | GLM-5.3 744B-A40B |
|---|---|---|
| Layers | 40 | 78, plus 1 NextN (layers 0–2 dense, 3–77 MoE) |
| Hidden | 5,120 | 6,144 |
| Routed experts | 384, top-6 (240 picks/token) | 256, top-8, 1 shared (**600 picks/token**). Router is sigmoid + `e_score_correction_bias` (noaux_tc), normalised, ×2.5 |
| Expert | 2304×5120 ×3, MXFP4 = **18.8 MB** | 2048×6144 ×3. FP8 = **37.76 MB**, MXFP4 = **20.05 MB** |
| Attention | CSA2 + compressor rings + indexer, mHC ×4 | **MLA**: q_lora 2048, kv_lora 512, nope 192 + rope 64 (interleaved, θ 8e6), v 256, 64 heads, scale 1/16. **DSA lightning indexer**: 32 heads × 128, LayerNorm k_norm with bias, top-2048. Indexer layers: "full" ones are 0, 1, 2, 6, 10, … (every 4th); the others reuse the previous full layer's top-k (Z.ai's *IndexShare*, arXiv 2603.12201). Plain residual. |
| Extras | Engram (203 GB on disk), DSpark | none; NextN MTP layer, **RedHatAI DSpark speculator** |
| Backbone (non-routed) | 9.85 GB | **~21 GB** (attention alone is 12.87 GB FP8) |
| Decode bytes/token, all resident | 13.0 GB | **~30 GB** in MXFP4xFP8, ~40 GB in FP8 |
| KV per position | ~0.9 KB | **~54 KB**: FP8 latent 656 B × 78 + indexer 132 B × 21. That is 14 GB at 256K. |
| Released precision | MXFP4 experts + FP8 dense | **FP8 everywhere** (128×128 block scales), 755.7 GB |

Simpler than DS4: no mHC, no Engram, no compressor, no Decoder tail, no window rings. The MLA latent and indexer keys
are written once per position, so a **Resume is Exact at any shared prefix** and Rewind points become unnecessary.

Harder than DS4:
- Twice the layers.
- 2.5× the picks per token.
- A backbone twice as big, so the Base step is about 2×.
- An O(context) indexer scan on 21 layers per token.
- KV 60× bigger, which makes context compete directly with Slots and makes KV checkpoints expensive.

## Byte budget and residency (per format, est.)

Per GPU (102.6 GB):
- Backbone share about 9.4 GB: attention, shared and dense split by heads/Halves; router replicated; head split by vocabulary; embedding gathered from host.
- DSpark drafter about 1.3 GB (2.5 GB BF16, split).
- KV replicated: 14.2 GB at 256K, 7.1 GB at 128K. The latent is shared by all heads, so head-split TP replicates it.
- CUDA context, scratch and the prefill shelf about 6 GB.

That leaves **~143 GB of Halves at 256K (~157 GB at 128K)**. The RAM tier is assumed to be 48 GB, keeping 24 GB of the 96 GB for KV checkpoints, because a single parked 256K session is 14 GB.

| Store | Expert | Routed store | Slots @256K (share) | +RAM tier | VRAM+RAM | Bytes outside VRAM+RAM (a short Append reads ~all) |
|---|---|---|---|---|---|---|
| FP8 (released) | 37.76 MB | 725 GB | 3,790 (19.7 %) | 1,270 (6.6 %) | 26 % | 534 GB → **~41 s** at 13 GB/s |
| **MXFP4xFP8** (RedHat) | 20.05 MB | 385 GB | 7,130 (37.1 %) | 2,390 (12.4 %) | 50 % | 194 GB → **~15 s** |
| EXL3 3.0 bpw (community) | ~14.2 MB | ~272 GB | 10,070 (52.4 %) | 3,380 (17.6 %) | 70 % | 82 GB → **~6 s** |
| *ds4-native today, for scale* | 18.8 MB | 289 GB | 8,400 (54.7 %) | 3,000 (19.5 %) | 74 % | — |

**Why short Appends are the wall.** A 300-token Append routes 2,400 picks per layer over 256 experts. The expected
untouched share is (1−8/256)^300 ≈ 0.01 %, so every tool result reads almost the whole non-resident set. That is
ds4-native's "structural weakness" (feasibility Risk 1), made 3–10× worse.

There is also a hard floor on this box for exact output. Even with every non-VRAM expert in RAM, the two PCIe x8
links (~57 GB/s together) put an MXFP4 short Append at about **4 s** or more.

## Decode estimate (est.; the hit rates are a proxy until Phase 0)

**The proxy.**
- **No GLM-5.3 routing statistics exist.** Maya's `data/expert-profile-glm53.bin` is a *ranking*: `make_profile.py` writes `table[layer][e] = slot`. It holds no pick counts, so it cannot give hit rates.
- The rows below use ds4-native's measured DS4 curve, with dynamic locality cutting static Misses 2–3×. That curve is 66.7 % static at 24 % residency, 91.3 % at 56 %.
- GLM picks 3.1 % of each layer's experts per token, against DS4's 1.56 %. Its curve may well be flatter, so treat these rows as optimistic.

**The step model.** `step ≈ t_base + n_ssd·c_ssd + n_ram·c_ram`:
- `t_base` ≈ 12–14 ms in MXFP4xFP8: about 15 GB per GPU per token, plus about 157 Exchanges.
- `c_ssd` ≈ 1.5–1.8 ms per 20 MB Expert (ds4-native measured 1.64 ms p50 for 18.8 MB).
- `c_ram` ≈ 0.35 ms.

| Store | VRAM hit (proxy) | Misses/token | Exact routing | + CCR + DSpark | All-resident ceiling |
|---|---|---|---|---|---|
| FP8 | 80–87 % | 78–120 | **3–5 tok/s** | 6–12 | ~55 |
| **MXFP4xFP8** | 89–93 % | 42–66 | **11–19 tok/s** | **25–40** | ~70–80 |
| EXL3 3.0 bpw | 95–97 % | 18–30 | 32–43 tok/s | 50–75 | ~85 |

DSpark pays less here than on DS4 while Misses dominate. A verify Round loads the union of its rows' experts:
about 2.8× the Misses at width 4. ds4-native's adaptive verification already prices that per Round, so it backs off
on its own. The RedHat speculator accepts long drafts (HumanEval 4.76, tool_call 4.01, block 8), so it starts paying
as the hit rate rises.

Reference points measured elsewhere:
- llama.cpp UD-IQ2_M on 2× RTX PRO 6000 Max-Q with 128 GB RAM: 11.3–12 tok/s, 83 tok/s prefill, TTFT 394 s at 32K (XDA, 2026-10-12).
- antirez/ds4 IQ2_XXS on an M5 Max: 4.1–5.1 tok/s.
- Maya publishes no GLM-5.3 speeds.

## Where the inspiration comes from (ds4-native's sources, mapped to GLM-5.3)

| ds4-native drew on | GLM-5.3 counterpart | Role here |
|---|---|---|
| **antirez/ds4 (DwarfStar)**: baseline + Oracle | **antirez/ds4 `b3f50180`** (2026-11-03, MIT) runs **full GLM 5.2/5.3 with SSD streaming**, has an `sm_120a` target, built-in GLM MTP (commits ≤2 tokens) and a GLM 5.2 expert hotlist. Weights are `antirez/glm-5.3-gguf` (IQ2_XXS experts, 211 GB). CUDA multi-GPU is layer placement only (no TP), with no published CUDA numbers. | Phase 0 baseline and routing-trace source; second Oracle (quantized) |
| **Project Maya**: server, oracle `ref.py`, kernels, profile | **Maya v1.1.57 glm-dsa** (MIT). Worth taking: the `ref/glm_dsa.py` f64 oracle (`--mode hf`/`llama`, 7 named mutations, `--layers A:B` slice mode), the synthetic GGUF generator and fixtures, the deterministic radix top-k (`glmd_topk.cuh`), RoPE numerics (`glmd_rope.cuh`), the router (`glmd_route.hpp`), fail-closed geometry checks, the KV layout arithmetic, the SSD prompt-cache design, Z.ai's template byte for byte, 50 tool-call fixtures, and the fake engine + engine-contract tests. `serve/server.py` already serves GLM-5.3: template, tools, thinking budget 32K/64K. | Frontend (unmodified, as for DS4); oracle and fixtures; borrow with notices |
| Maya as a design *not* to copy | The 2-GPU split is a **layer pipeline** whose boundaries must fall on full-indexer layers. Kernels are dp4a/WMMA tuned for **Volta** (no FP8 or block-scaled MMA). Routing goes through a host ring with a device spin-wait. The RAM tier requires the CPU lane. KV is VRAM-only, MTP draft depth is 1, and everything is spliced into 8.6k-line Flash classes. **Long-context quality FAILS at 32K: +1.38 nats** (`tools/strata/glm53_long_gate.py`, 2026-11-07), cause unresolved (selection bug or 2-bit). Every result is on 2-bit UD-IQ2_M; there is no FP8 check against HF. | The same list of reasons we did not patch Maya for DS4 |
| DS4 recipe (tangled.org/astrra.space/ds4-recipe) | No GLM material (latest commit 9ae354c, 2026-10-10). | Doctrine transfers whole: exactness gates, ABBA bench rules, popularity+victim cache, Cohorts, CCR, checkpoint policy |
| DeepSeek's reference `inference/` | **DeepSeek-V3.2-Exp `inference/model.py`** (MIT): MLA plus the same lightning indexer (LayerNorm k_norm with bias, Hadamard, FP8 keys). GLM's differences: 32 indexer heads, interleaved RoPE, the full/shared schedule, nope 192 / v 256. Cross-check against HF transformers `glm_moe_dsa` and llama.cpp `glm-dsa` (#25407 indexer, #24231 `LIGHTNING_INDEXER` op, #26474 full-layer-only indexer cache). | Oracle: the base of our CPU reference forward |
| FlashMLA | FlashMLA main is sm_100 only (sm_120 PRs #146/#189 were closed). Instead: **FlashInfer sm_120 sparse MLA** (#3395, Apache-2.0), **vLLM #43477** `flashinfer_mla_sparse_sm120` (tested on an RTX PRO 6000), **SGLang #26928** (656 B/token FP8 latent layout + 132 B indexer, a Triton sm_120 fallback), **DeepGEMM `nv_dev` #324** `sm120_fp8_mqa_logits` (MIT, not on main), TileLang `examples/deepseek_v32`. | Kernel inspiration for sparse MLA and indexer scoring on sm_120a |
| DeepSeek's own DSpark drafter | **RedHatAI/GLM-5.3-speculator.dspark** (`b374b95`): 2.5 GB BF16, 3-layer Qwen3-style drafter, reads aux hidden states from layers 2/20/39/58/75, block 8, Markov head (rank 256) + **confidence head**. Acceptance length 4.76 HumanEval, 6.13 math, 3.18 qa, 4.29 at 524K–1M. The model's NextN layer is the fallback (9.7 GB of FP8 experts we would rather not hold). | Draft source; feeds ds4-native's adaptive verification, which already consumes per-position confidences |
| MoCCE (cache-conditional routing) | Plus arXiv 2609.04895 (cache-aware router adaptation), 2608.07911 (reproducible expert-caching eval: LRU picks the optimal victim only 21 % of the time), 2601.17063 (FlashMoE SSD offload). None evaluates 256-expert top-8. | CCR behind a flag (owner decision); replay against Belady |
| Peer engine report (~150 tok/s DS4) | No GLM-5.3 2-GPU equivalent found. The rtx6kpro wiki has GLM-5.x NVFP4 resident on TP4–TP8 only; ktransformers needs host RAM larger than the expert set (does not fit 96 GB). | — |
| exllamav3 | `architecture/glm_moe_dsa.py` (+ TP, + MTP), MIT. Community EXL3 GLM-5.3: 0xSero 3.0 bpw (292 GB) / 4.0 (405 GB), davidsyoung 3.42 (355 GB). No turboderp GLM-5.3. | Only if the 3-bpw store is chosen (Decision D1) |

Other 4-bit checkpoints, if MXFP4xFP8 disappoints:
- `nvidia/GLM-5.3-NVFP4` (`e3b8f9f`, ModelOpt, MoE linears only, attention BF16).
- `RedHatAI/GLM-5.3-MXFP4` (W4A4 everywhere).
- `intel-ai/…-MXFP4-AutoRound`.
- `amd/…-Quark-MXFP4-AttnFP8`.

NVFP4 (g16 FP8 scales) would need its own GEMV, unlike MXFP4.

## What carries over from ds4-native, and what is new

| ds4-native part | For GLM-5.3 |
|---|---|
| Expert store, io_uring O_DIRECT Miss pipeline, pinned shelf, H2D per GPU | **Reuse.** Make the record geometry a parameter (20,054,016 B; gate\|up\|down with each GPU's Half contiguous) |
| Ledger, Expert cache, victim RAM tier, Near-miss uses, Access record + `cache_replay` (Belady) | **Reuse**, generalised to 75 layers × 256 × top-8. The Ledger gains a KV term that is no longer negligible |
| `mx_gemv` native block-scaled MXFP4 MMA (1,525 GB/s), act_quant semantics | **Reuse.** Same format and the same FP8 group-128 activations. Retile for K=6144 and N=2048 |
| FP8 Backbone GEMV (E4M3 + 32×32 E8M0 tiles) | **Adapt:** 128×128 blocks with FP32 scales |
| Exchange (P2P TP sum), SweepLink | **Reuse.** About 157 per token (attention + MoE × 78, head) |
| Rounds, prompt sweep, Cohort, Wave, Grouped MoE | **Reuse.** No Decoder tail (it was DS4-specific) |
| CSA2 attention, compressor, indexer, mHC, Engram | **Drop.** Replace with MLA (absorbed, 576-wide latent, 32 heads per GPU) and the DSA lightning indexer (replicated on both GPUs: deterministic top-k, so no Exchange) |
| DSpark (DeepSeek's 3-block drafter) + adaptive verification | **Keep verification.** New drafter forward for RedHat's DSpark (block 8, Markov head, confidence head) |
| Sampler, Draw index, Reply, thinking budget | **Reuse** |
| KV checkpoint, Resume, Split, Rewind points | **Simplify:** append-only caches make Resume Exact at any prefix with no Rewind points. **Re-budget:** 54 KB/position; spill to NVMe (Maya's SSD prompt-cache design) |
| `ds4n-serve` protocol behind Maya's `server.py` | **Reuse.** The server keys GLM-5.3 off a `# glm-dsa:` header in `<tokenizer>/../index.txt` or a `--glm-pack` arg, so the profile provides one |
| Metrics bridge, dotfiles run/switch scripts, pi profile | **Reuse.** New model label |

## Phases (each ends in a gate; nothing after a failed gate starts)

**Phase 0: measure before building.** No engine code. About 2–3 sessions plus GPU windows.
1. **Disk audit on the desktop.**
   - The MXFP4xFP8 download is about 415 GB, and the converted store plus Backbone is about 410 GB. Convert shard by shard and delete each source shard, so the peak stays near 450 GB.
   - Decide which DS4 artifacts can go. For example, the 501.6 GB merged GGUF may only be needed for Engram rows.
   - Record the budget in a dataset in `machines/desktop/disks.nix`. Never `cp` on that pool (block cloning keeps the source recordsize).
2. **Baselines.**
   - Build antirez/ds4 `b3f50180` (`make cuda CUDA_ARCH=sm_120a`) with `antirez/glm-5.3-gguf` (211 GB).
   - Optionally also Maya v1.1.57 with UD-IQ2_M (238.6 GB). It needs its own disk room, so run it in sequence.
   - Measure decode, prefill and short-Append TTFT on the ds4-native bench corpus.
3. **Routing trace on our traffic.**
   - Dump routed experts per layer and position from the baseline over replayed Pi/Loom sessions: parent + subagent turns, tool results, 30K–260K contexts.
   - A quantized model's router choices approximate FP8's. Measure that agreement in Phase 2.
   - Replay with `ds4n-cache-study`, generalised: static curve, popularity+victim policy, Belady bound, Misses per token and per Append at each store's Slot count.
4. **Gate G0.** Project decode and short-Append TTFT from the measured curve.
   - Proceed with MXFP4xFP8 if projected exact decode is at least **15 tok/s** and a 1K Append's TTFT is at most **12 s**.
   - Otherwise stop, or take a hardware lever (RAM to 192 GB, a second NVMe) or the 3-bpw store.
   - Owner sets the final thresholds.

**Phase 1: a shared engine core (deepen).** Split ds4-native into a model-agnostic **Engine** and model modules:
- **The Engine:** store/I/O, Ledger, Expert cache, Exchange, Rounds and sweeps, Sessions and checkpoints, sampler/Reply, verification policy, serve loop.
- **The Model seam:** geometry, Backbone layout, per-layer forward for a Round, Routing plan, KV layout, drafter.
- **Gate:** DS4 stays **byte-identical** on every existing Reference-configuration gate (inertness).

This avoids forking about 80 commits of residency and serving work (Decision D2).

**Phase 2: GLM Oracle and correctness harness (CPU first).**
- **Reference forward:** a CPU/f64 forward from HF safetensors, ported from DeepSeek-V3.2-Exp `inference/model.py` with GLM's differences.
- **Cross-checks:** against Maya's `ref/glm_dsa.py` on its synthetic fixtures, against llama.cpp, and against transformers on a small random GLM geometry.
- **Real weights:** a layer-slice mode streams one layer at a time.
- **Mutations:** Maya's 7 plus ours (interleave off, shared-layer reuse off, eps 0, bias on selection weights, Hadamard on/off, top-k tie order).
- **Reference-defining choices, decided and frozen:**
  - Latent KV precision (BF16 vs SGLang's FP8 656 B).
  - Indexer key precision and Hadamard.
  - LayerNorm eps 1e-6 (HF).
  - Top-k tie order: low position wins (Maya).
- **Gate:** every mutation breaks parity. Quantized-vs-oracle anchoring is reported as KL, never claimed bit-exact.

**Phase 3: store conversion.**
- MXFP4xFP8 safetensors become the Expert store (19,200 records, plus 256 NextN records only if MTP is kept) and the Backbone (FP8 128×128 + BF16), converted shard by shard.
- Logical identity is checked against the source; record identity is checked on a re-read.
- Measure the Miss cost on the real store: the target is ≤ 1.8 ms p50.

**Phase 4: sm_120a kernels**, each with primitive gates (odd shapes, extreme scales, mutants fail, fold order pinned):
- MXFP4 expert GEMV/GEMM: retile `mx_gemv`.
- FP8 128×128 block-scaled GEMV/GEMM.
- Absorbed MLA decode over the selected 2,048 positions, with a fixed merge order.
- Lightning-indexer scoring (FP8 MMA).
- Deterministic radix top-2048.
- Interleaved RoPE with precise `sincosf`.
- Sigmoid + bias top-8 router.

**Phase 5: forward pass on two GPUs.**
- **Parallel layout:**
  - TP2 with 32 heads per GPU.
  - Latent KV replicated (context-parallel KV is Decision D3b).
  - Indexer replicated.
  - Experts in Halves.
  - Head split by vocabulary.
- **Device-resident step:** CUDA graphs, routing on the GPU.
- **Gate G5:** Exact against the Reference configuration, Slot-count invariance at λ = 0, and anchoring KL against the Oracle on real text.
- **Measure:** `t_base`, real Misses per token, real Miss exposure. **Re-run the G0 projection with measured numbers.** This is the second kill point.

**Phase 6: prefill.**
- Prompt sweeps with Cohorts and Grouped MoE, resident Experts first.
- Indexer prefill scoring with FP8 MMA (O(n²), about seconds at 128K).
- Sparse MLA prefill.
- **Gate:** long fresh prompt ≥ 3K tok/s; short-Append TTFT measured against G0.

**Phase 7: speculation.**
- RedHat DSpark drafter forward, fed by aux hidden states from layers 2/20/39/58/75, into ds4-native's adaptive Verify width.
- **Gate:** verify ≡ decode, byte-exact; acceptance and speed measured on the code and agent corpus.

**Phase 8: serving.**
- `glm-native-serve` behind Maya's `server.py`: template, tool calls, `reasoning_content`, thinking budget.
- KV checkpoints with an NVMe spill and longest-prefix Resume.
- **Gate:** `serve-check` (an agent tool loop, a chat's next turn and a subagent resume all Exact) plus a long needle test at the chosen context.

**Phase 9: residency tuning and approximations.**
- Replay-tuned policy and RAM-tier size.
- **CCR behind a flag** (Decision D4), with KL reported per context bucket.
- **Gate:** the bench rules (ABBA, ≥12 pairs, CI lower bound > 0).

**Phase 10: cutover and role.** Run the Loom model A/B (`loom-model-ab`) against ds4-native and GLM-5.3-Flash v15, then decide where it routes in `pi/model-routing.json`: planner/reviewer or workhorse (Decision D5). Add a runbook, a dotfiles profile and a metrics label.

Pace for scale: ds4-native went from seed research to serving in about two weeks (81 commits). With Phase 1's reuse,
glm-native's new surface is mainly Phases 2, 4, 5 and 7.

## Decisions for the owner

| # | Decision | Recommendation |
|---|---|---|
| D1 | Served store | **MXFP4xFP8.** It is "full quant" in practice (matches FP8 on DeepSWE/Terminal-Bench), has DS4's structure, and reuses the MXFP4 kernels. Keep FP8 as the offline reference (layer-slice KL). EXL3 3.0 bpw only if G0 fails and speed beats quality. |
| D2 | Repo shape | **Shared Engine core in ds4-native** with DS4 and GLM model modules. The alternative, a fork, would double every residency and serving fix. |
| D3 | Context target | **128K first.** Each extra 128K costs about 700 Slots (~3.7 points of residency). 256K once G5 numbers are in. |
| D3b | KV under TP | Replicated latent first (simple, Exact). Context-parallel KV (as the vLLM DCP2 profiles) only if context must grow. |
| D4 | Cache-conditional routing | Off by default, flag on. It is the main short-Append lever, and it changes outputs. |
| D5 | Role | Decide after Phase 10. Expectation: planner/reviewer, not the tool-loop workhorse. |
| D6 | Phase 0 baseline runner | **antirez/ds4** (211 GB, sm_120a, same role it had for DS4). Maya v1.1.57 second if disk allows. |
| D7 | Hardware | Check whether the board takes 4 DIMMs (192 GB) at a usable speed and has a free CPU-attached Gen5 x4 M.2. Either moves MXFP4xFP8 toward ds4-native's regime. |

## Risks

1. **Short-Append TTFT** (est. 10–16 s; physics floor about 4 s on this box). This decides the model's role.
2. **The hit rate is unknown.** No GLM-5.3 routing counts exist anywhere (Maya's profile is a ranking). The DS4 proxy may be optimistic, because GLM picks twice the share of each layer.
3. **Base step about 2× DS4** (78 layers, 12.9 GB of FP8 attention). Even fully resident, the ceiling is about 70–80 tok/s.
4. **KV is 60× DS4's per position.** Context, Slots and checkpoints all compete for VRAM and RAM.
5. **DSA exactness and quality.** Indexer precision and tie order are reference-defining, and Maya's 32K long-context failure shows how subtle selection is. Our FP8-anchored Oracle should settle whether that failure is a bug or 2-bit noise.
6. **Disk.** About 450 GB peak for conversion beside the DS4 artifacts on one 2 TB drive. Unmeasured: the desktop was unreachable.
7. **Production conflict.** One GPU-owning process at a time, so every GLM GPU window is downtime for ds4-native serving (as during DS4's build).
8. **License:** the "GLM-5.3 License" is MIT-like, with a security-review clause for MaaS operators above $10B revenue. Fine here.

## Sources (pinned)

- `zai-org/GLM-5.3@ba32f8c` (config, 755.7 GB FP8)
- `RedHatAI/GLM-5.3-MXFP4xFP8@a5cf193`
- `RedHatAI/GLM-5.3-speculator.dspark@b374b95`
- `nvidia/GLM-5.3-NVFP4@e3b8f9f`
- `unsloth/GLM-5.3-GGUF` (UD-IQ2_M 238.6 GB … Q8_0 801 GB)
- mw00/project-maya `0065548` (v1.1.57: `docs/GLM53.md`, `ref/glm_dsa.py`, `data/glm-dsa/`, `tools/strata/glm53_long_gate.py`)
- antirez/ds4 `b3f50180`
- llama.cpp #19460, #25407, #24231, #26474, #25980
- vLLM #43477; SGLang #26928; FlashInfer #3395; DeepGEMM #324 (`nv_dev`)
- DeepSeek-V3.2-Exp `inference/model.py`
- arXiv 2603.12201 (IndexCache), 2602.15763 (GLM-5 report), 2609.04895, 2608.07911, 2601.17063
- XDA 2026-10-12 (llama.cpp GLM-5.3 on 2× RTX PRO 6000 Max-Q)
- ds4-native: `README.md`, `CONTEXT.md`, `docs/research/2026-10-26-feasibility.md`, `docs/research/recipe-translation.md`, `docs/research/reference-engines.md`
