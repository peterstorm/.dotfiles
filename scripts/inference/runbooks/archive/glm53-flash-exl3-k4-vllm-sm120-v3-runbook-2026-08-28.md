# GLM-5.3 Flash EXL3 K4 v84 multimodal + DFlash2 v3

**Status:** v84 image pulled and statically verified; DFlash2 draft not yet downloaded; target
checkpoint is still downloading; no local model boot or qualification.

This is a new multimodal profile. It does not alter the conservative v1 or 500K text-only v2
launchers. It uses the same target tensors as the active EXL3 download, adds a small DFlash2
draft checkpoint, and moves to the v84 runtime that packages the vision fix. The separate v4
profile uses the same v84 target and vision path with built-in MTP3 instead of DFlash2.

## What changed since v37

The reported vision failure is real and has two independent causes:

1. The v37 custom image lacks `vllm_flash_attn/layers/rotary.py` and
   `vllm_flash_attn/ops/triton/rotary.py`. Its GLM vision path can consequently fail when the
   ViT RoPE implementation hard-imports the absent Python layer.
2. The target checkpoint's `chat_template.jinja` is text-only. It replaces image content with
   a reminder that the model has no multimodal ability, so vLLM cannot match the processor's
   image placeholder.

A local workaround can copy two Python files from a vLLM 0.28 wheel and override the template.
This profile deliberately does **not** mix upstream 0.28 Python into the custom 0.26.1rc0 fork.
The newer v84 image instead patches its own `ApplyRotaryEmb` to fall back to native PyTorch RoPE
when the packaged FlashAttention helper is unavailable. It also embeds the official Z.ai
multimodal template. This is a more internally coherent fix and has an upstream image self-test.

## Immutable identities

| Artifact | Identity |
|---|---|
| Existing target checkpoint | `brandonmusic/GLM-5.3-Flash-EXL3-4bpw@4739eb1bcfd478e8a32da6358908567bc3a9ac51` |
| Current TR3 publication | `brandonmusic/GLM-5.3-Flash-tr3-4bpw@5ab363a8dcf6405955fd5f99671e01a1c9fb124b` |
| DFlash2 draft | `incoai/GLM-5.3-Flash-DFlash2@7d74cdd881ed7e32c31175984a67823127b66cfe` |
| DFlash2 manifest | 4 files, 2,342,175,855 bytes, SHA-256 `9979f7d652cd5c971d1db6a5b6093bdd271e711855fcbf22371ecc767d332c9d` |
| Official template source | `zai-org/GLM-5.3-Flash@04c4e9e95c5da8862dced7e5056455116f83a7e0` |
| Official template SHA-256 | `34d5ee66b12fa6446cdae131c352b8f68cd85369e0e6fda115583805fada3891` |
| Runtime publication | `brandonmmusic-max/glm-5.3-flash-exl3-4bpw@bd5321c1cfd4b8d352ef380e3158c64886039d03` |
| v84 image index | `sha256:0f1cdcc8891f1cc3a444121eb61d366289a1cbba285f0892dcbb24bc94961692` |
| AMD64 image | `sha256:184cfdb86fb08902898999ce5d7101f5711e3138f82b4738ba823145c17f8140` |
| Image config | `sha256:f28ba4b2192d8306f2ab93be9ea868459f76e2fd5893d4eef9f7cc48f9180578` |
| Embedded runtime provenance | SHA-256 `cf4b00958987cc50f94641592b1a8d74874adb4d671861ce12dd5e8f2907d907` |

All 120 target weight shards in the TR3 publication are byte-identical to the already pinned
EXL3 checkpoint. The downloaded config, text-only template, and processor config are also
byte-identical. Therefore a second 163.7 GiB target download would add no model capability;
the v3 launcher reuses the fully verified existing checkpoint and explicitly selects the
multimodal template embedded in v84.

The image config has 113 layers and labels vLLM
`6dc2f516688fe6f84c6994dcd20fddf296853a6c`, B12X
`36bce2c1552ba2d47dc09f20a6f64fbfc8ec4ff8`, CUDA 13.3, Torch 2.13, the vision fallback,
and the exact DFlash2 checkpoint. Its embedded provenance hashes the patched rotary source,
two DFlash attention files, and the multimodal template. The complete custom overlay still is
not available as a publicly reconstructible build, so digest pinning is evidence rather than
supply-chain reproducibility.

## Profile envelope

| Setting | v3 value |
|---|---:|
| Target parallelism | TP2 / EP2 / DCP2 |
| Context ceiling | 98,304 tokens |
| Sequences | 4 maximum; one full resident long request is the published capacity claim |
| Batched tokens | 2,072 maximum |
| GPU memory utilization | 0.95, fixed for encoder headroom |
| Target weights | EXL3 uniform K4 routed experts |
| Target KV cache | calibrated `nvfp4_ds_mla` |
| Draft | DFlash2, 7 tokens, TP2, probabilistic, standard rejection sampling |
| Draft attention | corrected noncausal `TRITON_ATTN` sliding window |
| Prefix cache | disabled, matching v84 |
| Vision encoder attention | `TORCH_SDPA` |
| Inputs | text and up to four images; video disabled |
| Chat template | exact official Z.ai multimodal template embedded in v84 |

