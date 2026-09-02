# Qwen3.8 Flash-Next EXL3 5.05 bpw vLLM TP1 plan — 2026-09-02

## Status

**Integration and qualification runbook; not currently launchable.**

The selected checkpoint is the highest practical EXL3 quant for one 96 GB RTX PRO
6000, but neither stock vLLM nor the qualified Qwen FP8 v2 image can load it today.
Do not point an existing launcher at this checkpoint and do not mark the profile
benchmark-ready until every gate below passes.

Target profile name: `qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1`

The intended result is a separate immutable candidate. It must not replace or mutate:

- Qwen Flash-Next FP8 v2;
- Qwen Flash-Next v1;
- GLM v10;
- DS4 Vision r21 or DS4 r18;
- their images, checkpoints, launchers, caches, or rollback containers.

Keep the candidate at Docker restart policy `no`. Runtime readiness, benchmark
readiness, and production promotion are separate decisions.

## Selected quant

Use branch **`5.05bpw_h6_ng6`**, pinned by commit rather than by branch name.

| Quant | Non-PLE safetensor files | Gross headroom on one 97,887 MiB GPU | Decision |
|---|---:|---:|---|
| 6.05 bpw | 92.99 GiB | 2.60 GiB | Reject for a GPU-resident service; insufficient cache/runtime headroom |
| **5.05 bpw** | **78.29 GiB** | **17.31 GiB** | **Selected** |
| 4.05 bpw | 63.58 GiB | 32.01 GiB | Retain as fallback if measured vLLM allocations invalidate 5.05 |

The 36.36 GiB n-gram embedding is excluded from the GPU column because it must stay
host-side. The EXL3 metadata describes approximately 76.16 GiB of non-PLE tensor
payload; 78.29 GiB is the safer upper bound from all non-PLE safetensor file sizes.
Neither figure is a promise about vLLM's live allocation: packed-weight staging,
kernel workspaces, PyTorch/CUDA state, vision, MTP, and allocator fragmentation must
be measured on a real cold boot.

### Context estimate

Qwen has 12 QSA layers in the 48-layer target and one additional full-attention MTP
layer. At FP16, the architectural target-plus-MTP estimate is approximately:

| Aggregate cache tokens | Estimated QSA cache |
|---:|---:|
| 65,536 | 1.88 GiB |
| 131,072 | 3.76 GiB |
| 200,704 | 5.75 GiB |
| 262,144 | 7.52 GiB |

This estimate includes K/V plus QSA raw and pooled index-key planes. vLLM's actual
hybrid cache geometry remains authoritative. Start at 200,704 tokens and only attempt
262,144 after preserving a measured cold and warm memory receipt.

## Immutable source identities

| Item | Pin |
|---|---|
| EXL3 repository | `turboderp/Qwen3.8-Flash-Next-exl3` |
| Selected checkpoint revision | `7cef615f7fd3681295b68848018876dfabc336c7` |
| Selected branch label | `5.05bpw_h6_ng6` |
| Repository snapshot size | 123,252,697,337 bytes (114.79 GiB) |
| N-gram table | 39,040,193,720 bytes (36.36 GiB) |
| Non-PLE safetensors | 84,059,538,629 bytes (78.29 GiB) |
| `config.json` SHA-256 | `ac225cdd25209e3220f02e99041f31391fbac183c008f58e841b2e773e80efa8` |
| `quantization_config.json` SHA-256 | `04b309b7bc26bce905a93d419bfffc1bbd7267fcc41f16332ce922d215818f61` |
| Canonical 29-path manifest SHA-256 | `1595a848bfe4b49b2a89eb9c54b36a2f4737d3583e7b4f3e3366af569d8761aa` |
| Quant metadata | 5.05 average bpw, 6-bit head, 6-bit vision, 5-bit MTP, `mul1` codebook |
| Qwen vLLM source baseline | `e126687a9a828d513c01a07cd69f025f27d63280` |
| Qualified Qwen v2 overlay | `c0ac28980016af357df50359d301648352eebbf2` |
| Generic vLLM EXL3 reference | `local-inference-lab/vllm@6dc2f516688fe6f84c6994dcd20fddf296853a6c` |
| ExLlamaV3 runtime reference | `v1.4.5@e648f1a131365aae15920073e761a3fa5a527654` |
| Historical Infernal EXL3 extension reference | `brandonmmusic-max/exllamav3@704aefd743b390af4bd0fb429d1906f9b964c7d8` |

