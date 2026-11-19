# GLM-5.3 Flash EXL3 K4 v9 fast/safe image research — 2026-08-30

**Status:** research complete; implementation and GPU qualification pending. No existing image is
both a drop-in replacement for the two-GPU EXL3 deployment and qualified for vision, MTP3,
prefix caching, 359K context, deterministic temperature-zero output, and sustained mixed traffic.
The recommended path is a new immutable v9 overlay, not an unpinned nightly or a switch to DFlash.

## Decision

Build v9 from the exact v84 rootfs currently used by v8, retaining EXL3 K4, B12X, FP8 DS-MLA
KV, vision, MTP3, and prefix caching. Replace the expensive unconditional `torch.topk` repair with
an overflow-safe exact persistent-top-k implementation, add the missing overlap-safe Mamba state
copy and remaining KPool/block-table bounds, then attempt to recover CUDA graphs and DCP2 one
independently qualified step at a time.

The likely fast path is:

```text
v84 EXL3/B12X rootfs
+ current #50021 accepted-count bounds
+ current CPU-proven mixed-token partition
+ #50729 overlap-safe Mamba state copies
+ #53982 V1/V2 block-table row bounds
+ KPool tail circular-slot/graph-address repair
+ #52149 exact overflow-aware persistent top-k
+ deterministic equal-score boundary repair
+ MTP/prefix replay-boundary repair adapted from #52244/#53802
+ CUDA graphs, initially DCP1; DCP2 only after equivalence gates
```

Do not promote a candidate merely because it is faster or survives a smoke test. The image must
pass complete-message output equivalence across cold/warm/partial-warm histories, mixed
prefill/decode traffic, graph shapes, process restarts, and changed image inputs.

## What the research established

### 1. The current base is missing a merged state-copy race fix

The v84 image identifies embedded vLLM commit
`6dc2f516688fe6f84c6994dcd20fddf296853a6c`. Its
`vllm/v1/worker/mamba_utils.py` still uses parallel memcpy-style copies for overlapping
same-block convolution-state shifts. It has no `is_left_overlap`, ordered token copy, or
`tl.debug_barrier` handling.

