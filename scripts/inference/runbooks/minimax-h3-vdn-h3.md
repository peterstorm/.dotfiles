# MiniMax H3 VDN-H3 Workflow Runbook

Workstation adaptation of aifuturetech's "Video DeltaNet Minimax H3 in ComfyUI —
Faster Base Model Without Losing Quality" (<https://youtu.be/kqyPTv77j3g>) for the
Blackwell desktop: the VDN-H3 (Video Delta Net) hybrid-attention node port, the
8-step stage checkpoint, and the two comparison workflows.

## What VDN-H3 is

Video Delta Net splits attention into two branches: nearby frames keep exact
softmax attention (local motion and consistency untouched), while distant
temporal context goes through the checkpoint's Video Delta Attention linear
branch — a constant-cost recurrent state replacing quadratic long-range
attention. Attention cost grows linearly with clip length instead of
quadratically, so the win grows with longer clips and larger resolutions.

The port (Saganaki22/ComfyUI-VDN-H3, Apache-2.0) reproduces the official
hybrid-attention math on ComfyUI's native MiniMax-H3 model as runtime model
patches: one patch node between the H3 loader and the sampler; conditioning,
samplers, VAE decode, and output nodes are unchanged. No new base model, no
retraining, no extra Python packages. The 8-step distilled model supports
8-step sampling by default — no Turbo LoRA required on the VDN branch.

## Provenance

| Field | Value |
| --- | --- |
| Source video | <https://youtu.be/kqyPTv77j3g> (aifuturetech) |
| Node port | Saganaki22/ComfyUI-VDN-H3 @ `183f33d8a7b3c6322d83be95ae369251a63b3198` (v1.3.1) |
| Comparison nodes | Saganaki22/ComfyUI-sol-attn @ `930a4d6e432ff8b8ed5e30ff2f72519b92d69bdf` (v0.6.2) |
| Switch node | nova452/Rebalance-Pack @ `4553b145043b3ed6818651e5e39a01614fc11fb6` (main HEAD — the exact revision the example pins) |
| VDN weights | OpenVDN/vdn-minimax-h3 @ `18be6bcc4ee72585eee322ba28b5ccac2cf85ef0` — `stage-dmd-step-250/` (bf16 release) |
| Realism LoRA | fal/MiniMax-H3-Realism-People-LoRA @ `039cc8579d7aa357a882d7f4111b25da4f72dccc` — `h3-realism-people-t2v-i2v-r2v.safetensors` (rank 32, 1500 steps, ungated) |
| Workflows | `VDN-H3-VS-fastvideoH3_t2v.json`, `Minimax-H3VDN-R2V.json` (built by `scripts/comfyui/build-minimax-h3-vdn-workflows.sh`) |
| Realism workflows | `VDN-H3-VS-fastvideoH3_t2v + Realism People LoRA.json`, `Minimax-H3VDN-R2V + Realism People LoRA.json` (built by `scripts/comfyui/build-minimax-h3-vdn-realism-workflows.sh`) |
| Deployed as | `minimax-h3-vdn-h3/` and `minimax-h3-vdn-h3-realism-people/` under `/var/lib/comfyui/user/default/workflows` |
| Author's Patreon JSONs | Account-gated; both graphs are adapted from the pinned upstream example + ModelTC REF2VA Turbo source instead |

## Install

1. Apply the desktop NixOS configuration: the three node packs are immutable
   declarative pins, each contract-tested during the build.
2. Download the bf16 stage (license-gated):

   ```bash
   MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=yes \
     download-minimax-h3-vdn-stage
   ```

   The release directory lands intact under `/models/comfyui/vdn/stage-dmd-step-250/`
   (`model_spec.json`, `linear_branch/`, `adapters/`); every artifact is
   SHA-256 verified against the pinned manifest before it reaches the model root.
   The bf16 release is pinned deliberately — not the optional int8 ConvRot
   quantization (bf16 where possible).
3. Download the fal Realism People LoRA (license-gated, ungated on HuggingFace):

   ```bash
   MINIMAX_H3_ACCEPT_LICENSE=yes MINIMAX_H3_AUTHORIZED=yes \
     download-minimax-h3-realism-people-lora
   ```

   The adapter lands as `/models/comfyui/loras/h3-realism-people-t2v-i2v-r2v.safetensors`
   (131,229,656 bytes), SHA-256 verified against the pinned manifest. It follows
   the MiniMax-H3 Community License of the base model and loads as-is — the keys
   are the standard H3 fused-QKV layout, no conversion step.

