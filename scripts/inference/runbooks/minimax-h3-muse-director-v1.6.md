# MiniMax H3 Muse Director v1.6 — maximum-quality local profile

This is the workstation adaptation of MuseCollective's final V1.2 bug-fix bundle and its upstream V1.4 example graph. It is Development-only local infrastructure for timeline-directed MiniMax H3 generation, seed scouting/refinement, hybrid Reference/First-Last-Frame chunks, audio transcription, and long-form continuation.

Primary source:

- [MiniMax H3 Director - The Bugs Are FIXED — V1.2 Update](https://youtu.be/41R-wFwEVIM)
- [Complete timestamped transcript](../research/muse-director-v1.2-video-41R-wFwEVIM-transcript.md)
- Pinned source: `muse-collective-26/MiniMaxH3-Director-V1.2@98700398963cd75f39c963e21b29264143c758fc`

The recording is chronological development footage. Later statements supersede earlier ones: most importantly, the temporary Seed Hunt seam glitch described around 00:58 is reported fixed around 01:03 after the Refine path was changed to rebuild the required prior latent context.

## Installed workflow

```text
/var/lib/comfyui/user/default/workflows/minimax-h3-muse-director-v12-local-development-v1.6/
└── 01 MiniMax H3 Muse Director V1.6 - Maximum Quality BF16 Local Development.json
```

V1.5 remains untouched. Every future graph change must use a new filename and destination directory.

## Workstation substitutions

The video's loader offers Q4, Q5, and Maximum Quality profiles. This workstation forces **Maximum Quality** and substitutes the creator graph's practical quantized selectors with the checksum-verified unpruned BF16 set:

| Role | Pinned selector |
|---|---|
| Reference diffusion model | `minimax_h3_ref2va_bf16.safetensors` |
| First/Last-Frame diffusion model | `minimax_h3_fl2va_bf16.safetensors` |
| Text encoder | `qwen3vl_32b_minimax_h3_bf16.safetensors` |
| Video VAE | `minimax_h3_video_vae_fp16.safetensors` |
| Audio VAE | `minimax_h3_audio_vae_fp32.safetensors` |
| Stage-2 upscaler | `minimax_h3_latent_upscaler_3d_fp16.safetensors` |
| Acceleration LoRA | `minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors` |

Low VRAM and Balanced remain disabled rather than lying to the unified loader about BF16 weight size. The automatic hardware probe is bypassed by the explicit Maximum Quality selection. Creator Q4/Q5, ConvRot, NVFP4, GGUF projector, and optional style-LoRA selectors are absent from active, named-widget, bypassed-picker, and subgraph state.

## Declarative dependencies

The workstation pins and deploys every video-listed node pack:

- Muse Director + Refine V2 bundle;
- Muse MiniMax H3 Unified Loader;
- Muse Run Stats;
- ComfyUI-H3-Multishot;
- ComfyUI-H3-Motion-Context-MultiRef;
- ComfyUI-KJNodes;
- local contract-equivalent display/save/purge helpers.

The long-form resume checkpoint loaders are hardened to `weights_only=True`. Sol Attention is deliberately absent; the pinned Unified Loader removed it after real memory-pressure stalls.

## Auxiliary models

```bash
# Apache-2.0 LTX2.3 cosmetic preview VAE from the repository linked by the video
download-tiny-preview-vae

# MIT, pinned medium model; this is the only Whisper quality exposed locally
download-muse-whisper-medium

# Optional H3 sampling preview. Requires the existing MiniMax license and
# territorial authorization gates.
MINIMAX_H3_ACCEPT_LICENSE=yes \
MINIMAX_H3_AUTHORIZED=yes \
download-minimax-h3-tae

# Required by two-stage sampling; normally already installed
download-minimax-h3-latent-upscaler
```

Muse transcription is hardened to `/models/comfyui/audio_encoders/faster-whisper-medium`. It cannot silently download Tiny/Base/Small on first use. The video identifies Medium as the most accurate supported choice.

## Video-derived quality defaults

The recording's quality-oriented baseline is:

- sampler: `euler`;
- scheduler: `beta`;
- acceleration: 8-step LoRA at strength 1.0;
- normal run: 8 total steps with a 4+4 two-stage split;
- slower quality run: 10 total steps with a 6+4 split;
- target: 1 megapixel until higher targets are separately qualified;
- temporal upscaler chunking: off;
- reference image size: Max;
- VAE Re-encode Carry and Raw Latent Carry: on;
- one workflow queued at a time.

The video's later 0.5-megapixel, single-stage reference-edit example is explicitly a faster lower-quality test, not the workstation baseline.

## Operation

1. Ensure the normal vLLM profile has released GPU1 before starting ComfyUI.
2. Start the service:

   ```bash
   sudo systemctl start comfyui
   systemctl status comfyui --no-pager
   ```

3. Open the v1.6 workflow and verify the Unified Loader displays `Maximum Quality`.
4. Analyze every character, location, and relevant first video frame before queueing. Blank descriptions remove important prompt context.
5. Keep each H3 chunk at or below about 15 seconds. Longer timelines are split into sequential chunks.
6. Choose the generation mode deliberately:
   - **Reference** for character/location/audio references;
   - **First/Last Frame** for frame-constrained generation;
   - **Hybrid** for a per-chunk mix of both.
7. Keep VAE re-encode and raw-latent carry enabled for continuity.
8. For Seed Hunt, choose 1–4 candidates and enable latent-only scouting. Refine only the selected candidate; the bundled Refine V2 resumes from its saved latent rather than regenerating from the beginning.
9. For the cleanest selected Seed Hunt output, use the final fixed Refine path from the pinned bundle. Do not follow the recording's earlier temporary workaround.
10. Save the native video, final frame, compiled prompt, seed, and timeline JSON before further editing.

## Audio and transcription

- **Voice reference** conditions voice identity.
- **Lip Sync** uses timed transcript cuts; lyrics/dialogue must be quoted and assigned to the correct reference speaker.
- Use an aligned vocals-only stem for transcription when music masks words, while retaining the intended main track for generation.
- Select only the required `[In, Out)` window; the node applies the same trim to transcription and generation to prevent timestamp drift.
- Whisper Medium runs on CPU and may take longer, but the recording identifies it as the most accurate option.
- First/Last-Frame mode has no native reference-audio socket. Treat audio behavior in Hybrid experiments as provisional and review it explicitly.

## Continuity and resume

For multi-chunk work:

- the prior chunk's final frames/audio provide continuation context where the mode supports it;
- First/Last-Frame continuation uses the prior final frame as the next first frame;
- guide images cannot land inside protected overlap frames;
- long-form resume saves a checkpoint and continues from a declared chunk range on a later run;
- preserve the checkpoint and all associated inputs together.

Resume checkpoints contain only tensors and scalar/string metadata and are loaded with the hardened safe loader. Do not import unknown checkpoints from another source.

## Reference video

The node normalizes source timing to H3's 24 fps. Set explicit in/out points, select whether source audio is referenced or reused, and treat motion transfer as generative conditioning—not one-to-one mechanics proof. The video's own comparison describes it as a loose but useful transfer, even with ControlNet.

## QA

Review each retained result for:

- exact chunk count, ordering, and visible seams;
- candidate/seed identity and whether Refine used the selected latent;
- character and location reference numbering;
- voice identity, speaker assignment, and transcript timing;
- first/last-frame adherence;
- reference-video duration and source-audio behavior;
- final frame continuity across mode changes;
- native 24 fps output and requested target resolution;
- unexpected creator models, quantized selectors, or runtime downloads.

Successful generation is technical evidence only. Human review is required before promotion beyond Development.
