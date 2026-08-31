# Qwen3.8 Flash-Next v2 state-safety plan

**Status:** planned; not implemented or qualified  
**Target:** Qwen3.8 Flash-Next FP8, TP2, MTP3, vision, 262,144-token context  
**Safety posture:** prefix caching remains disabled until complete output-equivalence qualification passes

## Objective

Build one immutable Qwen-specific serving image that retains the proven QSA exact-top-k repair and ports the applicable accepted-token/recurrent-state safety fixes discovered during GLM-5.3 qualification. Do not copy GLM-specific adapters into Qwen blindly: every source path, input hash, runtime call path, and output hash must be established against Qwen's exact base image.

## 2026-08-31 top-k research update

The observed local QSA nondeterminism is already repaired by the v1 mode-3 `torch.topk` overlay,
but upstream vLLM still routes merged Qwen support through affected `persistent_topk` paths.
Issue #51782 and PR #52149 remain open; Qwen support PR #53896 has merged, while the PLE-offload
PRs required by this workstation are not ready. A strict dry run proved that the GLM v9 exact
persistent-top-k patch applies without fuzz to the exact Qwen merge commit's two kernel headers.
The source algorithm and verifier matrix are reusable; the GLM extension binary is not.

See [`qwen38-flash-next-topk-upstream-research-2026-08-31.md`](qwen38-flash-next-topk-upstream-research-2026-08-31.md)
for upstream evidence, portability results, and the recommended Qwen-owned rebuild.

## Current immutable baseline

| Item | Identity / setting |
|---|---|
| Base image | `vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3` |
| Current derived image | `sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32` |
| Current QSA patch | `sha256:b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4` |
| QSA mode | `VLLM_QSA_EXACT_TOPK=3` |
| MTP | enabled, three draft tokens |
| Vision | enabled, one image per prompt |
| Prefix caching | disabled after cache-history-dependent output drift |
| Rollback | current derived image above |

## Applicability decisions

### Keep: QSA exact top-k for vLLM #51782

Qwen already bypasses the defective `torch.ops._C.persistent_topk` operator in its QSA selector. Preserve this repair. Re-evaluate mode 3's tie behavior: canonical ordering after `torch.topk` does not determine which equal-valued boundary candidate enters the selected set. Compare the existing implementation with a unique score/index key or stable full-sort reference, then retain the lowest-cost implementation that is exact and repeatable on real QSA logits.

### Port: PR #50021 accepted-token bounds

Port the fail-closed accepted-count checks from `vllm-project/vllm#50021@9a198c0f8452d0eb251509f02753853903d9f17f` wherever Qwen's exact runtime contains the equivalent MTP state lookup:

- causal-convolution state selection;
- Mamba/GDN recurrent-state selection;
- Flash Linear Attention recurrent and sigmoid-gating kernels used by Qwen;
- worker-side Mamba state management.

The invariant is: an accepted-token-derived index must be proven inside the allocated state dimension before any GPU gather, index selection, or pointer arithmetic. Invalid metadata must raise synchronously rather than becoming a device address.

### Conditional port: CPU-proven mixed-token partition

Inspect Qwen's V2 `gdn_attn.py` call path. If it builds speculative/non-speculative token partitions with asynchronously reused GPU metadata, replace that partition with the same authoritative CPU construction used by the GLM repair. Prove all of the following before H2D transfer:

1. every token index is in `[0, num_actual_tokens)`;
2. spec and non-spec sets are disjoint;
3. their union covers every actual token exactly once;
4. their sizes equal scheduler metadata;
5. zero-length and mixed-length requests remain valid.

If Qwen does not execute that path, do not add a dormant patch.

### Do not port: GLM sparse-indexer/KPool adapter

GLM's three `sparse_attn_indexer*.py` call sites are not Qwen's QSA interface. Qwen needs a QSA-specific exact selector, not the GLM KPool patch.

## Image construction

Build directly from the exact 32-layer Qwen base rather than chaining mutable local images. The Dockerfile must:

1. hash-check every unmodified source input;
2. hash-check each vendored patch;
3. apply with `patch --batch --fuzz=0`;
4. hash-check every patched output;
5. compile all changed Python modules;
6. retain the complete base rootfs layer prefix;
7. label the upstream PR/issue identities and patch digests;
8. produce one digest-pinned derived image and private identity receipt.

The launcher, pull/proof script, contract, and runbook must update all image pins atomically. Startup remains transactional: `restart=no` until authenticated readiness and all required receipts pass.

## Verification strategy

### Static and CPU gates

- Existing Qwen checkpoint/manifest verification.
- Exact base and derived rootfs-prefix proof.
- Source and patch SHA-256 checks.
- Python compilation of every modified source.
- Pure mixed-partition tests over zero, short, heterogeneous, and maximum accepted-count layouts.
- Contract rejection of prefix caching and any unpatched QSA `persistent_topk` call.

### GPU kernel gates

- Upstream #51782 crowded-bin reproducer.
- Equal-score boundary cases with deterministic lower-index tie-breaking.
- Invalid accepted-count tests for every patched recurrent/gating kernel.
- Valid minimum/maximum accepted-count controls.
- No CUDA error, illegal access, `indexSelectSmallIndex`, or new kernel Xid.

### Live qualification with prefix caching disabled

Warm serially before admitting concurrency. Require:

1. authenticated model and exact image identity;
2. MTP draft/accept counters increasing;
3. deterministic short and long cache-isolated temperature-zero outputs;
4. text, reasoning, tool-call, and image correctness;
5. changed-image isolation;
6. concurrent mixed decode/prefill with heterogeneous accepted counts;
7. maximum-context and memory-capacity receipt;
8. restart replay and sustained soak;
9. no recurrent-state bounds failure, CUDA error, or Xid.

### Separate prefix-cache research gate

Prefix caching is a separate experimental profile and remains off in the deployable profile. It may be reconsidered only after cold, exact-warm, partial-warm, changed-image, concurrent shared-prefix, long-context, tool-call, restart, and soak cases produce complete output equivalence—not merely cache-hit counters.

## Rollout and rollback

1. Reboot after any GPU Xid before loading the candidate image.
2. Build and prove the candidate while the serving profile is stopped.
3. Launch with `restart=no` and warm serially.
4. Run all static, GPU, live, and concurrency gates.
5. Promote restart policy only if every mandatory gate passes.
6. On any failure, stop the candidate and restore `sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32` with prefix caching disabled.

## Completion criteria

The plan is complete only when the candidate is immutable and reproducible, all recurrent-state indices fail closed, QSA selection is exact and deterministic, MTP3 and vision are active, prefix caching remains correctly gated, the full live matrix passes without new Xids, and rollback has been exercised.