The checkpoint's metadata says EXL3 1.4.4, while its model card requires ExLlamaV3
1.4.5 or newer for Qwen4Exp support. Use v1.4.5 as the behavioral reference.

Before implementation, regenerate the Hugging Face tree manifest as sorted TSV rows
of `path`, `size`, and content identity (LFS SHA-256 when present, otherwise repository
blob oid). Its SHA-256 must equal the value above. Check the manifest into the eventual
release overlay; do not rely only on Git/LFS pointer files.

## Compatibility finding

There are two distinct working lineages, but no existing image contains their union:

1. The qualified Qwen FP8 v2 source implements Qwen4Exp, UVA PLE, exact deterministic
   top-k/QSA ordering, recurrent-state bounds, MTP3, and vision. It has no EXL3
   quantization backend.
2. Infernal Invocation's vLLM contains a generic modern EXL3 backend and EXL3 extension
   binding. Its qualified GLM image explicitly scopes the optimized EXL3 path to GLM
   routed experts and predates Qwen4Exp support.

The selected checkpoint also stores 74,041 ordinary model tensor records as EXL3 and
stores the PLE table in a distinct packed-trellis representation. The existing Qwen
PLE method accepts unquantized or serialized FP8 embeddings only. It will reject an
`Exl3Config`, and it cannot interpret the PLE `trellis`, `head_bias`, `head_offsets`,
`head_vocab_sizes`, and `layer_multipliers` records.

Therefore all of these shortcuts are forbidden:

- stock vLLM plus `--trust-remote-code`;
- relabeling the checkpoint as FP8;
- loading EXL3 trellis bytes through the FP8 PLE path;
- copying the GLM `_C_stable_libtorch.abi3.so` or ExLlama extension binary;
- replacing the qualified Qwen source tree wholesale with the older Infernal tree;
- silently dequantizing the full model to BF16;
- silently moving model layers to CPU and calling the result a GPU-resident TP1 profile.

## Required integration

Build from the qualified Qwen v2 source baseline and adapt source logic, not binaries.
The release overlay should be small enough that every imported seam can be reviewed
against both source pins.

### 1. Generic EXL3 quantization backend

Port the minimum compatible surface from the Infernal reference:

- `Exl3Config` discovery and complete `tensor_storage` hydration;
- vLLM quantization registry/config plumbing;
- independently quantized linear and LM-head methods;
- `RoutedExperts`/MoE loading for 512 experts, top-10 routing, and TP1;
- exact weight-name mapping through the multimodal `model.language_model` wrapper;
- eager-only enforcement while EXL3 GEMM performs shape-bucket autotuning;
- complete checkpoint-consumption accounting.

The loader must prove that every expected EXL3 tensor record is consumed exactly once
and that every unexpected or shape-incompatible record fails startup. It must not
instantiate 74,041 durable Python module objects merely because the metadata describes
individual expert projections; pack routed experts into the runtime's existing fused
ownership boundary.

### 2. Rebuild the EXL3 extension

Compile the extension from the pinned ExLlamaV3 source logic against the candidate's
exact CUDA, PyTorch, Python, C++ ABI, and SM120 target. Preserve an extension SHA-256
in the image labels and verifier.

Do not transplant the GLM extension. The prior Qwen work established that model,
source tree, PyTorch/CUDA build, and native extension form one ABI.

The GPU verifier must compare EXL3 GEMM output against a source-reference decode for
all bitrates actually present in the 5.05 checkpoint, including equal/edge values,
large row counts, repeated launches, and allocator reuse.

### 3. Add an EXL3 PLE method

The first vLLM candidate should load the 36.36 GiB packed n-gram table once into host
RAM and gather only requested packed rows. Do not dequantize the whole table and do
not map its packed `int16` rows as FP8.

Required behavior:

1. Keep PLE metadata and the packed trellis host-side.
2. Compute exact n-gram row IDs with the checkpoint offsets, sizes, and multipliers.
3. Deduplicate requested rows per batch.
4. Gather packed rows into bounded pinned staging memory.
5. Copy only gathered rows to the selected GPU.
6. Dequantize with the `mul1` codebook and per-head bias.
7. Restore original row order and feed the existing PLE convolution/state path.

This mirrors the reference semantics without introducing per-token NVMe reads into the
first qualification candidate. Disk streaming may be evaluated later as a separate
profile; it must not be silently enabled as a memory fallback.