Upstream PR [#50729](https://github.com/vllm-project/vllm/pull/50729), merged as
`a02cfccbc6187344325e364f09f6d8c33c4b253b`, gives those copies memmove semantics while retaining
the fast tiled path for non-overlapping blocks. Field evidence in
[#54317](https://github.com/vllm-project/vllm/issues/54317) changed a production GLM-5.3 crash
cadence from every 2–4 hours to one 2h15m post-patch crash followed by an 11+ hour clean flight;
the issue explicitly reports that the race is exercised by prefix-cache/preemption traffic even
without speculative decoding.

The complete #50729 patch applies cleanly to public commit `6dc2f516…`. The v84 custom tree and
our #50021 port both modify `mamba_utils.py`, so v9 must merge the two safety changes and rerun
all invalid-count plus overlap tests; applying one patch over the other blindly is not acceptable.

This is the strongest lead for safely recovering CUDA graphs. Current v8 disabled graphs because
captured hybrid-state execution drifted; overlap-unsafe state copies are graph/timing sensitive.

### 2. Our unconditional `torch.topk` fix is safe but unnecessarily expensive

v8 replaced three GLM `persistent_topk` call sites with an exact `torch.topk` seam over the full
allocated row width. This removed vLLM issue
[#51782](https://github.com/vllm-project/vllm/issues/51782), but an independent report measured
approximately 15–25% decode-step overhead from the same mitigation, and our complete-image
benchmark rate fell from 43–88 effective tok/s on the old MTP3 image to about 30.7 tok/s on the
hardened image. Eager execution and DCP1 also contribute, so the exact share still requires A/B.

Upstream PR [#52149](https://github.com/vllm-project/vllm/pull/52149) detects candidate-buffer
overflow in every persistent-top-k dispatch path and falls back to bounded-memory exact FP32
radix selection. It preserves the existing workspace and graph contract. Its source-only patch
applies cleanly to public commit `6dc2f516…`.

Evidence reported by #52149:

- zero selected-value mismatches across its forced-overflow matrix;
- exact agreement with `torch.topk` selected-value multisets;
- GLM-5.2 TP2 C1 changed from 45.68 to 46.48 tok/s (+1.74%);
- GLM-5.2 TP2 C33 changed from 715.08 to 729.18 tok/s (+1.97%);
- no material normal-path regression.

The PR is still open/blocked, so v9 must pin and vendor the exact source rather than track the PR
branch. It also guarantees exact values, not deterministic membership among equal-valued boundary
candidates. v9 therefore needs a deterministic boundary-tie repair that chooses the lower token
index only among scores exactly equal to the selected threshold. It must not perturb scores or
construct out-of-FP16-range float keys, because that recreates the histogram crowding defect.

Tencent HPC-Ops now has an exact sampled/verified top-k merged in
[Tencent/hpc-ops#93](https://github.com/Tencent/hpc-ops/pull/93), measured 1.17–1.57x faster than
the nearest exact competitor and up to roughly 4x faster than older exact vLLM paths. It is not a
v9 dependency yet: its build supports SM90/SM100/SM103 only, not SM120. A separate SM120
micro-port may be evaluated later, but must not block the immediately applicable #52149 path.

### 3. Additional memory-safety fixes are required before graphs are reconsidered

- [vLLM #53982](https://github.com/vllm-project/vllm/issues/53982): both model-runner slot-mapping
  kernels can read past a narrow block-table row. The CUDA report says prompts beyond roughly 8K
  can fault without the guard. Both V1 and V2 must mask `block_indices < block_table_stride` and
  explicitly emit `PAD_SLOT_ID`; using `other=0` alone aliases invalid lanes to real block zero.
- [vLLM #53906](https://github.com/vllm-project/vllm/pull/53906) discussion: the hybrid model runner
  omitted `positions=input_batch.positions` when building KPool tail metadata, so the one-block
  circular mapping never ran. The corresponding graph path cloned the slot-mapping tensor and
  captured a transient address. The reported repair passes positions and writes into the
  caller-owned persistent buffer. Independent SM90 validation confirmed correct circular slots.
- [vLLM #50021](https://github.com/vllm-project/vllm/pull/50021): remains mandatory. It is open and
  validated under eager/align mode, so retain our pinned port and invalid-count GPU tests.
- The current authoritative-CPU mixed-token partition remains mandatory. It fixes a GLM-specific
  asynchronous partition/indexing failure not covered by #50021 or #50729.

### 4. DCP2 and CUDA graphs may be recoverable, but are not assumptions

Upstream PR [#52377](https://github.com/vllm-project/vllm/pull/52377), merged as
`22099afc6423efa2c6dac58ecaf0c5cbe652ece2`, repairs sparse-MLA metadata and workspace handling
after the DCP-manager refactor. Its patch does not apply directly to the older custom v84 DCP
implementation and needs a semantic port if DCP2 is retried.

Historical v71/v84 evidence on two RTX PRO 6000 cards shows what the graph/DCP2 path can do:

- built-in MTP3: roughly 140–147 C1 tok/s through 64K in the 600 W/+6000 MHz receipt;
- older conservative receipt: roughly 99–112 C1 tok/s through 128K;
- DFlash2 v84: 145–152 C1 tok/s through 64K, but with only a 98K ceiling and prefix caching off.

Those are not promises for this 450 W, 359K, deterministic profile. They prove that 30 tok/s is
not an architectural limit of the checkpoint. A reasonable initial v9 gate is at least 2x current
C1 throughput without weakening any correctness gate; the stretch target is 90+ tok/s at 128K.

### 5. Prefix-cache efficiency has upstream repair candidates

Open PR [#52244](https://github.com/vllm-project/vllm/pull/52244) moves hybrid recurrent-state
snapshots to the position where an MTP replay actually lands and adds the required prefill split.
Its 132-length sweep reached the exact replay ceiling for every tested length. PR
[#53802](https://github.com/vllm-project/vllm/pull/53802) is a smaller related boundary repair.
Neither applies directly to the older v84 coordinator, so v9 should port the invariant rather than
copy either diff mechanically:

```text
snapshot_position = floor((prompt_tokens - 1 - replay_unit) / replay_unit) * replay_unit
```

The port is a performance and correctness feature: it prevents zero/partial hits at unlucky prompt
lengths, but it must pass full output-equivalence tests before being enabled.

The separate 7,808-token hybrid page-size problem in
[#54458](https://github.com/vllm-project/vllm/issues/54458) still limits concurrency and cache
retention. There is no reviewed implementation ready to vendor. Do not redesign the cache layout
inside the first v9 image; record exact per-request page consumption and treat this as a later v10
candidate.

## Existing alternatives rejected

| Candidate | Decision | Reason |
|---|---|---|
| Official `vllm/vllm-openai:glm53-flash` | Reject | GLM-5.3 support PR #53906 remains open; image issue #54317 reports recurring memory corruption; it does not supply the EXL3/B12X contract. |
| Current vLLM nightly | Reject | No merged GLM-5.3-Flash support; multiple required fixes remain open; hybrid spec+prefix behavior is still under active repair. |
| SGLang GLM-5.3 branch | Reject for SM120 | Model and vision PRs remain open; SM120 has unsupported DSA decode backends, TP>1 MTP loading defects, and graph failure above ~262K. |
| TensorRT-LLM GLM-5.3 | Reject | Current documentation covers the non-Flash `GlmMoeDsaForCausalLM` path on 8x B200, not the two-GPU `Glm5Next` EXL3 checkpoint. |
| DFlash2 v84 | Reject for production requirement | It is fast but replaces mandatory MTP3, cuts measured multimodal capacity to 98K/129K KV tokens, ships under CC-BY-NC-ND-4.0, and has numerous open draft/prefix/graph issues. |
| Local-Inference-Lab NVFP4+DFlash2 | Reject | Qualified topology is TP4/DCP4 with an external draft, not two-GPU EXL3/MTP3/359K. |
| HPC-Ops exact top-k now | Defer | Promising, but no SM120 build/support or local GPU qualification yet. |

## v9 construction plan

### Layer 1 — state-safe eager control

Keep DCP1 and eager execution. Add #50729, #53982, and KPool-tail repairs to the current v8 state
patch. Retain current exact `torch.topk`. This isolates state correctness from top-k performance.

### Layer 2 — fast exact top-k

Replace the unconditional `torch.topk` overlay with pinned #52149 source plus deterministic
boundary-tie repair. Keep eager/DCP1. Compare target-step latency and complete outputs against Layer
1 using captured real indexer tensors and end-to-end requests.

### Layer 3 — CUDA graphs at DCP1

Enable graphs only after Layers 1–2 pass. Exercise every captured batch/spec width, cold and cached
prefill, mixed decode/prefill, long generations, and process restarts. Any cache-history-dependent
hash or GPU fault returns v9 to eager mode.

### Layer 4 — DCP2

Port #52377 semantics as required by the custom DCP manager, then test DCP2 as a separate image.
DCP2 must beat DCP1 materially and pass the same output-equivalence matrix. It is not promoted
merely because it boots or benchmarks faster.

### Layer 5 — deterministic collective relaxation

A/B the current Ring/Simple, one-device-connection, deterministic cuBLAS, and custom-all-reduce
disablement one setting at a time. Remove a restriction only when complete outputs remain equal
across repeated boots and traffic histories. Keep `CUBLAS_WORKSPACE_CONFIG` unless a controlled test
proves it irrelevant.

## Mandatory GPU gates

1. **Source identity:** hash every base and patched file; prove the complete base-rootfs prefix;
   compile Python and CUDA sources; pin the final image by config and manifest digest.
2. **Accepted-count bounds:** all #50021 invalid zero/oversized-count tests across KDA/GDN/Mamba,
   causal convolution, and state copy.
3. **Overlap semantics:** #50729 same-block left-shift tests for SD/DS layouts, multiple dtypes and
   biases, repeated under eager and graph replay.
4. **Slot bounds:** V1 and V2 narrow-row block-table tests; invalid columns must become
   `PAD_SLOT_ID`, never block zero.
5. **KPool tail:** circular slots at long positions; no transient graph address; 8K+ generated-token
   completion with zero out-of-range writes.
6. **Top-k:** all #51782/#52149 paths, crowded bins, 806,736-column regression, ragged sequence
   lengths, exact selected values, deterministic equal-score membership, 200 eager repeats and 200
   graph replays.
7. **Temperature-zero equivalence:** complete response hashes across at least 20 repeats per cell:
   cold, exact warm, partial warm, changed prefix, changed image, identical image, process restart,
   and graph-shape transitions.
8. **Mixed traffic:** cached MTP decode plus newly admitted 100K/256K/350K prefills; no partition
   gaps, state-index errors, Xids, or decode starvation.
9. **MTP:** MTP3 remains active; record target steps/s, accepted length, accepted-token throughput,
   and output identity separately.
10. **Vision/tools:** one and four images, changed bytes, reasoning, single/parallel/malformed tool
    calls, and explicit video rejection.
11. **Context:** retrieval and generation at 98K, 128K, 256K, 350K, 359K boundary, and clean
    overflow rejection.
12. **Soak:** reboot before qualification; no prior-boot Xid contamination; minimum 12-hour mixed
    soak with restart policy `no` and zero new Xid/SXid/MMU/corrected-error events.

## Throughput matrix

Use fixed tokenized prompts, `temperature=0`, `ignore_eos`, 1,024 output tokens, serial warmup, and
three measured repetitions per cell. Report client output tok/s, server generation tok/s, target
steps/s, MTP acceptance length, TTFT, TPOT, power, clocks, and cache hit deltas.

| Context | C1 | C2 | C4 |
|---:|:---:|:---:|:---:|
| 0 | required | required | required |
| 32K | required | required | required |
| 128K | required | required | capacity permitting |
| 256K | required | capacity permitting | no claim |
| 350K | required | no claim | no claim |

Also run a decode-plus-cold-prefill fairness cell with a 512-token long-prefill scheduling cap.
That cap should be evaluated for tail latency separately from raw prefill throughput.

## Promotion rule

Promote only an immutable image that:

- preserves vision, MTP3, prefix caching, and the 359K request envelope;
- passes every memory-safety and complete-output-equivalence gate;
- records a fresh exact KV-capacity receipt;
- delivers at least 2x current C1 decode throughput at 128K without a material prefill or quality
  regression;
- survives the mixed 12-hour soak with no GPU fault;
- remains `restart=no` until all gates pass.

Until then, v8 remains an unpromoted diagnostic service and the known rollback image remains
available. No mutable tag or upstream performance claim is sufficient evidence for promotion.
