# Qwen3.8 Flash-Next top-k upstream and GLM-port research

- **Date:** 2026-08-31
- **Scope:** QSA sparse-selection determinism/correctness only; recurrent-state and prefix-cache safety remain separate gates.
- **Conclusion:** the observed top-k nondeterminism is repaired in the local Qwen v1 overlay, but it is not fixed in upstream vLLM. The GLM source-level persistent-top-k repair is applicable to Qwen's merged source, but the GLM binary is not portable and the current Qwen base remains source-unreconstructible.

## Executive result

1. **Local Qwen v1:** fixed for the observed failure. The deployed derived image bypasses `persistent_topk` with `torch.topk` mode 3, masks out-of-range columns, and canonicalizes the selected ordering. With prefix caching disabled, two independent 10-run first-token/top-20 gates and three complete 1,706-token responses were byte-identical.
2. **Upstream vLLM:** not fixed. Issue `vllm-project/vllm#51782` remains open. PR `#52149` remains open and currently has a failing pre-commit check. PR `#53287` is draft and does not establish deterministic tie membership for QSA.
3. **Merged Qwen support:** PR `#53896` merged as `e126687a9a828d513c01a07cd69f025f27d63280`, but its QSA path still dispatches to `torch.ops._C.persistent_topk` for Blackwell family 12.x and for prefill chunks above 32 rows. Stock merged Qwen support is therefore still exposed.
4. **GLM reuse:** the v9 exact-overflow/deterministic-tie patch applies with `patch --fuzz=0 --dry-run` to both top-k headers at the exact merged Qwen commit. This proves close source compatibility, not compilation or runtime qualification.
5. **Do not copy the GLM extension binary:** Qwen uses PyTorch `2.13.0+cu130` and stable-extension SHA-256 `01baa4f…`; GLM v10 uses PyTorch `2.13.0`, CUDA 13.3, and extension SHA-256 `b144bf4…`. Replacing the Qwen `.so` would be an unqualified whole-extension ABI transplant.
6. **Next image:** rebuild from reconstructible Qwen source with the required PLE-offload changes, compile the exact persistent-top-k repair into that source, canonicalize QSA output order, and reuse the GLM verifier matrix. Do not modify the qualified rollback image in place.

## Problem separation

Three different observations must not be conflated:

| Observation | Status | Meaning |
|---|---|---|
| `persistent_topk` candidate-buffer overflow | Confirmed upstream defect | Can silently return the wrong selected-value set when a coarse bin overflows. |
| Tie/order nondeterminism | Confirmed for QSA | Equal-score membership and raw emission order can vary; QSA accumulation is order-sensitive. |
| Thai text corruption in upstream issue `#54521` | Not explained solely by top-k determinism | Exact deterministic `torch.topk` made runs reproducible but did not make all Thai text correct. Sparse-selection quality or another model/runtime issue remains possible. |

The local profile's qualification establishes repeatability for its pinned fixture and complete response. It does not prove that QSA sparse selection preserves all language quality, and it does not close the separate prefix-cache cold/warm drift.

## Current local Qwen v1

### Immutable identity

- Base image: `vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3`
- Derived image config: `sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32`
- Installed vLLM: `0.1.dev20073+g8e685d198`
- Patched QSA SHA-256: `79d13ab4a3805bd568e3b930cd0cc193fbf5997403f9d4e809838193c14204dc`
- QSA selector: `VLLM_QSA_EXACT_TOPK=3`
- Prefix caching: disabled

The stock image routed QSA through `persistent_topk` and failed repeated greedy prefill. The overlay's mode 3 does the following:

1. slices and converts logits to FP32;
2. masks columns outside each authoritative visible length to `-inf`;
3. calls `torch.topk(..., sorted=False)`;
4. canonicalizes the selected set by index and then descending value;
5. writes `-1` padding for ranks beyond the visible length.

This fixed the locally observed nondeterminism. It remains weaker than a formal score/index ordering because `torch.topk` does not promise which equal-valued boundary candidate enters the selected set. Canonicalizing only after selection cannot repair an unstable tie boundary. The existing mode-1 full stable sort does provide lower-index tie behavior, but has not been locally performance-qualified at realistic QSA prefill shapes.