Add a distinct fail-closed configuration marker such as
`VLLM_EXL3_PLE_CPU_OFFLOAD=1`. Existing `VLLM_PLE_CPU_OFFLOAD=1` alone must not make an
EXL3 table appear supported.

### 4. Preserve qualified Qwen behavior

Retain and re-run the Qwen v2 safety proofs:

- deterministic global lower-token-index top-k tie handling;
- canonical ascending QSA block order;
- complete/disjoint mixed GDN token partitioning;
- accepted-token bounds for causal convolution, selective state, recurrent FLA,
  sigmoid gating, and PLE;
- invalid PLE decode, prefill, and speculative state-row rejection;
- MTP position/state safety;
- one-image vision path;
- explicit prefix-cache disablement until equivalence is separately qualified.

EXL3 changes weight representation only. They must not weaken recurrent-state,
selection, cache, or multimodal invariants.

## Planned immutable artifacts

When implementation begins, create a new isolated artifact family rather than editing
the FP8 v2 files in place:

- `scripts/inference/qwen38/build-qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1-image.sh`
- `scripts/inference/qwen38/download-qwen38-flash-next-exl3-5.05bpw-v1.sh`
- `scripts/inference/qwen38/pull-qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1-image.sh`
- `scripts/inference/qwen38/run-qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1.sh`
- `scripts/inference/qwen38/switch-qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1.sh`
- `scripts/inference/qwen38/flash-next-exl3-5.05bpw-tp1-v1/`
- `tests/qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1-contract.sh`
- `benchmarks/vllm-tps/<date>-qwen38-flash-next-exl3-5.05bpw-vllm-tp1-v1.md`

Every build patch must apply with `patch --batch --fuzz=0`, have a pinned SHA-256, and
be followed by exact installed-source hashes. The final image must be addressed by
config digest, not a mutable tag.

## Download protocol

Download to a new immutable directory, for example:

```bash
REPO=turboderp/Qwen3.8-Flash-Next-exl3
REV=7cef615f7fd3681295b68848018876dfabc336c7
DEST="$HOME/models/Qwen3.8-Flash-Next-EXL3-5.05bpw-v1"

hf download "$REPO" \
  --revision "$REV" \
  --local-dir "$DEST"
```

The eventual downloader must:

- require at least 140 GiB free destination space before starting;
- use a staging directory and atomic final rename;
- reject an existing destination with a different manifest;
- validate all 29 path/size/content-identity rows;
- verify the config and quantization-config hashes above;
- require exactly 74,041 EXL3 tensor records and one PLE trellis record;
- write a local immutable receipt containing repository, revision, manifest hash,
  download time, and downloader version;
- never mutate the FP8 checkpoint directory.

## TP1 launch envelope

“TP1” here means one visible GPU and vLLM tensor parallel size one. Use physical GPU 0
for the initial profile so GPU 1 remains available as a rollback/creative resource.
Expose only GPU 0 to the container; never use `--gpus all` for this profile.

Initial conservative settings:

| Setting | Initial value |
|---|---|
| Physical GPU | 0 |
| `CUDA_VISIBLE_DEVICES` inside container | 0 |
| Tensor parallel size | 1 |
| N-gram parallel size | 1 |
| Maximum model length | 200,704 |
| Maximum sequences | 1 |
| GPU memory utilization | 0.94 for discovery boot only |
| Execution | `--enforce-eager` |
| Prefix caching | disabled |
| Chunked prefill | enabled, 2,048-token budget initially |
| KV dtype | explicit qualified Qwen/QSA dtype; never inferred from EXL3 weights |
| MTP | disabled for target-only baseline, then MTP3 |
| Multimodal cap | one image, zero video |
| Restart policy | `no` |

Expected vLLM arguments after the integration exists include:

```text
--quantization exl3
--enforce-eager
--tensor-parallel-size 1
--ngram-parallel-size 1
--max-model-len 200704
--max-num-seqs 1
--gpu-memory-utilization 0.94
--no-enable-prefix-caching
--no-enable-flashinfer-autotune
--enable-auto-tool-choice
--tool-call-parser qwen3_coder
--reasoning-parser qwen3
--limit-mm-per-prompt {"image":1,"video":0}
```

Do not add `--speculative-config` to the first target-only boot. After target-only
correctness and memory gates pass, qualify:

