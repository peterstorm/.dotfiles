# Qwen3.8 Flash-Next FP8 vLLM TP2 + PLE RAM offload v1

**Status:** checkpoint and deterministic-QSA image verified; stock v1 was rejected for non-deterministic prefill. Exact-top-k3 with prefix caching disabled was deployed and passed the live 10-run prefill gate on 2026-08-29. Experimental, not promoted over the Qwen3.8-27B rollback.

This is an isolated experimental profile for the official Qwen3.8-Flash-Next FP8 checkpoint.
It does not replace the qualified Qwen3.8-27B launchers. Flash-Next, Qwen 27B, DeepSeek, and
GLM are mutually exclusive on port 8000.

## Immutable identities

| Artifact | Identity |
|---|---|
| Checkpoint | `Qwen/Qwen3.8-Flash-Next-FP8@970c569adaca6b35532111fd6b27351b2baefe50` |
| Serving manifest | 144 files, 185,563,783,486 bytes, SHA-256 `7d02680af7388f69f23d78a5db2e2c9f5bc536ba7a6b264068a9b2bb6b85157e` |
| Indexed tensors | 152,089 tensors, 185,502,232,570 bytes |
| Image index | `vllm/vllm-openai:qwen38-flash-next@sha256:fc120ece0a388cc0aa1caad4a9f1cd92113484ab7ec2fd0efadd62585be05bf8` |
| AMD64 image | `vllm/vllm-openai@sha256:0aea30240f3e3d9ffae8526643950e170eb5fa07fc427016a9dd90892afa2aa3` |
| Base image config | `sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9` |
| Deterministic-QSA image config | `sha256:32a26fee4a4225b565017c36ce4f6589d716d608b59bbaa93c712a31a8433a32` |
| QSA patch | DocAI evals `522430ac96a4847583c3b0069757338cf27ab7ff`, patch SHA-256 `b2d642b9a54c504d8ad109888767cbbf2eda760f8c4edda6b12732ac22c174e4` |
| Patched `qsa.py` | SHA-256 `79d13ab4a3805bd568e3b930cd0cc193fbf5997403f9d4e809838193c14204dc` |

The mutable tags are never used by the launcher. It starts the exact deterministic-QSA image config. The derived image proves the 32-layer base rootfs prefix, adds only the patch layers, and fails its build if either the original `qsa.py` or vendored patch hash differs. The 172.82 GiB serving manifest includes all
131 weight shards and the complete tokenizer, multimodal processor, template, metadata, README,
and license surface.

## Model and memory shape

The checkpoint declares `Qwen4ExpForConditionalGeneration` with:

- 125B backbone parameters, 6B active per token;
- a 51.2B-element trigram embedding table;
- one 4B MTP layer;
- 48 hybrid QSA/Gated-DeltaNet layers;
- 512 routed experts with 10 selected per token;
- native 262,144-token context;
- a vision encoder and image/video processors;
- dynamic fine-grained FP8 with 128×128 blocks.

The 128 N-gram tensors span checkpoint shards 5–37. At one FP8 byte per element the table is
47.68 GiB; those shards occupy 48.67 GiB including adjacent tensors. Keeping that table on the
GPUs would leave insufficient space for vLLM, state caches, graphs, and KV cache on 2×96 GiB.
`VLLM_PLE_CPU_OFFLOAD=1` is therefore mandatory and not exposed as a launcher toggle.

The desktop has about 91 GiB total host RAM. The launcher requires at least 60 GiB available
before boot so the 47.68 GiB table plus offload worker and runtime have margin. This is tight;
monitor host RSS, page cache, swap, and OOM events during qualification. Do not run ComfyUI or
other memory-heavy jobs concurrently.

## vLLM support and provenance caveat

Flash-Next model support and PLE RAM offload are not in a released vLLM version at preparation
time:

- vLLM PR #53896 (`Qwen4Exp` model support) is open;
- vLLM PR #53899 (PLE CPU offload) is open;
- the PR reports FP8/BF16 RAM-offload validation on GB200 with TP2/TP4 and DP4+EP4;
- issue #53960 reports a PLE-offload warmup deadlock on TP1/GB10. This profile is fixed to TP2,
  but the failure reinforces the need for local warmup and soak evidence.

