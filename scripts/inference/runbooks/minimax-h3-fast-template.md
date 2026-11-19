# ComfyUI Fast H3 (MiniMax H3 default template, fast checkpoint route)

Smallzero's video ([ComfyUI Just Made MiniMax AI Video 5X Faster — Fast H3 Workflow](https://youtu.be/T6Vag3kb4Fk)) tests a fast MiniMax H3 pipeline that lives in **ComfyUI's own default templates** — no workflow file to download. The author found the fast checkpoint in the built-in template and swapped the attention backend; everything else is checkpoint selection.

## Where the template is

ComfyUI → **Templates** → Video → the **MiniMax H3** family. The template system ships four local routes plus the API ones:

| Template id | Route |
|---|---|
| `video_minimax_h3_t2v` | text-to-video (the video's "hidden Fast H3" starting point) |
| `video_minimax_h3_i2v` | image-to-video |
| `video_minimax_h3_r2v` | reference-to-video |
| `video_minimax_h3_i2v_continuation` | clip continuation |

These ship with the `comfyui-workflow-templates` package — already part of the workstation's ComfyUI python env, so the template browser has them with no extra install.

## The two routes

| Route | Checkpoint (UNET loader) | What the video shows |
|---|---|---|
| **Fast (turbo)** | `10Eros_Max_h3_TURBO_ref2va_beta2.safetensors` | The 15–20 s render for a 5-second clip — the distilled checkpoint the video calls the "Fast H3" |
| **Quality (full BF16)** | `minimax_h3_ref2va_bf16.safetensors` | The full-precision route — slower, higher motion fidelity |

Both are already installed under `/models/comfyui/diffusion_models/`. The video's tests push resolution from the default low-res draft to 1.0 MP and a 2.0 MP portrait with native audio — same template, higher resolution.

## Selector fixes needed on first open

The template's selectors point at the template's default files, which may not match the workstation's installed set. If a selector names a file that is not on disk, re-pick it on the canvas once and save. The installed equivalents:

| Loader | Pick the installed |
|---|---|
| UNETLoader | `10Eros_Max_h3_TURBO_ref2va_beta2.safetensors` (fast) or `minimax_h3_ref2va_bf16.safetensors` (quality) |
| CLIPLoader | `qwen3vl_32b_minimax_h3_bf16.safetensors` — BF16 beats the nvfp4 variant the video's author used |
| LoraLoaderModelOnly | the H3 LoRAs live at the **loras root**, not under a `mmh3\` Windows subfolder: `minimax_h3_ref2v_turbo_4step_v0.1_comfyui_bf16.safetensors`, `h3-realism-people-t2v-i2v-r2v.safetensors` |
| MinimaxH3LatentUpscaler3D | `minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors` — the retired fp16 is gone upstream |

These need no re-picking (exact match to disk):

- **VAELoader (video)**: `minimax_h3_video_vae_fp16.safetensors`
- **VAELoader (audio)**: `minimax_h3_audio_vae_fp32.safetensors` — the native-audio branch of the video's 0.8 MP and 2.0 MP tests
- **ModelAttentionBackend**: `comfy kitchen attention` — the ComfyUI Kitchen backend the video installs to replace SageAttention; `comfy-kitchen 0.2.31` is already in the workstation's ComfyUI python env

## Video test matrix (what to expect)

| Test | Setting | Result in the video |
|---|---|---|
| 1 | Default 15-second T2V render | 15–20 s on the turbo checkpoint |
| 2 | 1.0 megapixel | quality vs scaling tradeoffs |
| 3 | 10-second prompt, native audio, 0.8 MP | audio + lip-sync check |
| 4 | 2.0 MP portrait (1080p) | 6-minute render, motion quality at higher res |

The video's core claim: MiniMax H3 has strong motion dynamics but is brutal without high-tier VRAM; the distilled pipeline changes prototyping speed on older hardware (3080/4060/5060 class). The tradeoff is motion quality at higher resolutions and the 2.0 MP portrait's 6-minute render.

## Does this affect all workflows?

**No.** The fast checkpoint is a per-workflow widget value in the UNET loader — picking it in the template changes only that graph's run. Nothing installed changes:

- The muse builder's H3 turbo family (`minimax-h3-turbo-lora-qualification/`) pins its **own** checkpoints and accelerates by a **different route** — full-BF16 weights plus the 4-step/8-step turbo LoRAs (`minimax_h3_fl2v_turbo_4step/8step_v1.0_comfyui_bf16`), the qualification-tested pairing. The video's fast route is the **distilled turbo checkpoint with no LoRA** — complementary, not a replacement.
- The Motion Context / MultiRef, muse sheet, and Director families pin their own checkpoints per workflow; installed files stay immutable.
- No downloader, pin, or path config changes when you pick the turbo checkpoint — it is a canvas choice, not a stack change.

The turbo checkpoint (`10Eros_Max_h3_TURBO_ref2va_beta2`) and the muse turbo LoRAs (`minimax_h3_fl2v_turbo_4step/8step`, `minimax_h3_ref2v_turbo_4step`) are alternative accelerations of the same base: pick one per graph. Mixing them (turbo checkpoint + turbo LoRA) double-discounts the step schedule and is not tested.