```text
--speculative-config {"method":"mtp","num_speculative_tokens":3}
```

The launcher must provide the API key through a mode-0600 env file, use isolated model,
vLLM, Triton, and temporary directories, set `HF_HUB_OFFLINE=1`, bind host port 8000
only after proving it is free, and use `--restart no`.

### Host-memory preflight

The packed PLE table consumes 36.36 GiB before staging and process overhead. Require:

- at least 90 GiB physical host RAM;
- at least 60 GiB `MemAvailable` before launch;
- no active memory-heavy ComfyUI workload during initial qualification;
- no sustained swap-in/swap-out during generation;
- bounded pinned staging buffers rather than pinning a second full copy.

GPU isolation does not imply host-memory coexistence. ComfyUI-on-GPU1 compatibility is
a later mixed-workload gate, not an assumption.

## Bring-up sequence

### Gate 0 — static fail-closed proof

Before loading weights:

1. Verify source, patch, native extension, image, and checkpoint hashes.
2. Prove the image contains Qwen4Exp plus generic EXL3 plus EXL3 PLE support.
3. Prove `--quantization exl3` selects `Exl3Config`.
4. Prove ordinary PLE FP8/unquantized methods reject the trellis table.
5. Prove eager mode is mandatory and CUDA graphs are disabled.
6. Parse all tensor metadata and produce consumed/unconsumed counts without allocating
   model weights.
7. Run CPU/GPU unit tests for n-gram hashing, shard boundaries, duplicate-row gather,
   trellis dequantization, malformed metadata, and bounded staging.

### Gate 1 — target-only load at 32K

Start without MTP and with a 32,768-token context. Require:

- exact image and checkpoint identity;
- one visible GPU and TP1/NP1 logs;
- zero missing, duplicate, or unexpected weights;
- PLE trellis resident in host RAM, not GPU and not interpreted as FP8;
- no CPU model-layer fallback;
- authenticated `/health` and exact `/v1/models` identity;
- zero restart, Xid, illegal-memory, OOM, or native-extension errors.

Record model tensors, non-Torch memory, activation peak, extension workspace, PLE host
RSS, pinned memory, zram, and free GPU memory.

### Gate 2 — same-checkpoint reference parity

Use ExLlamaV3 v1.4.5 only as an independent reference process, never concurrently with
vLLM on the same GPU. Compare:

- raw EXL3 linear and routed-MoE kernels across checkpoint bitrates;
- PLE row IDs and dequantized rows at first/last shard boundaries and random samples;
- target logits on fixed short, long, image-token, and hostile-boundary prompts;
- greedy selected tokens and complete-message hashes where tolerances permit;
- deterministic repeatability over ten fresh requests and a warm restart.

Compare the EXL3 candidate to the FP8 profile for semantic drift, but do not require
numerical equality across different weight formats.

### Gate 3 — MTP3

Enable MTP3 only after target parity passes. Require:

- MTP weights use their declared 5-bit EXL3 metadata rather than BF16 fallback;
- all three draft positions become active;
- accepted-token counters increase;
- invalid accepted counts and state rows fail closed;
- target-only and MTP greedy complete outputs match over the deterministic suite;
- no adjacent request can observe another request's recurrent or PLE state.

Measure target-only and MTP3 decode separately. Acceptance percentage alone is not a
speed result; record accepted drafts per step and end-to-end output tokens/s.

### Gate 4 — memory and context ladder

Run cold and warm boots independently at:

1. 32,768;
2. 131,072;
3. 200,704;
4. 262,144 only if measured headroom permits.

After the discovery boot, replace profiler-derived KV allocation with a fixed byte
budget that preserves at least 2 GiB of proven transient headroom above the largest
observed prefill/vision/MTP allocation. Cold and warm boots must expose the same cache
capacity. Never infer safe capacity from repository size alone.

Each level requires exact buried-needle retrieval, one-token and long decode, clean
request teardown, and a subsequent unrelated request proving state isolation.

### Gate 5 — protocol and semantic quality

The FP8 v2 candidate previously failed semantic promotion despite runtime safety. The
EXL3 profile must independently pass:

- exact word-count and exact-string instructions;
- ordinary and reasoning-enabled chat;
- required `get_weather`-style tool invocation with valid arguments;
- strict JSON/structured output;
- SSE content plus `[DONE]`;
- a generated solid-red image identified specifically as red;
- long-context retrieval;
- no repetitive reasoning exhaustion under the configured token cap.