## Workflows

### VDN-H3-VS-fastvideoH3_t2v.json — T2V head-to-head

Adapted from the node port's shipped example (the same 2-branch, shared-sampler
Switch topology the video demos). Both branches sample 8 steps, er_sde / beta,
from the same fixed noise seed:

- TRUE branch ("True = VDNH3"): BF16 FL2VA + ApplyVDNH3
  (`stage-dmd-step-250`, turbo adapter ON, `lora_mode` merge,
  `branch_weights` cache_gpu) + MiniMaxChunkFeedForward. **No Turbo LoRA** on
  the VDN branch.
- FALSE branch: BF16 FL2VA + `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors`
  at strength 1.0 + comfy kitchen attention + Scheduled Sol Attention.

Flip the Switch widget to choose the branch; both write to
`video/VDN-H3_VS_fastvideoH3_t2v`.

### Minimax-H3VDN-R2V.json — REF2VA comparison

The VDN branch beside the previously qualified REF2VA Turbo control. Both
branches share the prompt, reference images, resolution (1344×768, reference
resize `match`), duration, and fixed noise seed; each samples its own trained
recipe:

- VDN branch: BF16 REF2VA + ApplyVDNH3, 8 steps, er_sde / beta, no Turbo LoRA.
- Control branch: BF16 REF2VA + ref2v Turbo 4-step LoRA at 1.0 + comfy kitchen
  attention + Scheduled Sol Attention + video/audio sigma shift 12/3, 4 steps,
  Euler / simple.

Drop `subject_1.png`, `subject_2.png`, `environment.png` into the three loaders
before queueing. Outputs: `video/VDN-H3_R2V_VDN` and `video/VDN-H3_R2V_Turbo4_Control`.

### Realism People LoRA variants

`VDN-H3-VS-fastvideoH3_t2v + Realism People LoRA.json` and
`Minimax-H3VDN-R2V + Realism People LoRA.json` copy the two graphs above and wire
the fal realism adapter into **both branches of each graph**, so the comparison
stays apples-to-apples — the variable remains the attention route, not the LoRA.
Built by `scripts/comfyui/build-minimax-h3-vdn-realism-workflows.sh` from the
checksum-gated built base workflows; every other widget (samplers, schedulers,
VDN stage, sigma shifts) is unchanged.

- The adapter only touches the shared attention projections
  (`diffusion_model.blocks.N.attn.qkv_proj`, fused QKV), so it composes with the
  VDN runtime patch and with the Turbo LoRA. In the T2V graph the turbo branch
  chains UNET → realism LoRA → Turbo LoRA → comfy kitchen → Sol; the VDN branch
  chains UNET → realism LoRA → ApplyVDNH3.
- **Start every prompt with the trigger word `r34l1sm`**, then describe the
  scene (the graphs already prepend it; keep it when editing prompts). Scale 1.0
  is the intended strength; 0.6–0.8 for a lighter touch.
- Outputs are prefixed `_realism` (`video/VDN-H3_VS_fastvideoH3_t2v_realism`,
  `video/VDN-H3_R2V_VDN_realism`, `video/VDN-H3_R2V_Turbo4_Control_realism`) so
  realism and non-realism renders never overwrite each other.
- Sigma schedulers in the R2V graph keep the raw UNET on purpose: sigmas do not
  depend on LoRA weights.
- One adapter covers t2v, i2v and r2v — trained on a larger people-focused
  dataset as the successor of fal's MiniMax-H3-Realism-LoRA.

## Model substitutions (bf16 where possible)

