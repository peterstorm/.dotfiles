# MiniMax H3 Dual Sampling — photoreal skin workflow

Source video: [The AI Brief — “This is how Minimax H3 on Steroids Looks like”](https://youtu.be/HJteqahyEKM)

## Source provenance

The original downloaded workflow was recovered from homelab and is preserved
byte-for-byte at:

`comfyui/workflows/minimax-h3-singularity-dual-sampling-i2v.json`

- Original filename: `MiniMax_H3_Singularity_DualSampling_The_AI_Brief_EN.json`
- Author metadata: `The AI Brief`
- Nodes / links: `87 / 88`
- SHA-256: `69b3373cf4b9784d50886c0ae65a516e34f0b9cf65dc29d9d216bd286dab4778`

The builder refuses any source with a different digest or structural identity.
This supersedes the earlier public-video reconstruction.

## Installed workflows

Open **User workflows → `minimax-h3-dual-sampling-v1.1-source-exact`**:

1. **`00 MiniMax H3 BF16 Dual Sampling - Source Exact Topology`** — default.
   Uses the official unpruned BF16 Ref2VA checkpoint and BF16 Qwen3-VL-32B
   encoder: the highest-precision published H3 model stack.
2. **`01 MiniMax H3 Singularity v1.3 Dual Sampling - Source Exact Topology`** —
   source-model comparison. Singularity v1.3 publishes no BF16 checkpoint; its
   34 GB unpruned INT8 model is its best available artifact. Pruned INT8 and
   W4A8 alternatives are excluded.

The obsolete `minimax-h3-dual-sampling-v1.0` reconstruction is removed only
after the source-exact v1.1 directory has verified and installed.

## Exact source topology

The downloaded graph uses:

1. A six-step `simple` schedule.
2. `ExtendIntermediateSigmas`: two linear intermediate sigmas from 1 to 0.
3. A split at step 2: the primary Turbo sampler runs the high-sigma segment.
4. Primary AV separation: preserve primary audio and upscale only the denoised
   video latent.
5. BF16 3D latent upscale at 1.25×, aligned to 32 with temporal chunking.
6. The source’s second split at step 0. This gives its middle sampler zero
   sampling intervals and is intentionally retained as an optional no-op seam.
7. Rejoin the upscaled video with the preserved primary audio.
8. A no-fresh-noise final low-sigma AV pass using LMS 0.5 and Realism People
   1.0 (`r34l1sm`), followed by video/audio decoding.

This differs materially from the initial reconstruction: the primary sampler
runs only the high-sigma segment, while the LMS/Realism guider owns the final
low-sigma pass.

## Workstation compatibility adaptations

The build-time adapter preserves sampling and AV-link semantics while making
the graph deterministic on the pinned desktop closure:

- rgthree Set/Get virtual wires become direct links between the same loaders
  and H3 reference inputs.
- The one-active-LoRA rgthree stack becomes core `LoraLoaderModelOnly`.
- The unsupported `easy float` scale node becomes a fixed 1.25 upscaler value.
- Stale cloud previews, Windows paths, and mutable model URLs are removed.
- The retired upscaler selector/schema becomes the current pinned BF16 3D-conv
  model with explicit `force_unload`.
- The source’s `BlockSparseAttention` is omitted. Pinned ComfyUI 0.34 does not
  contain that newer node, and upstream has reported MiniMax H3 Turbo artifacts
  when sparse attention is enabled. The exact-quality Comfy Kitchen backend,
  source Sage patch, and chunked feed-forward path remain.

No ComfyUI Manager, runtime download, rgthree, or Easy-Use dependency remains.
The raw source is retained separately for audit and future core upgrades.

## Pinned model profile

| Role | Selector | Precision / rationale |
|---|---|---|
| Default diffusion | `minimax_h3_ref2va_bf16.safetensors` | Official unpruned BF16; preferred |
| Source-model comparison | `minimax_h3_singularity_ref2va_v1.3_int8.safetensors` | Best published Singularity artifact; no BF16 exists |
| Text encoder | `qwen3vl_32b_minimax_h3_bf16.safetensors` | BF16; source INT8 encoder upgraded |
| Video VAE | `minimax_h3_video_vae_fp16.safetensors` | Highest official video-VAE precision |
| Audio VAE | `minimax_h3_audio_vae_fp32.safetensors` | FP32 |
| Primary accelerator | `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` | BF16, strength 1.0 |
| Detail refinement | `minimax_h3_lms_v1.0_r64.safetensors` | Rank-64, strength 0.5 |
| Skin realism | `h3-realism-people-t2v-i2v-r2v.safetensors` | Strength 1.0, trigger `r34l1sm` |
| Latent upscale | `minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors` | Current BF16 3D-conv model |

The LMS artifact is pinned to
`Alissonerdx/Minimax-H3-ComfyUI@0ff489e781c274d17b2e3a30cd6f9a8d40ca49ff`,
size `1,239,664,536`, SHA-256
`16f3195bc6bffa431c0598dc2031e520ba058b4fcbc9f104db9e3fdfdeacf60c`.

## Prepare models

The complete model closure is installed on desktop. Idempotently verify LMS:

```bash
MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=yes \
  download-minimax-h3-dual-sampling-models
```

MiniMax H3 base/derivative use remains governed by the MiniMax-H3 Community
License and territorial-authorization gate. LMS declares Apache-2.0. The latent
upscaler declares no code or model license, so this remains private local
Development-only: no Production, commercial-use, redistribution, or public-
display authority is inferred.

## Operation

The workflow is installed while ComfyUI is inactive. The running GLM inference
container is not stopped or restarted. Do not start ComfyUI beside the two-GPU
GLM deployment; use the existing transactional creative-stack activation only
when an explicit workload cutover is wanted.

Before the first expensive render:

1. Select local files in Picture 1, Picture 2, and optional Picture 4. The
   original JSON referenced images that were not included in the upload.
2. Run a 5-second fixed-seed qualification before restoring 15 seconds.
3. Compare BF16 and Singularity with identical prompt, references, seed, and
   dimensions.
4. Inspect skin in motion for crawling pores, oversharpening, identity drift,
   waxy smoothing, and audio discontinuity.
5. Preserve the primary preview beside the final refined output.

The downloaded workflow is authoritative for topology and settings, not proof
of general identity retention, arbitrary prompts, or production fitness.