A safer loader does not waive model-quality gates.

### Gate 6 — prefix-cache qualification

Keep prefix caching disabled through all earlier gates. To qualify it later, compare
cache-off and cache-on runs for:

- aligned and unaligned shared prefixes;
- PLE n-gram windows crossing the reuse boundary;
- GDN recurrent checkpoints;
- QSA index state;
- target-only and MTP3;
- cancellation, abort, and slot reuse;
- complete greedy output equality.

Any mismatch leaves prefix caching disabled in the release profile.

### Gate 7 — traffic, throughput, and soak

Record API usage-derived tokens rather than counting SSE chunks. At minimum run:

- C1 1,024-token target-only and MTP3 decode;
- 32K, 128K, and 200K prefill plus 512-token decode;
- one image request;
- sequential mixed short/long/image traffic proving state cleanup;
- concurrency two only after C1 passes and memory is re-budgeted;
- a 30-minute soak with zero HTTP/schema errors, restarts, OOMs, native faults,
  recurrent-state errors, Xid/SXid/MMU faults, or PLE staging growth.

Record TTFT, post-first-token decode, overall throughput, MTP acceptance, host memory,
NVMe reads, GPU memory, and thermals. Compare against the qualified local receipts,
not against model-card marketing numbers.

### Gate 8 — optional GPU1 coexistence

Only after standalone qualification, start the normal GPU1 workload and repeat a
bounded mixed test. Reject coexistence if host-memory pressure causes swap traffic,
PLE stalls, OOM, or latency instability. The standalone profile may remain valid even
if coexistence is rejected.

## Promotion criteria

The profile may be called **benchmark-ready** only when:

- the immutable checkpoint and source chain are reconstructible;
- all static and GPU verifiers pass;
- 200,704 context is stable on cold and warm boots;
- target-only and MTP3 deterministic/state-safety gates pass;
- text, tools, JSON, streaming, vision, and long-context semantics pass;
- fixed KV headroom survives mixed traffic and soak;
- restart count remains zero and restart policy remains `no`.

Production promotion additionally requires a controlled quality comparison against
Qwen FP8 v2, GLM v10, and the Qwen v1 rollback. A successful EXL3 boot is not a
promotion event.

## Failure attribution

Classify failures before changing quant or memory settings:

| Failure | Primary attribution |
|---|---|
| `Exl3Config` not selected | vLLM quantization registry/config integration |
| Missing `trellis`/`suh`/`svh`/`mul1` | EXL3 metadata or weight mapper |
| PLE rejected as unsupported config | missing EXL3 PLE method |
| PLE row mismatch | hash/offset/shard/gather/dequant integration |
| Native symbol/ABI error | extension build lineage |
| OOM before cache allocation | weight/runtime integration, not context length |
| OOM during cache creation | KV budget/context envelope |
| First prefill OOM after successful boot | insufficient transient headroom |
| Deterministic kernel mismatch | EXL3/QSA/MTP implementation |
| Correct kernels but poor instruction/tool/vision output | semantic model/checkpoint integration |
| Prefix-only mismatch | recurrent/QSA/PLE cache equivalence |

Do not “fix” semantic failures by weakening exact tests, and do not “fix” memory
failures by silently offloading routed experts. A CPU-MoE variant is a separate profile
with separate naming, performance evidence, and qualification.

## Transactional rollback

The future switcher must snapshot every currently running inference container and its
restart policy before stopping anything. On verifier, launch, readiness, identity, or
acceptance failure it must:

1. stop and remove only the EXL3 candidate container;
2. leave the candidate image, model, cache, and failure logs available for diagnosis;
3. restore exactly the previously running profile set;
4. verify authenticated health, model identity, restart policy, and restart count;
5. return non-zero.

Manual fallback must remain possible through the existing immutable switchers. Never
delete Qwen FP8 v1/v2, GLM v10, DS4 Vision r21, or DS4 r18 while this profile is under
qualification.

## Current decision

Proceed with **5.05 bpw**, TP1, host-resident packed PLE, eager execution, target-only
first, 200,704 initial context, fixed-KV budgeting after measurement, and MTP3 only
after parity. The 6.05 branch is out of scope for this GPU-resident profile; making it
fit would require CPU MoE/vision offload or an impractically small cache and must be
named and qualified separately.
