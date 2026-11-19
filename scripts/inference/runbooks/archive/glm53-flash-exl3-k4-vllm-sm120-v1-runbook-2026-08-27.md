# GLM-5.3 Flash EXL3 K4 vLLM SM120 TP2 v1

**Status:** checkpoint and image downloads started; not booted or locally qualified.

This is an isolated experimental alternative to the ModelOpt/NVFP4 profile. It serves the
source-available EXL3 K4 checkpoint through a custom Infernal Invocation vLLM fork. Existing
Qwen, DeepSeek, GLM NVFP4, and ComfyUI assets remain rollback paths.

## Immutable identities

| Artifact | Identity |
|---|---|
| Checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Serving manifest | 135 root serving files, 175,715,798,014 bytes, SHA-256 `96bb2e8ebdc287233c142f05465ac180c34c25e47a3b8ef338882faced3f52b7` |
| Image index | `sha256:3b4f5628b94141b82cdbe579317b3dde2212ef52877a0197976d003fef3390ce` |
| AMD64 image | `verdictai/glm53-flash-exl3-k4@sha256:a6962d4a45474e9b50e26d888d739076c5fbe51e5e531c2d11ead3d74285f484` |
| Image config | `sha256:19a51d921523dd0c21afbf99bb49a00fc2d3feb6f565b1d3474ed0120372d847` |
| ExLlamaV3 | `brandonmmusic-max/exllamav3@704aefd743b390af4bd0fb429d1906f9b964c7d8` |

The checkpoint manifest intentionally contains the complete root-level serving surface:
120 model shards plus configuration, tokenizer, processor, receipts, license, README, and
published manifests. Nested calibration and reproduction sources are not needed by vLLM and
are excluded. The upstream receipt binds 175,622,979,576 indexed tensor bytes and 150,226
tensors.

## What the image contains

This **is vLLM**, not stock ExLlama or the checkpoint's standalone Transformers script:

- custom vLLM package `0.26.1rc0+infernal.invocation.cu133.r19.vllm174c789.b12x12c4263`;
- an EXL3 K4 routed-expert loader with TP2 rank slicing;
- B12X sparse MLA with `nvfp4_ds_mla` KV storage;
- a zero-padded physical-RoPE/NoPE adapter for GLM-5.3;
- CUDA 13.3, PyTorch 2.13, NCCL 2.31.2, and SM120 ExLlamaV3 kernels.

EXL3 describes the routed-expert **weights**. `nvfp4_ds_mla` describes the **KV cache**.
They are independent quantization surfaces.

The image inherits a DeepSeek entrypoint. The repository launcher therefore overrides it with
`/opt/venv/bin/python -m vllm.entrypoints.openai.api_server`. Never run the image by tag with
its default entrypoint.

### Provenance limitation

The image is digest-pinned and carries a BuildKit in-toto statement, but the statement has no
builder identity and incomplete dependency resolution. Its GLM overlay labels name vLLM
commits `eb290e8...` and `df684ff...` and B12X commit `30aafad...`; those commits were not
publicly resolvable during preparation. This prevents independent source reconstruction.
The profile is acceptable only as an isolated experimental test—not as a trusted promotion
artifact without further source publication or a reproducible replacement build.

## Initial qualification envelope

| Setting | v1 value |
|---|---:|
| Tensor parallelism | 2 |
| Context | 131,072 tokens maximum |
| Active sequences | 1 by default; hard ceiling 8 |
| Batched tokens | 8,192 |
| Weight reader | EXL3 K4, routed experts only |
| KV cache | `nvfp4_ds_mla` |
| Attention | `B12X_MLA_SPARSE` |
| MTP | disabled |
| Vision/video | disabled with `--language-model-only` |
| Prefix cache | disabled |
| CUDA graphs | disabled with eager mode |

The reported Estonia results—approximately 80 tok/s C1 decode, more than 3,000 tok/s prefill,
10/10 coherence, and sustained behavior through 128K—are external claims, not local evidence.
The separate claim that the packed MLA cache can exceed one million tokens is a capacity claim,
not proof of a coherent one-million-token request. This v1 stops at 128K.

The desktop currently has driver `595.91.07`, while the image was built in a CUDA 13.3 stack
whose build environment records driver 610.43.02. The image includes CUDA compatibility
libraries and does not declare a restrictive minimum through `NVIDIA_REQUIRE_CUDA`; actual
startup remains the only valid compatibility test.

## Download and verify

The home ZFS path avoids interactive sudo over SSH:

```bash
cd ~/.dotfiles
DEST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/download-glm53-flash-exl3-k4-v1.sh

docker logs -f glm53-exl3-k4-v1-model-dl

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/verify-glm53-flash-exl3-k4-v1.sh
```

The downloader is resumable. `.download-complete` is installed atomically only after all 135
files pass size and SHA-256 verification plus architecture, quantization, receipt, and index
contracts.

Pull and inspect the image:

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v1-image.sh
```

The pull script checks the exact config digest, 100-layer rootfs identity, provenance labels,
EXL3 TP2 reader, model registration, B12X NVFP4 cache shape, and FlashInfer SM120 cache shape.
It writes a mode-0600 identity receipt under `~/.local/state/glm53/`.

## Preflight

Preflight re-hashes about 163.7 GiB but does not access GPUs:

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v1" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v1.sh --preflight
```

## Attended cold boot

GLM, Qwen, and DeepSeek are mutually exclusive on port 8000. ComfyUI must also stop because it
holds nearly one GPU's memory.

```bash
systemctl stop comfyui.service
nvidia-smi

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v1" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v1.sh --launch

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v1
```

The launcher fails closed unless exactly two 96 GB-class RTX PRO 6000 Blackwell GPUs are
present, each uses at most 1 GiB, each retains the repository's 450 W power cap, the image and
checkpoint identities pass, and port 8000 is free. API keys are mounted through a private env
file and never placed in process arguments.

## Acceptance probes

Use curl configuration over stdin so the bearer token is not exposed through argv:

```bash
key="$(<~/.config/glm53/api-key)"
printf 'header = "Authorization: Bearer %s"\nurl = "http://127.0.0.1:8000/v1/models"\n' "$key" |
  curl --silent --show-error --fail --config -
```

Qualification must cover:

1. authenticated model discovery and rejection without credentials;
2. deterministic text sanity and multilingual/code/reasoning prompts;
3. streaming and non-streaming chat;
4. `glm45` reasoning and `glm47` tool-call parsing;
5. measured C1 prefill/decode throughput;
6. 32K, 64K, and 128K needle/coherence tests;
7. restart with `MAX_NUM_SEQS=8` only after C1 passes, then eight concurrent requests;
8. VRAM headroom, temperatures, PCIe/NCCL behavior, Xid checks, and an attended soak.

Do not enable MTP, vision, prefix caching, CUDA graphs, context above 128K, or more than eight
sequences in this profile. Each requires a new versioned qualification profile.

## Rollback

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v1 2>/dev/null || true
systemctl start comfyui.service
```

No checkpoint, cache, image, env file, or container belonging to another profile should be
deleted during rollback.

## Required attribution

The checkpoint and runtime material are source-available under the ShapleyMcg License v1.0,
not OSI open source. Retain the bundled license and this attribution:

> This work includes or was produced using ShapleyMcg, created by Brandon M. Music
> (https://github.com/brandonmmusic-max/shapleymcg). ShapleyMcg is licensed under the
> ShapleyMcg License v1.0, an attribution-required license that grants no rights to the person
> known as "0xSero." Use of ShapleyMcg without this attribution is unlicensed.
