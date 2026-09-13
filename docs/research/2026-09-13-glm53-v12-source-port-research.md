# GLM-5.3 EXL3 K4 v12 source-port research — 2026-09-13

**Status:** implementation candidate, not a release and not permission to replace
v11.1. The production baseline remains GLM-5.3 Flash EXL3 K4 v11.1 until a
separately identified v12 image passes every gate in this receipt.

## Executive decision

The 2026-09-13 Spark TP2 R2 update adds no new vLLM, B12X, or LMCache
implementation commits relative to the R1 source audited on 2026-09-12. Its
new information is nevertheless useful:

1. `CUBLAS_WORKSPACE_CONFIG=:4096:1` saved 140 MiB of live allocation per rank
   on the same GPU family without a measured throughput regression.
2. A fixed 1M context plus fixed 4 GiB/rank KV contract was qualified for the
   Spark profile; automatic context shortening is now explicit opt-in.
3. Engine-driven LMCache can restore a complete 1,048,320-token text prompt
   from RAM or filesystem-backed storage without recompute while keeping the
   sidecar CPU-only.
4. The R2 qualification materially improves evidence quality: stock clocks,
   same-session control, immutable source/recipe identities, million-token
   vision, mixed progress, cache attribution, and explicit limitations.

The recommended first v12 candidate is still a **narrow child of v11.1**, not
a transplant of the Spark image or its complete source tree:

- port the SM120/121 disjoint-batch MLA fix;
- port Mamba cleanup across null gaps;
- correct CUDA-graph memory double accounting;
- add the 4 MiB cuBLAS workspace limit as a measured, reversible launcher
  setting;
- preserve v11.1's r2.1 admission fixes and all existing model/runtime choices.

Vision-memory changes and DCP scratch reuse should be evaluated only after that
core candidate is green. LMCache is a separate `v12-cache` child because it
activates new scheduler, recurrent-checkpoint, transfer-lifetime, host-memory,
and filesystem failure modes.

**Implementation status (2026-09-14)**: the recommended first candidate is
implemented as **v12** — `scripts/inference/glm53/glm53-v12-upstream-core-port/`
(byte-pinned overlay archive `upstream-core-port-v12-pr710-pr718-pr694.tar.gz`,
SHA-256 `898db34d0535fbd32312f7071a9354e10174aeed623dafba2ee4f4d9aff5d288`, 102
files), pull/run/switch scripts, and
`tests/glm53-flash-exl3-k4-vllm-sm120-v12-contract.sh` (PASS). The upstream
patches do not apply to the legend r2.1 overlay files, so the port is by hand;
see the deployment receipt
`benchmarks/vllm-tps/2026-09-14-glm53-v12-deployment-receipt.md` for the four
ported changes, the pinned artifacts, and the operator steps (the build and
qualification run on the desktop host). Image id unrecorded until the first
build.

---

## 1. Scope and method

This receipt consolidates the 2026-09-12 audit and the 2026-09-13 R2 update.
It compares:

- local v11.1 packaging, launcher, overlay manifest, contract, and qualification;
- the source-locked Spark TP2 R1/R2 artifacts;
- the exact vLLM tree embedded in those artifacts;
- the R2 recipe commits and LMCache source identity;
- relevant upstream pull requests and production-file diffs.

The comparison is source-based. Similar names or a mutable branch head are not
accepted as evidence. Applicability is classified independently for engine
correctness, memory/capacity, checkpoint-specific optimization, and launcher
tuning.

### Local production baseline

