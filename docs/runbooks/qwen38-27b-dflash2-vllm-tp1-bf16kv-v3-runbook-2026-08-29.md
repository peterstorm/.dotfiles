# Qwen3.8-27B DFlash2 vLLM TP1 BF16-KV v3 — 2026-08-29

## Purpose

Qualify the unchanged Qwen3.8-27B BF16 target and canonical DFlash2 draft on one
RTX PRO 6000 without reducing KV precision. This immutable profile uses physical
GPU0 so physical GPU1 remains available to the Nix-managed ComfyUI service.

The existing TP2 vLLM v2, SGLang, DSpark, GLM, and Muse profiles remain unchanged
rollback artifacts.

## Immutable identity

| Item | Value |
|---|---|
| Launcher | `scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-vllm-v3.sh` |
| Container | `qwen38-27b-bf16-dflash2-vllm-v3` |
| Target | `Qwen/Qwen3.8-27B@1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0` |
| Draft | `incoai/Qwen3.8-27B-DFlash2@dedf8df68adfb1afeaf7b7480c0a0243108177b4` |
| vLLM image | `vllm/vllm-openai:nightly-a9a17e7095a66ef6c6685a1c7ddd657781a78d3c` |
| Image digest | `sha256:3578c1fa6a9676e1de068b9d75c777cc865d251fadfbe6175ae82278739c6674` |
| Embedded source | `a9a17e7095a66ef6c6685a1c7ddd657781a78d3c` |
| Cache | `/models/vllm-cache/qwen38-bf16-dflash2-tp1-bf16kv-v3` |
| Private env file | `~/.config/qwen38/vllm-dflash2-tp1-bf16kv-v3.env` |

## Fixed profile

```text
physical GPU:             0
ComfyUI physical GPU:     1
tensor parallelism:       1
target weights:           BF16
draft weights:            BF16
KV cache:                 BF16 (`auto` with BF16 target)
GDN state:                FP32
context:                  262144
max sequences:            8
max batched tokens:       4096
GPU memory utilization:   0.92
DFlash2 speculative depth: 7
attention backend:        FlashInfer
prefix cache:             enabled
chunked prefill:          enabled
```

GPU selection is deliberately not configurable. Fewer launcher states prevent an
operator from silently placing Qwen on physical GPU1, where it would conflict
with ComfyUI. When ComfyUI is active, the launcher verifies that systemd pins it
to `CUDA_VISIBLE_DEVICES=1`; otherwise it fails closed.

## Launch and rollback

Pull and verify the shared immutable image:

```bash
bash scripts/inference/qwen38/pull-qwen38-dflash2-vllm-v2-image.sh
```

After explicitly stopping the inference family currently owning port 8000:

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v5.sh dflash2-vllm-tp1-bf16kv
```

The switcher's same-engine fallback is the official TP2 vLLM v2 profile:

```bash
bash scripts/inference/qwen38/switch-qwen38-backend-v5.sh dflash2-vllm-official
```

GLM and Qwen are mutually exclusive on port 8000. The Qwen switcher refuses to
stop an unknown inference-family container; stop GLM explicitly before the
cutover and retain it as the rollback.

## Qualification gates

1. Require authenticated `/v1/models` and served model `qwen3.8-27b`.
2. Require target architecture `Qwen3_5ForConditionalGeneration` and registered
   draft architecture `DFlash2DraftModel` in the boot log. The instantiated
   internal draft implementation identifies itself as `DFlash2Qwen3ForCausalLM`.
3. Record loaded weight memory, available KV cache memory, GPU KV capacity, and
   the maximum concurrency reported for 262,144 tokens.
4. Reject the profile if a single 262,144-token request cannot be admitted.
5. Pass text, streaming, tools, image input, shared-prefix reuse, and malformed
   tool recovery.
6. Run 32K, 108K, and 262K retrieval probes and monitor preemptions, OOMs, Xids,
   restarts, and DFlash acceptance.
7. Verify ComfyUI can start and reserve physical GPU1 without changing Qwen's
   GPU0 allocation. Do not run a large Comfy workload during Qwen boot profiling.

## Qualification receipt — 2026-08-29

The attended cold boot succeeded in 241 seconds with no restart or OOM:

```text
fixed model/runtime memory: 55.23 GiB
peak activation memory:      3.65 GiB
CUDA graph memory:           0.25 GiB
available BF16 KV memory:   28.49 GiB
GPU KV capacity:           343,968 tokens
262,144-token concurrency:    1.31x
steady GPU0 allocation:      87.7–88.5 GiB
steady GPU1 allocation:       2 MiB
```

Authenticated model discovery returned only `qwen3.8-27b`. Exact text output,
stream termination, automatic tool calling with valid JSON arguments, four-way
concurrency, and a generated red-PNG vision probe all passed. DFlash2 produced
112 draft tokens and accepted 56 in this short sample.

A cold 249,510-token retrieval prompt returned the exact buried code in 280.276
seconds. Repeating the identical prompt returned the same code in 20.629 seconds;
217,152 prompt tokens were served from the local prefix cache. This proves that
the advertised 262K context has usable headroom with BF16 KV on one card.

The long-context probes recorded three recompute preemptions despite no OOM,
restart, Xid, or remaining KV allocation after completion. The profile is
therefore an active qualification candidate, not yet a promoted replacement for
the TP2 rollback. Investigate the preemptions and run a sustained agent/tool soak
before promotion. GLM v6 remains intact as the stopped rollback container.

The initial tokenizer-only sizing probe intentionally counted a 400,026-token
string and emitted the expected overlength warning; that string was never sent
to model inference.

Static contract:

```bash
bash tests/qwen38-dflash2-vllm-tp1-bf16kv-v3-contract.sh
```
