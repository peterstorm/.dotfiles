# Qwen3.8 Flash-Next FP8 vLLM TP2 + PLE RAM offload v1

**Status:** pinned image pulled and statically verified; checkpoint download and runtime boot not started.

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
| Image config | `sha256:bd995759b5b8ac51062e04c9e4d7c91c382d1ba377bb787e24dca2ccb39925e9` |

The mutable tag is never used by the launcher. The 172.82 GiB serving manifest includes all
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
build or merged release exists. A GPU-assisted `vllm serve --help=all` probe succeeded on the
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
| Prefix caching | Enabled |
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

Pull and prove the special image:

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

## Qualification gates

1. Prove unauthenticated requests fail and authenticated `/v1/models` returns only
   `qwen3.8-flash-next-fp8`.
2. Confirm logs show PLE CPU offload, 128 N-gram shards, TP2, FP8, QSA/GDN, and MTP3—not a silent
   GPU-resident or non-speculative fallback.
3. During load and warmup, monitor `free -h`, process RSS, cgroup OOM events, GPU VRAM, Xids, and
   kernel logs. Fail if swap thrashes or available RAM approaches zero.
4. Qualify deterministic text, code, multilingual, reasoning levels, streaming, and preserved
   reasoning history.
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