The 0.95 utilization and explicit image/video limits follow the reported conservative vision
configuration rather than the v84 Compose's 0.986 setting and effectively unbounded modality
default. This is intentionally a local qualification candidate, not a claim that the exact
published benchmark envelope was reproduced.

## Upstream evidence and local limitations

The v84 receipt reports successful warmup and a real remote-JPEG request identifying a mallard
on 2× RTX PRO 6000 Blackwell Workstation Edition. It also reports DFlash2 mean acceptance
5.738763 on the first 16 GSM8K rows, 3,897 tok/s 8K prefill, and 129.45 tok/s empty-context C1
decode. The upstream machine used GPU IDs 1 and 3, 300 W limits, +6000 MHz memory offset, and
ECC disabled. Those values differ from this desktop's current 450 W limits and do not qualify
our cards, driver, clocks, thermals, context, tools, or image handling.

The DFlash2 model is only 2.18 GiB, but is licensed **CC-BY-NC-ND-4.0**. It cannot be treated as
a permissive commercial dependency. The target checkpoint remains under ShapleyMCG License
1.0. Preserve both notices and review use restrictions before deployment.

## Download and verify DFlash2

Do not redownload the TR3 target repository. Finish and verify the existing EXL3 checkpoint,
then fetch only the draft:

```bash
cd ~/.dotfiles
DEST="$HOME/models/GLM-5.3-Flash-DFlash2-v1" \
  bash scripts/inference/glm53/download-glm53-flash-dflash2-v1.sh

docker logs -f glm53-flash-dflash2-v1-model-dl
```

The downloader is revision-pinned, resumable, retries transient Xet errors, verifies all four
files and the draft architecture/block contract, and atomically writes `.download-complete`.
Independent verification:

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-DFlash2-v1" \
  bash scripts/inference/glm53/verify-glm53-flash-dflash2-v1.sh
```

## Pull and inspect v84

```bash
bash scripts/inference/glm53/pull-glm53-flash-exl3-k4-vllm-sm120-v3-image.sh
```

The puller proves the config digest, platform, 113-layer rootfs, runtime labels, DFlash2 identity,
vision-fallback marker, embedded provenance, four source hashes, architecture registration, and
native-PyTorch rotary fallback behavior. A GPU-assisted CLI probe on driver 595 confirmed the
TP/EP/DCP, TORCH_SDPA, modality-limit, prefix-cache, and speculative flags. These probes do not
execute model weights or inference kernels.

## Preflight and attended boot

```bash
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
DFLASH_HOST="$HOME/models/GLM-5.3-Flash-DFlash2-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v3" \
  bash scripts/inference/glm53/run-glm53-flash-exl3-k4-vllm-sm120-v3.sh --preflight
```

After both active model downloads finish and an attended window begins:

```bash
systemctl stop comfyui.service
nvidia-smi

MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
DFLASH_HOST="$HOME/models/GLM-5.3-Flash-DFlash2-v1" \
CACHE_HOST="$HOME/.cache/glm53-flash-exl3-k4-sm120-v3" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v3.sh start

docker logs -f glm53-flash-exl3-k4-vllm-sm120-v3
```

The launcher fails closed on both checkpoint identities, image config, template identity, GPU
identity/memory/power, active ComfyUI, and port conflicts. API credentials remain in a private
env file and never appear in process arguments.

## Qualification gates

1. Confirm unauthenticated rejection and authenticated discovery of only
   `glm-5.3-flash-exl3-k4-vision`.
2. Inspect startup for the native-PyTorch vision-RoPE fallback, TORCH_SDPA encoder, TP2/EP2/DCP2,
   calibrated NVFP4 MLA scales, and DFlash2-7.
3. Test one local image, one remote HTTPS image, four images, malformed media, unsupported video,
   oversized media, and text-only requests.
4. Prove the rendered prompt contains one image token sequence per image and never the text-only
   “no multi-modal input ability” reminder.
5. Compare greedy target-only and DFlash output for lossless parity; measure acceptance for code,
   reasoning, multilingual, and tool prompts.
6. Exercise reasoning history, streaming, single/parallel/malformed tool calls, and image-plus-tool
   turns.
7. Stage 8K, 32K, 64K, and 98,304-token text and image retrieval while recording TTFT, prefill,
   decode, queueing, VRAM, and encoder-cache behavior.
8. Restart twice, then soak while monitoring Xids, corrected errors, thermals, host RAM, and GPU
   memory. Do not promote solely because the mallard smoke test passes.

## Rollback

The v3 switcher restores the previously running repository-owned profile after launch/readiness
failure. Manual rollback keeps both earlier profiles intact:

```bash
docker rm -f glm53-flash-exl3-k4-vllm-sm120-v3 2>/dev/null || true

# Conservative text-only rollback:
MODEL_HOST="$HOME/models/GLM-5.3-Flash-EXL3-K4-v1" \
  bash scripts/inference/glm53/switch-glm53-exl3-profile-v1.sh start
```
