# MiniMax H3 Dual Sampling — photoreal skin workflow

Source video: [The AI Brief — “This is how Minimax H3 on Steroids Looks like”](https://youtu.be/HJteqahyEKM)

## Installed workflows

After applying the desktop configuration, open **User workflows →
`minimax-h3-dual-sampling-v1.0`**:

1. **`00 MiniMax H3 BF16 Dual Sampling - Maximum Precision`** — default.
   Uses the official unpruned BF16 Ref2VA checkpoint and BF16 Qwen3-VL-32B
   encoder. This is the highest-precision published H3 model stack.
2. **`01 MiniMax H3 Singularity v1.3 Dual Sampling - Best Published Quant`** —
   video-faithful comparison. Singularity v1.3 publishes no BF16 checkpoint;
   its 34 GB unpruned INT8 model is its best available artifact. The pruned
   INT8 and W4A8 variants are deliberately excluded.

The Gumroad JSON is checkout-gated. This package does **not** claim byte-for-byte
identity with it. It reconstructs the topology and settings visible in the
public video and transcript, then removes unnecessary convenience-node
requirements for the pinned workstation closure.

## Reconstructed topology

The public graph and narration show:

1. Four-step Ref2V Turbo primary sampling at 0.5 MP.
2. Split the generated AV latent.
3. Preserve the primary audio latent unchanged.
4. Upscale only the video latent by 1.25× with the MiniMax H3 3D latent
   upscaler in BF16, aligned to 32 pixels with temporal chunking.
5. Apply LMS at 0.5 and Realism People at 1.0 (`r34l1sm`) to the refinement
   model.
6. Run the high-sigma half of a no-fresh-noise video refinement pass.
7. Rejoin the preserved audio latent.
8. Run the low-sigma final AV pass, then decode video and audio once.

The graph uses core `LoraLoaderModelOnly`, `ResolutionSelector`,
`SplitSigmas`, `DisableNoise`, `SamplerCustomAdvanced`,
`LTXVSeparateAVLatent`, and `LTXVConcatAVLatent` nodes. It does not require
rgthree, Fearworks, or ComfyUI-Manager. The sole non-core execution node is the
already pinned `MinimaxH3LatentUpscaler3D`.

## Pinned model profile

| Role | Selector | Precision / rationale |
|---|---|---|
| Default diffusion | `minimax_h3_ref2va_bf16.safetensors` | Unpruned BF16; preferred |
| Video comparison | `minimax_h3_singularity_ref2va_v1.3_int8.safetensors` | Best published Singularity artifact; no BF16 exists |
| Text encoder | `qwen3vl_32b_minimax_h3_bf16.safetensors` | BF16; lower INT8/NVFP4 encoders excluded |
| Video VAE | `minimax_h3_video_vae_fp16.safetensors` | Highest official video-VAE precision |
| Audio VAE | `minimax_h3_audio_vae_fp32.safetensors` | FP32 |
| Primary accelerator | `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors` | BF16 |
| Detail refinement | `minimax_h3_lms_v1.0_r64.safetensors` | Pinned LMS rank-64 LoRA, strength 0.5 |
| Skin realism | `h3-realism-people-t2v-i2v-r2v.safetensors` | Pinned Realism People LoRA, strength 1.0 |
| Latent upscale | `minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors` | Current BF16 3D-conv model; retired FP16 selector excluded |

The new LMS artifact is pinned to
`Alissonerdx/Minimax-H3-ComfyUI@0ff489e781c274d17b2e3a30cd6f9a8d40ca49ff`,
size `1,239,664,536`, SHA-256
`16f3195bc6bffa431c0598dc2031e520ba058b4fcbc9f104db9e3fdfdeacf60c`.

## Prepare models

The main BF16 stack, Singularity, Realism People, Turbo, VAEs, and BF16 latent
upscaler are already installed on the workstation. Install/verify the LMS LoRA:

```bash
MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=yes \
  download-minimax-h3-dual-sampling-models
```

MiniMax H3 base/derivative use remains governed by the MiniMax-H3 Community
License and the workstation’s separate territorial-authorization gate. The LMS
repository declares Apache-2.0. The latent-upscaler repository declares no
code or model license, so this workflow remains private local Development-only;
it carries no Production, commercial-use, redistribution, or public-display
authority.

## Operation

The workflow is installed while ComfyUI is inactive. The running GLM inference
container is not stopped or restarted. When a deliberate creative-session
cutover is wanted, use the existing transactional creative-stack activation;
do not start ComfyUI beside the two-GPU GLM deployment.

Before the first expensive render:

1. Replace `dual-sampling/face_identity.png` and
   `dual-sampling/character_sheet.png` in the two Load Image nodes.
2. Run a short 5-second fixed-seed qualification before restoring the video’s
   15-second setting.
3. Compare the BF16 default against the Singularity profile with identical
   prompt, references, seed, and dimensions.
4. Inspect skin texture in motion—not a single frame—for crawling pores,
   oversharpening, identity drift, waxy smoothing, and audio discontinuity.
5. Preserve the primary/native output alongside every refined derivative.

The public video is evidence for a useful candidate topology, not proof of
general identity retention, arbitrary prompts, or production fitness.