## Upstream status

Status was queried directly from GitHub on 2026-08-31.

| Upstream item | Status | Relevance |
|---|---|---|
| vLLM issue `#51782` | Open | Canonical `persistent_topk` silent-overflow defect. |
| vLLM PR `#52149`, head `b8f88c1a29f54dcc42f1b163db523bf362e845e3` | Open; pre-commit failing | Exact bounded-memory overflow fallback and deterministic pivot collection; lineage used by GLM v9. |
| vLLM PR `#53287`, head `3d3f23f0e460f271839388bd2168e4a214bddace` | Draft/blocked | Alternative overflow exploration. Qwen reporter found its tests permit run-varying tie indices/order. |
| vLLM PR `#53382` | Open/blocked | Expands cooperative top-k to 64 rows, but family 12.x remains excluded; it does not solve large-prefill QSA. |
| Qwen support PR `#53896` | Merged at `e126687…` | Makes Qwen source reconstructible upstream, but retains affected top-k dispatch. |
| PLE offload PR `#53899` | Open, dirty/needs rebase | Mandatory for this workstation's 51.2B-element PLE table. |
| UVA PLE PR `#54371` | Draft/blocked | Potential later offload path; no complete test evidence yet. |
| Qwen issue `#54521` | Open | Direct stock-image QSA nondeterminism evidence on GB10/sm121. |

The exact merged QSA source still contains:

```python
use_cooperative_topk = (
    blocks.shape[0] <= 32
    and logits.stride(0) % 4 == 0
    and current_platform.has_device_capability(90)
    and not current_platform.is_device_capability_family(120)
)
topk_op = (
    torch.ops._C.cooperative_topk
    if use_cooperative_topk
    else torch.ops._C.persistent_topk
)
```

On the local RTX PRO 6000 Blackwell pair (`sm_120`), the family exclusion is active. More importantly, QSA prefill commonly has more than 32 rows, which selects `persistent_topk` regardless of architecture. Simply removing the family exclusion is unsafe: issue `#54521` reports that cooperative-top-k tests fail to launch on GB10, and large-prefill batches would still miss the row-count gate.

## What issue #54521 adds

The upstream stock Qwen image reproduced greedy divergence around and above the sparse-selection boundary. Follow-up isolated two top-k properties:

- raw `persistent_topk` output order varies once more than `k` candidates are visible;
- tie-heavy boundary sets can choose different equal-score indices, even when selected values remain equivalent.

Sorting selected blocks fixed the near-boundary order-sensitive regime. Replacing the selector with exact deterministic `torch.topk` fixed repeated-output nondeterminism for a 20K-token captured request, apart from the already-known cold-versus-prefix-cached computation difference.

However, deterministic selection did not remove all Thai spelling corruption. That is evidence against claiming that the top-k race explains semantic quality loss by itself. It may instead expose ordinary QSA sparsification quality, another runtime defect, or a model/checkpoint behavior. The correct conclusion is narrower: top-k repeatability is fixable and should be fixed, but it is not a complete language-quality proof.

## GLM assets and applicability

### Reusable asset 1: deterministic Python reference

The GLM v8 patch constructs a unique 64-bit key from ordered FP32 score bits and inverse column index, then runs `torch.topk(sorted=True)`. This guarantees lower-index selection for exact ties and masks columns outside authoritative row lengths.

It can be adapted into a QSA mode 4 without replacing the compiled extension. Benefits:

- exact deterministic score/index semantics;
- no dependence on the broken persistent kernel;
- narrow Python-only overlay with the same immutable hash-gated construction as v1.

Costs:

- large temporary int64 tensors at QSA prefill scale;
- likely slower and more memory-intensive than current FP32 mode 3;
- still requires real 64/192/512-row, 65,536-column and long-prefill benchmarks.

Qwen's existing mode 1—stable full sort—is a simpler correctness reference and should be benchmarked alongside the GLM key approach.

### Reusable asset 2: v9 compiled exact selector

The GLM v9 patch, derived from PR `#52149` and strengthened with deterministic pivot collection, provides:

