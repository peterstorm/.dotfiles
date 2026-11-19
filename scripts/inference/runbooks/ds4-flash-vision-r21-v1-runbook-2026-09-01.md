# DeepSeek V4 Flash Vision — Infernal Invocation r21 v1

**Status:** immutable Python overlay built; target and fixed-K6 DSpark qualified on the workstation; running with `restart=no`

## Immutable identity

| Item | Value |
|---|---|
| Checkpoint | `deepseek-ai/DeepSeek-V4-Flash-Vision-Exp@86f746b36186f0e567729a5c06a8c918caba82a9` |
| Checkpoint size | 167,831,846,872 bytes in the revision tree; 48 weight shards |
| Base image | `voipmonitor/vllm@sha256:ed525dec1a4ac5cf7f19c7cf2fb29661389d71a29ff8de91aade8e6785e10291` |
| Base image ID | `sha256:24f19364f0c6a991422bcb436a3e07ab52e66e0eb241aba0b9490e95476a8e3f` |
| vLLM integration tree | `d6cf36ae0dc30d48fd656a3c34a353ec62074922` |
| Overlay patch | `sha256:800f7ad21304e8be633428ad0db4ef49839b75bff84071b84ef9f44c78042469` |
| Derived image | `sha256:f5b3c70a39613bd2459bc186068e8e67720cf69b407a7c91b12a0585bf0ed183` |
| Served model | `deepseek-v4-flash-vision` |

The checkpoint had originally been staged from later revision `e46e16bf…`.
A complete Hugging Face tree comparison proved that its weights, configuration,
tokenizer, and model index are identical to `86f746b3…`; the later revision only
adds evaluation YAML and changes README. The downloader then re-resolved the local
tree against the required revision and installed the exact revision marker without
re-downloading 148 GiB of identical weights.

## What the overlay changes

The derived image preserves Infernal's NVIDIA language model, B12X attention and
MoE kernels, DGLIN linear path, InstantTensor loader, FP8 compressed MLA cache,
TP2, and DSpark implementation. It changes Python source only, behind exact
base-source and final-source SHA-256 manifests.

The overlay:

1. moves `DeepseekV4ForCausalLM` to the multimodal registry and wraps the
   platform-selected implementation without replacing it;
2. extends `DeepseekV4Config` with the checkpoint's vision fields while leaving
   `vision_n_layers=None` text checkpoints valid;
3. adds the checkpoint-compatible full-attention ViT, 2-D RoPE, RMSNorm,
   gated MLP, and 3x aligner under exact `vision.*` and `aligner.*` names;
4. implements the official RGB/resize/pad/normalize/patchify and position-dependent
   N-layout algorithm for `<｜deepseek_image｜>`;
5. admits only the five synthetic IDs `vocab_size + [0,4]`, masks them before
   text lookup, installs learned START/PAD/NEWLINE/END embeddings, and merges
   aligned features only at IMAGE positions;
6. loads `bias_vl` and text correction bias on target and draft gates and routes
   synthetic tokens with `scores + bias_vl`, preserving text hash/score routing,
   renormalization, shared experts, EPLB, and `int32` B12X IDs;
7. threads raw IDs into sparse-attention metadata and builds paged image-visible
   indices disjoint from ordinary 128-token causal SWA;
8. evaluates the ordinary SWA/compressed partition and image-only partition with
   natural-log LSEs, includes the sink only in the first, and merges by exact
   `logaddexp` weights;
9. rewinds local prefix hits that end inside media and enforces full media spans
   before consulting the encoder cache; and
10. sanitizes both draft-model embedding paths and DSpark's direct Markov-anchor
    lookup while retaining raw IDs for MoE routing.

## Qualified runtime

```text
TP_SIZE=2
DCP_SIZE=1
MODE=dspark
DSPARK_DEPTH_MODE=fixed
DSPARK_TOKENS=6
BACKEND=b12x-a8-dglin
VLLM_USE_B12X_MHC=0
MAX_MODEL_LEN=312000
MAX_NUM_BATCHED_TOKENS=4096
MAX_NUM_SEQS=8
GPU_MEMORY_UTILIZATION=0.975
PREFIX_CACHE=1
EXTRA_VLLM_ARGS="--disable-chunked-mm-input --default-chat-template-kwargs.reasoning_effort=max"
```

K6 is required rather than merely aggressive. The checkpoint declares
`dspark_block_size=5` and has three predictor layers. K3 fails the minimum block-size
invariant; K5 fails the `num_speculative_tokens % n_predict == 0` invariant. Six is
the smallest legal depth.

The target-only profile remains available with:

```bash
SERVING_MODE=dspark-mtp0 DSPARK_TOKENS=6 \
  scripts/inference/deepseek/run-ds4-flash-vision-r21-v1.sh
```

## Operations

```bash
# Idempotently establish the exact checkpoint revision
scripts/inference/deepseek/download-ds4-flash-vision.sh

# Rebuild and prove the immutable image
scripts/inference/deepseek/build-ds4-flash-vision-r21-image.sh
scripts/inference/deepseek/pull-ds4-flash-vision-r21-v1-image.sh

# Transactional start/status/stop
scripts/inference/deepseek/switch-ds4-flash-vision-r21-v1.sh status
scripts/inference/deepseek/switch-ds4-flash-vision-r21-v1.sh start
scripts/inference/deepseek/switch-ds4-flash-vision-r21-v1.sh stop
```

The switcher preflights image and checkpoint identities, stops repository-owned
profiles, launches at `restart=no`, requires health, authentication, exact model ID,
and zero restarts, then runs text and generated-red-image probes. A failed launch
quiesces the candidate and restarts the prior profile set.

Pi model selector:

```bash
pi --model desktop-vllm/deepseek-v4-flash-vision:max
```

## Qualification result

The K6 runtime loaded 81.86 GiB per GPU, captured target, DSpark, and DFlash
context-KV graphs through 56 rows, exposed 559,184 KV tokens, and reported 1.79x
concurrency at 312,000 tokens.

It passed:

- red, blue, and maximum-layout green images (117 and 349 multimodal tokens);
- image-byte sensitivity and correct color identification;
- required tool calling and strict JSON-schema output;
- 120,135-token vision prefill in 20 seconds and a 120,064-token cache hit in 2 seconds;
- 300,135-token near-limit vision prefill in 35 seconds and a 300,032-token cache hit
  in 2 seconds;
- target-only decode at 126.1 tok/s and fixed K6 at 171.0 tok/s on the same 1,024-token
  streaming probe, a 35.6% decode-rate increase;
- K6 activity at all six positions; after the mixed soak, 358,565 of 764,580 draft
  tokens were accepted (46.9%, 2.81 accepted tokens per target step);
- a 1,801-second soak with 962 four-request batches, 3,848 requests, zero API/schema
  errors, zero CUDA/index/Xid/traceback matches, and zero restarts; and
- a complete manual stop/start followed by text and vision probes, still at zero
  Docker restarts.

Temperature-zero responses remained semantically stable but not byte-identical:
five cached repetitions all identified red, while wording/reasoning hashes differed.
Treat repeatability as a separate model/runtime characteristic, not a vision safety
failure.

The detailed receipt is
[`2026-09-01-ds4-flash-vision-r21-v1.md`](../../benchmarks/vllm-tps/2026-09-01-ds4-flash-vision-r21-v1.md).