| Stage | Upstream selector | Workstation selector | Why |
| --- | --- | --- | --- |
| Diffusion (UNETLoader) | `minimax_h3_fl2va_int8_convrot.safetensors` | `minimax_h3_fl2va_bf16.safetensors` | Unpruned BF16 DiT; the VDN patch applies at runtime on whatever base is loaded |
| Diffusion (R2V UNETLoader) | `minimax_h3_ref2va_bf16.safetensors` | unchanged | Already the workstation BF16 profile |
| Text encoder (CLIPLoader) | `qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors` | `qwen3vl_32b_minimax_h3_bf16.safetensors` | Full BF16 encoder |
| Video VAE (VAELoader) | `minimax_h3_video_vae_int8_convrot.safetensors` | `minimax_h3_video_vae_fp16.safetensors` | Full-precision video VAE variant |
| Audio VAE (VAELoader) | `minimax_h3_audio_vae_fp32.safetensors` | unchanged | fp32 is the only audio VAE variant |
| Turbo LoRA (T2V FALSE branch) | upstream's resized 4-step rank-64 LoRA at 0.65 | `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` at 1.0 | On-recipe: the shared 8-step sampler pairs with the 8-step LoRA at its released strength |
| VDN stage | `stage-dmd-step-250` (bf16) | unchanged | bf16 where possible; the int8 ConvRot variant trades fidelity for speed |
| Scheduled Sol Attention | upstream example's `SolAttnMiniMax` (pre-rename schema) | `MiniMaxH3ScheduledSolAttentionPatch` (v0.6.2) | The class was renamed and its inputs redesigned between the example's export and v0.6.2; the example's intent is kept — tau_start 1.2, dense_percent 0.2 (the Sol-Attn paper's recipe), min_tokens 12288, sink exact_kv_and_rows — with released defaults elsewhere (tau_end 0.8, linear curve, diag threshold, no int8) |

## Tips and tricks (from the source video, kept binding)

- **No Turbo LoRA on the VDN branch.** The VDN run does not need the Turbo LoRA
  connected at all — the attention mode alone makes it faster at the default
  8 steps, and the released 8-step turbo adapter replaces community Turbo LoRAs
  (never run both). VDN alone was the video's recommended config for quality:
  a few seconds slower, keeps most of the original weights' data.
- **Do not stack the "MiniMax H3 Scheduled Sol Attention" patch with the VDN
  node.** It replaces `blocks.*.attn.forward` — the same path VDN owns — so
  wherever SOL handles a call, VDN's linear branch is skipped. The workflows
  keep SOL and VDN on separate branches; SOL's FFN-chunking node
  (MiniMaxChunkFeedForward) and general attention overrides do compose.
- **`lora_mode` must stay `merge`** on the 8-step DMD checkpoints
  (`stage-dmd-*`): bypass applies the same adapters but each module's delta
  carries bf16 rounding noise that the deep blocks amplify — every bypass
  render of the 8-step model comes out grainy.
- **`branch_weights: cache_gpu`** keeps the linear-branch weights resident
  (~4.3 GB VRAM free required); `stream` is the small-card fallback.
- **VDN is VRAM- and RAM-heavy.** Commenters with 16 GB VRAM / 32 GB RAM hit
  OOM or near-zero step progress; with the LoRA route the same cards run
  roughly double the resolution and clip length. The workstation's per-card
  memory feeds it; keep `--reserve-vram 8` in force.
- **8-step sampling is the VDN default**; the 50-step model
  (`stage-b-step-2000`) needs ~50 steps and `apply_turbo_adapter` OFF.
- **Judge raw outputs.** The video benchmarks raw first-sampling results with
  no latent upsampling or enhancement — the comparison workflows keep that
  topology so the true output of each route is visible.
- **Stacking for more speed is possible** (VDN + Turbo LoRA) but the video's
  own numbers found the graphics gain is not worth the quality risk: VDN keeps
  fast-motion areas clean where the LoRA route starts pixelating.
- Video benchmarks (10 s @ 0.8 MP, RTX Pro 6000): VDN alone 2:22, Turbo LoRA +
  Sage Attention 1:51, Turbo LoRA + Comfy Kitchen + Sol 1:54. VDN keeps
  fast-motion areas clean where the LoRA route pixelates.

## Known trade-offs

- The port's portable kernels land under upstream's headline numbers: the
  official 74.5x figure combines 8-GPU parallelism, FA4, FP8, and 8-step
  distillation; single-GPU is ~2.6x at 50 steps, and this port measured ~17 s/it
  at 1280×736 / 145 frames on an RTX 5090.
- Both patched models coexist during a queue job (the Switch topology), so the
  comparison graphs hold more model memory than a single-branch run.
- The Sage Attention branch from the source video is intentionally absent:
  SageAttention is not installed on this workstation, and the video's own
  conclusion found Comfy Kitchen + Sol indistinguishable from it.