| Item | Identity / contract |
|---|---|
| Served model | `glm-5.3-flash-exl3-k4-vision-fp8kv-mtp-359k-v11.1` |
| Image config | `sha256:b53556e777c0505e03ffb2255dbd373b1f32b837c468dde4a4e753ca23c3822b` |
| Base image | `verdictai/glm53-flash-exl3-k4@sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Overlay | legend upstream-core-port r2.1, commit `832e6000120148f82c64acaecc56b6f96c27e6e2` |
| Overlay archive | SHA-256 `91c370ce94e93ef73b09974a2b627cf6b26e8bd3f5a1d4a88022c56742db3c83` |
| Runtime shape | TP2 / EP2 / DCP2 A2A, EXL3 K4 weights, FP8 DS-MLA KV, probabilistic MTP3, vision |
| Serving limits | 359,000 context, `--max-num-batched-tokens 2048` scheduler-wide batch cap, at most 16 requests, utilization-sized KV |
| Critical local fixes | real-footprint align admission, reserve aging, unconditional deferred-free drain |
| Qualification | promoted 2026-09-08; 1,530,473 logical KV tokens, long-context/mixed/churn gates and 30-minute soak passed |

The local source base reports `0.1.dev20111+g7f1e92bec.d20260827`. The v11.1
overlay replaces 91 base files and adds 10 modules through 101 fail-closed
manifest destinations.

### Spark TP2 R2 immutable identities

| Item | Identity |
|---|---|
| Documentation commit | `local-inference-lab/rtx6kpro@74485e5262c31ddeaef7aae0aec9879bcef0d5cb` |
| Published image | `localinferencelab/vllm@sha256:c549afc8dc065fa63246618761ec2563af78ff70dae6409ed5c72acdc850f795` |
| Image config | `sha256:a96dcc30390a9f8750f1e2000f3a4d12d6fe7b268b10d1143bf37a7e3ec91c5b` |
| Source-lock SHA-256 | `87bd0bbb39e690285567c1ed55551e2dbf8dcd14980944a0e8981abf276c1cd2` |
| vLLM commit / tree | `7f4aecc66e857d093e012a2c57d03711bd23be4a` / `638917d5473e73a7d56e8d033b41c0cd34b68181` |
| B12X commit / tree | `73f66f028c1b59e92728e9fbbe4a472bb7796248` / `e16e8830853ee030a89efcc2554871a42616be19` |
| LMCache commit / tree | `29bc5a2efde737c436b04499eb62cd1776cebeec` / `5a88a1ea9d2627c76288d056e7193f7454669b64` |
| Recipe commit / tree | `b91127b1a54997d9a67a8aead8c1acf97b194f7b` / `57077f4327b9e8d86c0c5dd97272ddfd0c33a612` |
| Runtime | CUDA 13.3, PyTorch 2.13, vLLM `0.26.1rc0+glm53.tp2.experimental2.vllm7f4aecc6` |

The R2 artifact audit explicitly reports
`component_implementations_unchanged=true`: R2 changes packaging, launch
policy, and qualification, not the vLLM/B12X/LMCache implementations reviewed
for R1.

---

## 2. What is new in the 2026-09-13 R2 update

### 2.1 Bounded cuBLAS workspace — take into the v12 candidate

R2 sets:

```text
CUBLAS_WORKSPACE_CONFIG=:4096:1
```

The controlled stock-clock comparison reports 140 MiB less live allocation per
rank than `:32768:8`, with −0.02% measured 32K prefill, +0.21% C1 output, and
−0.07% verifier steps. Those ranges do not establish a speed change, but they
do establish a useful memory reduction on the target GPU family.

**Decision:** include it in v12-rc1 as a launcher-owned value with an explicit
override for the A/B gate. Do not silently add it to production v11.1. It does
not replace the SM120 allocation-boundary source fix and is not a universal fix
for every reported cuBLAS failure.

### 2.2 Fixed context and KV allocation — adopt the contract pattern, not the numbers

R2 explicitly requests:

```text
MAX_MODEL_LEN=1048576
KV_CACHE_MEMORY_BYTES=4294967296
```

Automatic profiling requires `KV_CACHE_MEMORY_BYTES=auto`; accepting a shorter
context additionally requires `MAX_MODEL_LEN=-1`. This is a good fail-closed
serving contract: an operator cannot believe a native context was served after
an automatic fit silently shortened it.

The exact 4 GiB value is not transferable without testing. R2 permits four
requests and uses a different NVFP4 Spark checkpoint; local v11.1 permits 16
requests and currently reports 1,530,473 logical KV tokens from
`--gpu-memory-utilization 0.987`. Local v10 already showed that 3.5 GiB/rank
provided 691,602 logical tokens, so a fixed local budget may still cover the
359K window but would reduce aggregate concurrency.

**Decision:** v12-rc1 keeps v11.1's utilization-sized KV so source fixes remain
attributable. A later memory-contract experiment should compare a fixed budget
against the existing 1,530,473-token receipt and may be promoted only if its
concurrency and transient-headroom trade is deliberate.

### 2.3 Engine-driven LMCache — valuable, but a separate child

R2 qualifies a CPU-only sidecar with worker-owned asynchronous GPU
gather/scatter. Its 64 GiB L1 arena is preallocated pinned shared memory; L2
objects can persist on a filesystem. For a 1,048,320-token synthetic text
prompt it reports:

| Path | Restore | Attribution |
|---|---:|---|
| RAM | 0.808 s | 1,048,320 external-transfer tokens, zero recompute |
| Filesystem after both services restart | 1.279 s | 1,048,320 external-transfer tokens, zero recompute |

Literal-document and shared-instruction tests separately passed 16 exact-answer
checks. The filesystem result includes the OS page cache and is not cold-disk
throughput.

This is attractive for repeated long agent instructions and long-lived chat
histories, but it is not a launcher-only change for local v11.1. Correct hybrid
restore requires atomic bundles containing target and MTP recurrent endpoints,
model/checkpoint/layout identity, scheduler integration, block leases, and
completion handling. The local overlay has connector-aware engine code, and
its r2.1 deferred-free drain was designed for this state, but it does not ship
the qualified LMCache package or this complete semantic-checkpoint composition.

The serving host must also prove enough available RAM and host `/dev/shm` for
the non-lazy pinned L1 arena, unlimited or sufficient memlock, and writable,
sized L2 storage. These are startup invariants, not warnings: failure must occur
before either service starts.

**Decision:** do not enable LMCache in v12-rc1. Design and qualify an opt-in
`v12-cache` child after v12 core promotion. Keep GPU-local prefix caching as the
default.

### 2.4 R2 launcher details to benchmark, not copy blindly

- `OMP_NUM_THREADS=1` versus local `2`;
- NCCL min/max channels `2` and buffer `1 MiB`;
- `expandable_segments:True,large_segment_size_mb:12`;
- B12X KDA prefill and a 65,536-token full-CKV gather cap;
- scheduler budget 3,072, at most four requests, and graph captures through 16.

The first three are cheap A/B candidates. B12X KDA and CKV gathering are tied to
the newer source/backend composition; local v11.1 explicitly uses Triton KDA
and custom B12X DCP A2A. Scheduler and graph shapes encode a different
concurrency contract. None belongs in v12 without isolated measurements.

---

## 3. Consolidated source-port ledger

### 3.1 Include in v12-rc1

| Priority | Change | Exact source | Local evidence | Decision |
|---|---|---|---|---|
| P0 | SM120/121 disjoint MLA BMM storage | PR [#710](https://github.com/local-inference-lab/vllm/pull/710), `dbdf960a3362b719cafd726377085ee63dfdff35` plus documentation `0eff58055a9c193f98c132b9528b057a244e32a7` | Current `mla_attention.py` uses the affected direct `torch.bmm`; the unmodified reproducer triggered a native MMU fault at a mapped allocation end on RTX PRO 6000, while the patch prevented it | Port |
| P0 | Mamba recurrent cleanup across null gaps | PR [#718](https://github.com/local-inference-lab/vllm/pull/718), `25fc3585faee243b345dce770a3f1e0ee59a0ee2`; upstream vLLM #55450 | Current align mode deliberately creates null gaps but lacks `_num_retired_blocks` and the Mamba-specific range cleanup | Port |
| P1 | Count graph memory once | PR [#694](https://github.com/local-inference-lab/vllm/pull/694), `dd8e5ca35f5ec9af0ce7d44ad0aabcb4a550d329` + test `d84208d424a16b15edc5f6e7e4326ec9d3409b1e` | Current `gpu_worker.py` adds the graph estimate to activation peak and later adds measured graph memory again; `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` currently masks it | Port while retaining the zero-estimate setting for first qualification |
| P1 | Bound cuBLAS workspace to 4 MiB/handle | recipe `707d33e87dba6072e582af38114feb4acf5c5f68` | Same GPU family; measured 140 MiB/rank reduction with overlapping performance samples | Add to candidate launcher and A/B |

Expected production-source delta relative to the v11.1 installed tree:

```text
vllm/model_executor/layers/attention/mla_attention.py
vllm/v1/attention/ops/dcp.py
vllm/v1/core/single_type_kv_cache_manager.py
vllm/v1/worker/gpu_worker.py
```

The first three are already v11.1 overlay destinations. `gpu_worker.py` becomes
one new explicit replacement in the v12 manifest. The installer must update its
pinned mapping/replacement counts rather than treating it as an implicit copy.

### 3.2 Evaluate only after v12 core is green

| Change | Exact source | Applicability and decision |
|---|---|---|
| Bounded vision temporaries | `7f4aecc66e857d093e012a2c57d03711bd23be4a` | Local multimodal code lacks 4,096-row chunking and uses the same conceptual GLM vision pipeline. High-value for large/multiple images, but adapt only the vision portions and requalify the local four-image contract. |
| DCP/MLA scratch reuse | `0fb58627`, `2e6ff184`, `0114a09b`, `317afc7c`; full-size test `c9eb3e58` | Potentially substantial transient-memory recovery. Port as one coherent stack; local A2A and backend ownership differ. Never cherry-pick isolated hunks. |
| Pooled-indexer target-layer sharing | `d5b19d25eeedec5a1e127531d39938e11de364e2` | The local indexer implementation is structurally older. Adapt only after an allocation trace identifies equivalent disjoint lifetimes. |
| Target/MTP temporary sharing | `7f4aecc66e857d093e012a2c57d03711bd23be4a` | Valid only for matching geometry, one MTP layer, PP1, and no overlapping microbatches. Local MTP3 satisfies some but not automatically all guards. |
| Reclaim retired profiling allocations before explicit KV pool | `7f4aecc66e857d093e012a2c57d03711bd23be4a` | Relevant only if v12 later adopts explicit KV bytes. Keep coupled to that experiment. |
| Router FP32 output / SM120 graph-pool guard | PR [#666](https://github.com/local-inference-lab/vllm/pull/666), `97dab213776f115d55642a79b64a4b002ce47a90` | Current source does not enable the newer SM120 cuBLAS router path, so the exact graph guard is not currently exercised. Porting it also changes router arithmetic/dispatch; require accuracy and graph A/B first. |
| Probabilistic draft top-k/top-p matching | PR [#573](https://github.com/local-inference-lab/vllm/pull/573), `cfa34ed7770512640fef3bdc219594cb8e07ac00` | Improves proposal match/acceptance; rejection remains distribution-correct without it. Confirm the local GPU MTP path before adapting CPU proposer code. |
| Partial pooled tail placement | PR [#715](https://github.com/local-inference-lab/vllm/pull/715), `618562444d73742e4e872defcad4d37f477f5c59` | Exact fix targets `ops/glm_kpool.py`; local code uses `ops/kpool_compress.py` and a padded full-width selection. Add a local regression first; do not assume the bug transfers. |
| Direct DCP peer-access eligibility | PR [#599](https://github.com/local-inference-lab/vllm/pull/599), `c2a13c2c0c000580f0619304ec8bae8767ab6541` | Sensible fail-closed behavior, but local custom B12X A2A uses a different call path and fixed two-GPU topology. Trace before porting; add a launcher P2P preflight independently. |
| Tool-call parser hardening | parser commits in PR [#701](https://github.com/local-inference-lab/vllm/pull/701) beginning `c252a205` and `d93140e6` | Useful for agent serving, but separate from GPU memory/liveness and spans frontend parser contracts. Qualify malformed, streamed, and replayed GLM tool history independently. |

### 3.3 Already covered locally

| Upstream concern | Local status |
|---|---|
| Independent draft RNG, PR #653 | Equivalent disjoint Philox range exists through `DRAFT_GUMBEL_POS_OFFSET`; do not duplicate. |
| Shared-expert output lifetime, PR #706 | Current base records `output` on the consumer stream after waiting; equivalent protection exists. |
| CUDA graph resource retention | Current v11.1 lineage already retains capture resources required after capture. |
| Expandable-segment compatibility, PR #553 | Current engine has expandable-segment/cumem compatibility handling; R2's allocator string remains an A/B setting, not a missing engine fix. |
| r2.1 real-footprint admission / reserve aging / zero-token deferred-free drain | Local-only, qualified, and mandatory. The Spark source does not replace these exact protections. |

### 3.4 Do not port into the EXL3 profile

- release of duplicate MXFP8/NVFP4 packed weights;
- private NVFP4 MTP vocabulary head;
- B12X W4A16 expert-specific changes and B12X scale padding;
- Spark checkpoint limits or model identity;
- one-image/four-request serving limits;
- CUDA 13.3/PyTorch 2.13 as an incidental part of this fix set;
- performance numbers as expected EXL3 gains.

Those are checkpoint, quantization, backend, or complete-runtime decisions—not
generic vLLM fixes.

---

## 4. Optional `v12-cache` composition

LMCache must be treated as a coherent subsystem. The list below is an
integration inventory, **not** an ordered cherry-pick recipe. The implementation
baseline is the complete source-locked vLLM commit/tree `7f4aecc6` /
`638917d5`; a port must map every cache-relevant difference onto v12 core and
prove that omitted differences are irrelevant.

| Capability | Pinned source evidence | Principal vLLM files |
|---|---|---|
| Request-boundary capture and scheduler integration | `52d9977bc`, complete GLM cache composition `91e48841b` | `config/{cache,vllm}.py`, `v1/core/{boundary_checkpoint,kv_cache_manager,sched/scheduler}.py`, `v1/worker/gpu/{boundary_checkpoint,input_batch,model_runner}.py` |
| Aligned hybrid reuse and block leases | `86acae98f` | `v1/core/{block_pool,kv_cache_coordinator,kv_cache_manager,single_type_kv_cache_manager}.py` and connector scheduler/worker implementations |
| DCP/MTP recurrent restore | `858b49126`, `99c94361d` | `v1/worker/gpu/{boundary_checkpoint,model_runner}.py`, `v1/worker/gpu/model_states/mamba_hybrid.py`, MTP/DFlash speculator integration |
| Atomic external export/import and worker copies | PRs [#708](https://github.com/local-inference-lab/vllm/pull/708) and [#709](https://github.com/local-inference-lab/vllm/pull/709), especially `b4c0fef2a` and `7ca53f89c` | connector `v1/base.py`, `v1/core/{boundary_checkpoint,kv_cache_manager,sched/scheduler}.py`, `v1/worker/gpu/{boundary_checkpoint,kv_connector,model_runner}.py` |
| Cache admission correctness | exact-hit `871d0133d`, queued-local admission `893ce0d38` | `v1/core/{kv_cache_manager,sched/scheduler}.py`, GPU input-batch state |
| Partial attention-page reuse | PR [#676](https://github.com/local-inference-lab/vllm/pull/676), `74cf9209092b3b8d986aecd0d55983ed6f9d8724` | `v1/core/single_type_kv_cache_manager.py` |
| Late/stale completion tolerance | PR #701, `07f399a12cf9075286b950416c8d834006d05190` | `v1/core/sched/scheduler.py` |
| Recurrent endpoint capacity accounting | `94febe5c35530d630b161b5abf5617e484b70fbe` | `v1/core/kv_cache_utils.py` |

The child must additionally pin exact LMCache source
`29bc5a2efde737c436b04499eb62cd1776cebeec` or an independently audited
successor; source-lock model, tokenizer, chat template, KV/recurrent layouts,
quantization, and connector identity so incompatible objects are safe misses;
and preserve v12 core including the local r2.1 deferred-free drain.

The sidecar/runtime shell must enforce these startup invariants before either
child process starts:

- CPU-only sidecar and worker-owned GPU copies;
- a unique, non-lazy named shared-memory arena;
- available host RAM and `/dev/shm` exceeding the configured L1 arena plus
  transfer/process headroom;
- sufficient memlock limit for the pinned arena;
- an absolute, non-symlinked, writable L2 path with an explicit capacity and
  eviction policy when L2 is enabled;
- loopback administrative listeners unless a separately authenticated network
  boundary exists;
- signal and unexpected-child-exit propagation that terminates both processes.

The following R2 facts must remain explicit:

- L1 size is a preallocation, not a lazy maximum;
- `--ipc host` means Docker `--shm-size` does not enlarge host `/dev/shm`;
- exact multimodal endpoint restore is unsupported;
- storage-object size, per-rank attention page size, and the scheduler-wide
  batching cap are independent dimensions;
- filesystem results including OS page cache are not cold-disk results.

A local geometry must be derived, not copied. R2 uses 4,096 global-token
objects, 2,048-token per-rank attention pages, and
`--max-num-batched-tokens 3072`. Local v11.1 uses a 17,920 FP8 retention
interval and `--max-num-batched-tokens 2048`. Neither option is a per-request
generation limit.

---

## 5. v12 implementation shape

### Recommended approach

| Approach | Benefits | Costs / risks | Decision |
|---|---|---|---|
| Replace v11.1 with the complete Spark image/tree | Fast access to the published composition | Changes checkpoint, quantization, KDA, CUDA/PyTorch, cache policy, context, image count, concurrency, and loses local r2.1 attribution | Reject |
| Copy all newer vLLM files over the local overlay | Captures many fixes | Cross-lineage APIs and ownership assumptions become implicit; failures cannot be attributed | Reject |
| Build a manifest-pinned child with four source replacements and one launcher setting | Small review/test surface; preserves qualified behavior and rollback | Requires adapting upstream tests to the older tree | **Use for v12-rc1** |
| Add memory ports and LMCache to the same first candidate | Maximum feature gain | Conflates reliability, memory, and cache lifetime changes | Reject; stage as children |

### Proposed lineage

```text
v11.1 (qualified r2.1)
  └── v12-rc1
      ├── PR #710 SM120/121 disjoint MLA BMM
      ├── PR #718 Mamba null-gap cleanup
      ├── PR #694 graph-memory accounting
      └── CUBLAS_WORKSPACE_CONFIG=:4096:1
          ├── v12-memory experiment (vision + coherent DCP scratch ports)
          └── v12-cache experiment (atomic recurrent LMCache)