- overflow detection on all persistent dispatch paths;
- exact bounded-memory FP32 rescans;
- deterministic lower-index tie selection;
- selected-value equivalence with `torch.topk`;
- no dependence on fixed candidate-buffer capacity;
- materially better measured GLM latency than full-row `torch.topk`.

A strict dry run against the exact Qwen merge commit succeeded:

```text
patch --dry-run --batch --fuzz=0 -p1 < glm53-v9-fast-persistent-topk.patch
checking file csrc/libtorch_stable/persistent_topk.cuh
checking file csrc/libtorch_stable/topk_histogram_4096.cuh
# all hunks applied; long-path hunks had line-number offsets only, no fuzz
```

This is strong evidence that the algorithm can be ported at source level. It is not permission to reuse the built GLM extension.

### Reusable asset 3: verifier matrix

The GLM GPU verifier already exercises the essential failure classes:

- crowded `33 × 32,769`, `k=2,048` rows against exact selected values;
- all-equal 8,192-column rows with deterministic lowest-index ties;
- the 806,736-column/4,096-visible regression;
- repeated calls and latency comparison.

For Qwen, extend rather than merely copy this matrix:

- `k=512`, columns `65,536`, causal visible lengths around 480/512/768/2,048/8,448;
- rows 1/32/64/192/512;
- continuous, narrow-range, quantized, and all-equal logits;
- exact selected-value and exact selected-index checks;
- repeated launches and CUDA Graph replay;
- QSA expansion/attention output hash, not only selector output;
- cold cache only for top-k attribution; prefix-cache equivalence remains a separate suite.

### Non-reusable GLM assets

Do not port:

- GLM sparse-indexer/KPool Python adapters;
- B12X MLA code;
- DCP global-top-k merge logic;
- the GLM `_C_stable_libtorch.abi3.so` binary;
- GLM CUDA 13.3 build assumptions.

Qwen owns a different QSA call path and PLE/MTP state model.

## Options

### A. Keep local v1 unchanged

- **Pros:** already deterministic on the qualified local fixture; immutable and rollback-safe; no build risk.
- **Cons:** formal equal-boundary tie semantics remain weaker; base source provenance remains unresolved; `torch.topk` has prefill overhead; prefix caching and recurrent-state safety remain unpromoted.
- **Use:** current rollback/experimental profile.

### B. Add a Python deterministic-key QSA mode

- **Pros:** narrowest source change; takes the proven score/index-key idea from GLM v8; no compiled ABI replacement.
- **Cons:** likely high temporary memory and latency at 512-row prefill; current mode 3 already passes observed determinism; source provenance of the base wheel remains unresolved.
- **Use:** diagnostic candidate, not the final promoted profile.

### C. Rebuild Qwen with the compiled exact persistent selector

- **Pros:** deepest fix at the shared defective operator; exact overflow handling and deterministic ties; best likely performance; directly reusable verifier logic.
- **Cons:** requires a complete reconstructible Qwen+PLE source tree and a full extension build; upstream PR is not merged; all Qwen/MTP/PLE/vision paths require requalification.
- **Use:** recommended v2 direction after pinning a viable PLE source revision.

### D. Copy the GLM extension binary

**Rejected.** Different CUDA builds, different source trees, different extension hashes, and different model/runtime surfaces make this an unqualified ABI replacement.

## Recommendation

Do not rebuild urgently: the local v1 overlay already fixes the observed top-k repeatability defect, and the qualified GLM v10 remains the active safe profile.

For Qwen v2:

1. pin the merged Qwen source commit plus one exact, reviewable PLE-offload revision;
2. rebuild the complete stable extension in that source tree with the GLM-v9/PR-52149 exact selector adapted as a Qwen-owned patch;
3. canonicalize QSA's selected block order explicitly even if the kernel is deterministic;
4. run the extended selector and QSA-output verifier matrix;
5. retain prefix caching off;
6. apply the separately planned accepted-token/recurrent-state checks;
7. launch as a new immutable profile with `restart=no` and preserve v1 for rollback.

If PLE offload cannot yet be reconstructed cleanly from public source, wait rather than grafting a new compiled extension into the provenance-unknown v1 wheel.
