# GLM-5.3 Flash NVFP4 multimodal TP2 on vLLM/SM120 v2 (2026-08-27)

## Status

**Prepared, not pulled, not downloaded, not booted, and not qualified.** This profile does
not replace or stop Qwen, DeepSeek, or Muse merely by being installed. It is a 262,144-token,
text+single-image TP2 qualification candidate for the exact requested checkpoint.

v2 supersedes the unbuilt v1 design. Research after v1 found that upstream vLLM PR #53969
is incomplete for the released GLM config: `index_topk=2048` plus `index_kpool=4` produces
a 2176-wide candidate buffer, while the SM120 FlashInfer kernel is instantiated at 2048.
The v2 artifact carries the additional candidate-width, page-alignment, prefill-routing,
and empty-row fixes already exercised on RTX PRO 6000.

## Immutable identities

| Component | Identity |
|---|---|
| Checkpoint | `local-inference-lab/GLM-5.3-Flash-NVFP4` |
| Checkpoint revision | `520de24eabf507659eaef7c70f14fd584527facc` |
| Checkpoint manifest SHA-256 | `98ce8b429c9e8959aa3eccd0a79dc52a6e7901ea0fae1451323d887a1590e9ca` |
| Official vLLM base | `vllm/vllm-openai:glm53-flash@sha256:2c6da6c6f16ed15c91e412d896dba13701f25fe1861eaec9ddaa4db34d1d21c4` |
| SM120 overlay image | `cstechdev/vllm:glm53-flash-nope-sm120-cu130-20260826-r1@sha256:0bd709e80b8ff13ae5de8f7d7f708a499fade3a26970d56afb1be2ff3860fde5` |
| Overlay image config | `sha256:136b60b807401679fb529b5fc99ce86c8ec291b38ef01c75801c76696e995be3` |
| Overlay source | `chriswritescode-dev/glm-5.3-flash-sm120@dc6b4fdd68005ab6ee0b1decfa4ebb8384393d37` |
| Overlay source tree | `b376906774010561e22fa8e234937764f83fd221` |
| Container | `glm53-flash-nvfp4-vllm-sm120-v2` |
| Served model | `glm-5.3-flash-nvfp4` |
| Port | 8000, exclusive with Qwen and DeepSeek |

The overlay is third-party, not an official vLLM release. Registry inspection shows that
its root filesystem is the exact pinned official base plus two additional layers. The pull
script verifies that prefix relationship, the repository/config digests, native GLM and
ModelOpt-mixed registration, and the exact NoPE/2176/page-alignment source markers before
accepting it. This is stronger artifact provenance than a mutable tag, but it is not
upstream release qualification.

## What current TP2 research actually proves

### Available fixes