```

No child may be called v12 or replace the current served model ID until its own
immutable image ID and qualification receipt exist.

### Preserve unchanged in v12-rc1

- EXL3 K4 checkpoint and its revision;
- native FP8 DS-MLA 528-byte GLM NoPE records;
- TP2 / EP2 / DCP2 custom A2A;
- probabilistic built-in MTP3 and disjoint draft RNG;
- 359,000 context, `--max-num-batched-tokens 2048` scheduler-wide batch cap,
  16 request slots;
- Triton KDA prefill;
- four-image/no-video contract;
- `VLLM_MAMBA_STATE_PROTECT=16` and age `128`;
- `VLLM_MAMBA_ALIGN_CAP_LEGACY` forbidden;
- authenticated readiness, capacity receipt, rollback, and restart promotion.

---

## 6. Qualification gates

`/health` is not a liveness oracle: the known v11 wedge returned HTTP 200 while
no work progressed. Promotion requires throughput/metrics progress and request
completion.

### Static/source gates

- pin v11.1 predecessor image, overlay, and every imported source commit;
- assert the exact changed-file set and per-file hashes;
- update and pin overlay mapping/replacement counts;
- reject unmapped files, `__pycache__`, and `.pyc` artifacts;
- byte-compile every installed Python destination;
- assert all source and launcher markers, including the cuBLAS value;
- prove the v11.1 r2.1 markers remain present and their legacy/deadlock paths
  remain absent.

### Focused CPU tests

- adapt upstream Mamba sparse-cleanup cases: leading/interior/trailing null gaps,
  repeated retirement, request free, and no double free;
- adapt graph-accounting tests for estimate disabled/enabled and measured graph
  pools;
- retain all v11.1 static contract and invalid-preflight tests.

### Focused GPU tests

- run the mapped-allocation MLA query/value BMM regressions on both GPUs;
- run changed-input CUDA graph replay across every local capture size;
- compare graph output against eager output;
- run an explicit capacity/capture lane with
  `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=1` so the graph-accounting fix is
  exercised, while retaining `0` in the initial parity lane;
- run compute-sanitizer where practical and inspect Xid/SXid/MMU evidence;
- measure live/reserved memory and throughput with cuBLAS workspace enabled and
  disabled.

### Serving regression gates

- authenticated text, deterministic `temperature=0,seed=0`, and probabilistic
  sampling smoke;
- vision red-image plus the local four-image contract;
- MTP drafts/acceptance with no fallback;
- exact shared-prefix reuse;
- exact long-context retrieval near 128K, 256K, and tokenizer-sized 358,900;
- mixed 271K retrieval, long decode, and short requests;
- C1, C8, and long-prefill/decode interleave latency;
- the original v11 admission-deadlock reproducer;
- shared-prefix multi-turn churn under a concurrent whale;
- no OOM, illegal memory access, engine-core failure, preemption regression, or
  silent capacity reduction.

### Soak and promotion

Run at least 24 hours—longer than the historical ~14-hour deadlock—with unique
long prefills, continuing sessions, cache churn, vision, aborts, and mixed
concurrency. Require:

- no scheduler state with `running=0`, `waiting>0`, KV near 0%, and stalled
  throughput logs;
- no automatic restart;
- no fatal CUDA/NCCL/engine log;
- post-soak authenticated work completes;
- final idle metrics and exact boot capacity are captured.

Only then build an immutable v12 image, record its ID, switch with
`restart=no`, run authenticated readiness and acceptance, and atomically promote
it to `restart=unless-stopped`. Any failure restores v11.1.

For `v12-cache`, repeat all of the above and add startup rejection for
insufficient RAM, `/dev/shm`, memlock, L2 capacity, and L2 permissions; then
exercise cold/store/RAM restore, filesystem restore after both processes
restart, eviction pressure, aborted loads/stores, failed admission, concurrent
immutable writers, sidecar death, vLLM death, wrong-identity safe miss, exact
token attribution, and a cache soak.

---

## 7. Evidence and limitations

Local evidence:

- `scripts/inference/glm53/glm53-v11.1-upstream-core-port/`
- `scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v11.1.sh`
- `tests/glm53-flash-exl3-k4-vllm-sm120-v11.1-contract.sh`
- `benchmarks/vllm-tps/2026-09-07-glm53-v11.1-r2.1.md`

Captured upstream evidence:

- [`glm53-v12-2026-09-13-evidence/`](glm53-v12-2026-09-13-evidence/), including
  immutable patch exports for v12-rc1 PRs #694, #710, and #718
- upstream deployment page:
  <https://github.com/local-inference-lab/rtx6kpro/blob/74485e5262c31ddeaef7aae0aec9879bcef0d5cb/models/glm-5.3-flash-spark-tp2.md>
- source recipe:
  <https://github.com/local-inference-lab/blackwell-llm-docker/tree/b91127b1a54997d9a67a8aead8c1acf97b194f7b/recipes/glm53>

Limitations:

- Spark TP2 remains research-only and does not include an extended soak.
- Its 1M text transfer tests validate attribution/output equality, not general
  long-context language quality.
- Its exact multimodal request endpoint cannot be restored from LMCache.
- The reported R1 195.7 tok/s used a different physical pair and VRAM +6000;
  it is not a v12 performance target.
- No performance or memory gain transfers to EXL3 until measured on the local
  candidate.