The supplied image is published under the official `vllm/vllm-openai` namespace and contains
the required special build, but its OCI labels say build commit `unknown`, pipeline `local`, and
image tag `local/vllm-openai:dev`. The installed wheel reports
`0.1.dev20073+g8e685d198`, but that abbreviated commit was not resolvable in either the public
vLLM repository or the contributor fork. Its exact image digest and runtime capabilities are
provable; its source commit is not. Treat it as experimental until a reconstructible official
build or merged release exists. The stock image also contains a correctness defect on capability-family 12.x: `qsa_select_paged_tokens` excludes that family from `cooperative_topk` and routes through the racy `persistent_topk` kernel. The derived image applies the published `torch.topk(sorted=False)` plus canonical ordering repair and fixes `VLLM_QSA_EXACT_TOPK=3`; see [the DocAI investigation](https://docai.hu/en/blog/qwen38-flash-next-nondeterministic-vllm-kernel) and vLLM issue #51782. A GPU-assisted `vllm serve --help=all` probe succeeded on the
desktop's driver and confirmed the prefix-cache, MTP, multimodal-limit, reasoning, and tool
arguments. That parses the CLI only; it does not load weights or execute model kernels.

## Initial profile

| Setting | Value |
|---|---:|
| Tensor parallelism | 2, fixed |
| Context | 262,144 tokens maximum |
| Active sequences | 4 maximum |
| GPU memory utilization | 0.94 |
| PLE/N-gram placement | Host RAM, mandatory |
| MTP | 3 draft tokens |
| Prefix caching | Disabled; cold/warm output equivalence failed the repaired-image gate |
| QSA selection | Exact `torch.topk` + canonical ordering (`VLLM_QSA_EXACT_TOPK=3`), mandatory |
| FlashInfer autotune | Disabled |
| Tool parser | `qwen3_coder` |
| Reasoning parser | `qwen3` |
| Multimodal | At most one image; video disabled for initial qualification |
| Host port | 8000 |

The supplied Compose used port 8118. This repository uses port 8000 so Pi and the transactional
profile switcher retain one stable endpoint. The cache and temporary paths are local
operator-owned directories rather than another user's absolute paths.

## Download and verify

Do not start this 172.82 GiB transfer while another large model transfer needs bandwidth unless
that contention is intentional:

```bash
cd ~/.dotfiles
DEST="$HOME/models/Qwen3.8-Flash-Next-FP8-v1" \
  bash scripts/inference/qwen38/download-qwen38-flash-next-fp8-v1.sh

docker logs -f qwen38-flash-next-fp8-v1-model-dl
```

The downloader is revision-pinned, resumable, retries transient Xet response failures, and writes
`.download-complete` atomically only after every file passes size and SHA-256 verification. It
also verifies architecture, context, FP8, MTP, license, tensor census, and all 128 N-gram shards.

Re-run verification independently:

```bash
MODEL_HOST="$HOME/models/Qwen3.8-Flash-Next-FP8-v1" \
  bash scripts/inference/qwen38/verify-qwen38-flash-next-fp8-v1.sh
```

Pull the special base, build the one-file deterministic-QSA overlay, and prove the exact base prefix, patch, resulting source, and derived image:

```bash
bash scripts/inference/qwen38/pull-qwen38-flash-next-vllm-v1-image.sh
```

## Preflight and attended boot

Preflight hashes the complete checkpoint but does not touch GPUs or allocate the N-gram table:

```bash
MODEL_HOST="$HOME/models/Qwen3.8-Flash-Next-FP8-v1" \
CACHE_HOST="$HOME/.cache/qwen38-flash-next-fp8-v1" \
  bash scripts/inference/qwen38/run-qwen38-flash-next-fp8-vllm-v1.sh --preflight
```

Attended startup:

```bash
systemctl stop comfyui.service
nvidia-smi
free -h

MODEL_HOST="$HOME/models/Qwen3.8-Flash-Next-FP8-v1" \
CACHE_HOST="$HOME/.cache/qwen38-flash-next-fp8-v1" \
  bash scripts/inference/qwen38/switch-qwen38-flash-next-profile-v1.sh start

docker logs -f qwen38-flash-next-fp8-vllm-v1
```

The launcher fails closed on checkpoint identity, image identity, GPU count/type/memory/power,
host RAM availability, cache access, and port conflicts. API credentials are supplied through a
private env file and never appear in process arguments.

## Local qualification receipt — 2026-08-29

The first preflight found that the pinned `LICENSE` uses CRLF. Its bytes matched
the immutable manifest, but the verifier compared the first line as LF-only.
The verifier now removes exactly one trailing carriage return before checking
`Qwen Community License 1.0`; all 144 manifest records and metadata gates then
passed.

Attended boot used both GPUs with ComfyUI inactive:

- container start to authenticated readiness: approximately 312 seconds;
- PLE CPU offload registered one layer and both TP workers;
- model allocation: 64.58 GiB per worker;
- peak activation / CUDA graphs: 1.03 / 0.29 GiB per worker;
- KV allocation: 21.72–21.84 GiB per worker;
- logical KV capacity: 1,459,504 tokens, or 5.57× at 262,144;
- authenticated model id exact; unauthenticated discovery returned 401;
- a single-response greedy text gate, SSE `[DONE]`, tool JSON, and generated-red-PNG vision
  gates passed; the later repeated-logprob probe invalidated the original determinism claim;
- C1: 172.1 decode tok/s; C4: 518.3 aggregate end-to-end tok/s;
- MTP3 effective acceptance length: 2.61 C1 and 2.51 C4;
- fresh 249,336-token retrieval: exact marker in 23.059 seconds; identical
  prefix-cached replay in 0.743 seconds with 246,400 cache-hit tokens;
- zero preemptions, OOMs, restarts, and observed Xids.

Host memory remains the operational constraint. After startup the 91 GiB host
reported 29 GiB available while zram held 43.6 GiB logical data compressed to
34.6 GiB. The PLE worker was roughly 7.6 GiB resident and 41.2 GiB swapped.
There was no sustained zram churn during idle or qualification, but ComfyUI and
other memory-heavy workloads must remain stopped. See
`benchmarks/vllm-tps/2026-08-29-qwen-flash-next-fp8.md` for full measurements.


## Determinism incident and repair — 2026-08-29

The stock deployment was rejected after the published prefill probe was applied. Its exact vLLM
build (`0.1.dev20073+g8e685d198`) and Blackwell family-12 path call
`torch.ops._C.persistent_topk`; no exact-top-k overlay was present. Ten identical greedy requests
(`temperature=0`, `max_tokens=1`, `top_logprobs=20`) against the 3,205-token published T3-01
fixture produced ten distinct top-20 vectors. Other Pi sessions were active during that first
measurement, so it was not used as the sole kernel attribution; the installed affected source
path and absent repair independently establish that the deployment was vulnerable.

The remediation is a two-layer image derived from the exact base. Its Dockerfile hash-gates the
original source and the vendored upstream experiment patch, applies with zero fuzz, hash-gates the
result, syntax-compiles it, and sets mode 3. The launcher pins the resulting image config and
reasserts mode 3. The transactional switcher now runs the same ten-request probe on an idle engine
and rolls back if even two vectors differ.

The first repaired-image gate still produced three vectors: cold run 1, partially cached run 2,
and one stable vector for runs 3–10. Prefix caching was therefore disabled as another
correctness requirement; the original 249K cached-replay latency result no longer applies.

After restart without prefix caching, all ten runs were byte-identical from the first request:
first token `We`, logprob `-0.36722856760025024`, top-20 SHA-256
`3e490b4aedbdcaeac14f5e79af620c4ac210b305bbf13ccd9fcf025f5145b845`.
A second independent ten-run gate produced the same vector. Three complete greedy T3-01
responses were also byte-identical (message SHA-256
`5b95afe5bcfbbb12002b3d8cee861ec5616b8da92c6f1e637f27a6db5382917f`, 1,706 completion
tokens each) and returned the correct `2026-11-10` / `munkanap` JSON.

This repair addresses the QSA selected-context race only. MTP3 remains enabled because disabling
it substantially reduces decode throughput and does not remove the model's greedy-thinking
repetition tendency. MTP is not promised to be output-equivalent to plain greedy; parity and a
reasoning-loop retry policy remain separate promotion gates.

## Qualification gates

1. Prove unauthenticated requests fail and authenticated `/v1/models` returns only
   `qwen3.8-flash-next-fp8`.
2. Confirm logs show PLE CPU offload, 128 N-gram shards, TP2, FP8, QSA/GDN, and MTP3—not a silent
   GPU-resident or non-speculative fallback.
3. During load and warmup, monitor `free -h`, process RSS, cgroup OOM events, GPU VRAM, Xids, and
   kernel logs. Fail if swap thrashes or available RAM approaches zero.
4. Require `probe-qwen38-flash-next-determinism.sh` to produce one byte-identical top-20
   vector across ten idle-engine runs; then qualify code, multilingual, reasoning levels,
   streaming, and preserved reasoning history.
5. Exercise single, malformed, parallel, and multi-turn `qwen3_coder` tool calls.
6. Qualify one-image prompts separately; video remains disabled.
7. Measure MTP acceptance, C1/C4 TTFT, prefill, decode, queueing, and output parity with MTP off.
8. Test 32K, 128K, and 262K retrieval/coherence; capacity allocation alone is not correctness.
9. Restart twice to prove offload worker cleanup and shared-memory/cache idempotency.
10. Complete an attended thermal, memory, and correctness soak before promotion.

## Rollback

The switcher automatically restarts the previously running repository-owned inference profile if
Flash-Next launch or authenticated readiness fails. Manual rollback:

```bash
docker rm -f qwen38-flash-next-fp8-vllm-v1 2>/dev/null || true
systemctl start comfyui.service
```

The existing Qwen3.8-27B checkpoint, images, caches, launchers, and switchers are not modified.

## License

The checkpoint uses **Qwen Community License 1.0**, not a standard OSI license. Preserve the
bundled license. It imposes additional display requirements above stated commercial scale
thresholds and requires a separate Qwen license for specified commercial Model-as-a-Service or
AI Work Assistant use. Internal use has a stated exception; consult the actual license rather
than this summary before external or commercial deployment.