1. [vLLM #53906](https://github.com/vllm-project/vllm/pull/53906) supplies native
   `Glm5NextForConditionalGeneration`, multimodal processing, KDA, kpool sparse MLA,
   MTP, ModelOpt mixed precision, and the GLM parsers. It remains open.
2. [vLLM #53963](https://github.com/vllm-project/vllm/issues/53963) isolates the RTX PRO
   6000 SM120 failure: stock vLLM reaches weight load, then NoPE (`qk_rope_head_dim=0`)
   fails the DeepSeek-shaped 64-wide RoPE cache/kernel contract.
3. [vLLM #53969](https://github.com/vllm-project/vllm/pull/53969) adds symmetric zero
   padding for NoPE and reports TP2, 384K, text, vision, tools, and MTP on two DGX Spark
   SM121 systems. It does **not** by itself solve this checkpoint's 2176-wide kpool buffer.
4. `chriswritescode-dev/glm-5.3-flash-sm120` adds the missing released-config fixes:
   2048-capacity candidate selection, valid-length handling, prefill routing, SM120
   DeepGEMM 64-page alignment, and zero-row handling. Its pinned image was validated on
   4x RTX PRO 6000 SM120 with multimodal input, MTP, and 524K context.
5. The independent `0xSero/glm-5.3-flash-sglang-sm120` bundle validates a different
   SGLang implementation on 4x RTX PRO 6000 at native 1M context. It is useful hardware
   evidence, but not evidence for this vLLM TP2 profile or this exact checkpoint revision.

### What remains unproved

There is no public end-to-end report for **this exact 184.5-GiB mixed ModelOpt checkpoint
on 2x RTX PRO 6000 SM120**. The available TP2 report uses two 121.6-GiB unified-memory
DGX Sparks; the available RTX PRO report uses four cards and a larger BF16/FP8 checkpoint.
The fixes are not intrinsically TP4-only, and the underlying RTX PRO kernel probes include
32 heads/rank (the TP2 geometry), but capacity and full-model correctness still require an
attended local boot.

## Why 262K plus image support is the v2 envelope

The checkpoint has native 1,048,576 context and multimodal assets. Its index references
`198,042,331,512` tensor bytes; the complete 53-record download is 184.49 GiB. With MTP
disabled, target+vision/nonexpert/input-scale files are about 177.15 GiB, or a theoretical
88.6 GiB/card at TP2 before CUDA, NCCL, KDA state, indexer storage, and KV.

The validated overlay reports approximately 8.7 KiB/token/rank for GLM's packed sparse
MLA/indexer/KDA cache. At 262,144 tokens that is about 2.18 GiB/rank; its indexer also
reserves roughly 1.3 GiB/rank after profiling. That is tight but materially more plausible
than 524K or 1M in the roughly 7-GiB/card theoretical remainder. v2 therefore uses:

- full multimodal model, one image per prompt, video disabled;
- 262,144-token maximum context;
- TP2, no MTP, eager mode, no prefix caching;
- ModelOpt mixed weights with Marlin NVFP4 MoE for the conservative correctness path;
- packed `fp8_ds_mla` KV and forced SM120 sparse MLA;
- eight sequences, 2,048 batched tokens, BF16 KDA/Mamba state;
- `--no-enable-flashinfer-autotune`;
- no CPU offload by default.

`MAX_NUM_SEQS=8` is both a scheduling and memory invariant. It prevents the observed
`max_num_seqs (1024) exceeds available Mamba cache blocks (512)` startup failure. The
launcher rejects 9+ before Docker/filesystem access.

## Preparation only

All commands below run on `desktop`. None launches inference unless explicitly shown in
the later qualification section.

### 1. Storage and current-service record

```bash
cd ~/.dotfiles
df -h /models
zfs list -o name,used,avail,mountpoint | grep /models
bash scripts/inference/glm53/switch-glm53-profile-v2.sh status
docker ps --format '{{.Names}}\t{{.Image}}\t{{.Status}}'
```

Reserve at least 220 GiB for the model plus Docker/cache space.

### 2. Download and verify the exact checkpoint

```bash
bash scripts/inference/glm53/download-glm53-flash-nvfp4-v1.sh
docker logs -f glm53-nvfp4-v1-model-dl
bash scripts/inference/glm53/verify-glm53-flash-nvfp4-v1.sh
```

The downloader is resumable. `.download-complete` is written only after all 53 files pass
size and SHA-256 verification. The verifier re-reads about 184.5 GiB and checks architecture,
1M native context metadata, ModelOpt `MIXED_PRECISION`, both NVFP4/MXFP8 groups, and indexed
tensor bytes. A user-writable ZFS destination can avoid interactive sudo during remote
qualification; use the same path for every later step:

```bash
DEST="$HOME/models/GLM-5.3-Flash-NVFP4-v1" \
  bash scripts/inference/glm53/download-glm53-flash-nvfp4-v1.sh
MODEL_HOST="$HOME/models/GLM-5.3-Flash-NVFP4-v1" \
  bash scripts/inference/glm53/verify-glm53-flash-nvfp4-v1.sh
```

When using that layout, export the same `MODEL_HOST` while invoking preflight or the
switcher.

### 3. Pull and prove the image without starting a GPU service

```bash
bash scripts/inference/glm53/pull-glm53-flash-vllm-sm120-v2-image.sh
```

This pulls images and runs a no-GPU Python source probe; it does not mount the checkpoint,
use GPUs, bind a port, or start an inference server.

### 4. Static preflight

```bash
bash scripts/inference/glm53/run-glm53-flash-nvfp4-vllm-sm120-v2.sh --preflight
```

Preflight validates the local image ID and fully re-hashes the checkpoint. It does not
query/stop GPUs or create a server container. Stop here after preparation.

## Attended TP2 qualification (explicitly deferred)

Only in a planned window:

```bash
sudo systemctl stop display-manager
nvidia-smi
STARTUP_TIMEOUT_SECONDS=3600 \
  bash scripts/inference/glm53/switch-glm53-profile-v2.sh start
```

The switcher performs preflight before stopping anything, transactionally quiesces all
repository-owned GPU profiles, launches GLM, requires `/health` plus authenticated
`/v1/models`, and restarts the previous container set if launch/acceptance fails. It keeps
bearer tokens out of argv.

Required startup evidence:

- TP=2 and exactly two RTX PRO 6000 Blackwell SM120 cards;
- `modelopt_mixed` and Marlin selected with no missing target/vision weights;
- `FLASHINFER_MLA_SPARSE_SM120`, `fp8_ds_mla`, NoPE rope-pad path;
- top-k capacity 2048, not a 2176 shape assertion;
- storage block/page alignment accepted (no DeepGEMM 32-vs-64 assertion);
- `max_num_seqs=8`, no Mamba/KDA block error;
- positive KV capacity of at least 262,144 tokens/rank;
- no OOM, Xid, NCCL, restart loop, `locklock...` output, or illegal memory access.

If capacity fails, preserve logs. An attended A/B may try `CPU_OFFLOAD_GB=4`, then 8;
never call that the same profile in benchmark records. If 262K cannot fit without offload,
create a separately versioned lower-context launcher rather than silently changing v2.

## Acceptance matrix

### Auth and model identity

```bash
key=$(<~/.config/glm53/api-key)
curl --fail --silent --show-error --config - <<EOF | jq .
url = "http://127.0.0.1:8000/v1/models"
header = "Authorization: Bearer $key"
EOF
```

The sole served ID is `glm-5.3-flash-nvfp4`. Wrong/absent credentials must receive 401/403
for `/v1/*`. vLLM does not protect every non-inference route; do not expose port 8000 to
the Internet.

### Text and reasoning

Test `low`, `high`, and `max` reasoning on deterministic prompt sets. Confirm reasoning is
separated into `reasoning_content`, multi-turn continuations preserve required reasoning,
and low is materially shorter than max. The checkpoint template explicitly recognizes low
and high; all other values become max, so Pi exposes only those three levels.

### Tools

Test forced, automatic, absent, parallel, malformed-argument, and tool-result continuation
cases. `glm47` must emit OpenAI-compatible `tool_calls`, never JSON-like prose.

### Images

Use a small PNG/JPEG, a detailed document/screenshot, and a deliberately invalid image.
Verify the model describes visual facts not present in text, performs OCR/grounding, rejects
the invalid payload cleanly, and survives a multi-turn image conversation. Confirm a second
image is rejected by the one-image profile limit and video is rejected. Compare at least ten
image prompts against a trusted GLM-5.3 endpoint; a successful HTTP response alone is not
vision qualification.

### Long context and TP2

Run known-answer retrieval at 8K, 32K, 128K, 200K, and 262K, both text-only and with one
image where practical. Then run concurrency 1/2/4/8; request 9 must queue, not crash. Include
multi-turn shared-prefix tests despite prefix caching being disabled, because KDA/indexer
state corruption can still appear across turns.

Record TTFT, prefill/decode throughput, memory, power, KV capacity, and any offload. Run at
least 100 coding/tool/image prompts and an 8-hour mixed 262K soak. Inspect `journalctl -k`
and `nvidia-smi` for Xid events.

## Stop and rollback

```bash
bash scripts/inference/glm53/switch-glm53-profile-v2.sh stop
# Restart the prior Qwen v4 or DS4 r18 profile with its existing versioned path.
sudo systemctl start display-manager
```

Never remove Qwen/DS4 checkpoints, caches, images, env files, or containers during GLM
qualification.

## Promotion rules

Promotion requires clean cold boot/restart, TP2 capacity at 262K without undeclared offload,
text/reasoning/tool/image correctness, eight-way concurrency, long-context retrieval, an
8-hour soak, and clean Xid/kernel logs. Record the checkpoint revision, image/config digest,
driver, firmware, GPU serials, exact flags, and benchmark artifacts.

524K and native 1M, MTP, multiple images/video, CUDA graphs, prefix caching, and more than
eight sequences are separate memory/kernel contracts and require new versioned profiles.
Until qualification, Pi catalog visibility means explicit test availability—not production
default.
