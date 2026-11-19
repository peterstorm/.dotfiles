# ComfyUI H3 Motion Context Resize v1.1

True Visuals' workflow update (2026/09/16, [video](https://youtu.be/rc332zxjQ_I)) fixes the post-upscale part of the 2-phase upscale workflow: **H3MotionContextResize** resizes only the video stream of the MiniMax H3 Motion Context AV latent so a saved context can chain-test continuity at a different resolution without regenerating the previous clip.

## Why the node exists

MiniMax H3 Motion Context chains clips so motion and audio continue seamlessly across joins. Its latents are stored as plain lists — `{"samples": [video, audio]}` — not tensors, so standard ComfyUI resize/upscale nodes can't touch them (they call `.shape` on `samples["samples"]`, and a list has none). **H3MotionContextResize** unpacks the list, resizes only the video stream spatially, and repacks the same list format so `H3 Motion Context` / `H3 Motion Context Save Latent` accept it unchanged. Audio and the frame/step count are never touched — only width and height change, which is what `MiniMaxH3MotionContext` actually checks for a match.

The v1.1 update corrects the part of the workflow that runs after the upscale pass and updates the example workflow JSON to match. Still tested on 8GB VRAM thanks to chunked frame processing that keeps memory usage under control.

## Installed workflow

```text
/var/lib/comfyui/user/default/workflows/minimax-h3-motion-context-resize-v1.1/
└── ComfyUI-H3MotionContextResize-2StageSamplingUpscale.json
```

This is a dedicated graph. It does not modify or replace any existing MiniMax H3 or Motion Context workflow. Workflow versions are immutable: change the filename and destination directory before changing the graph in a future release.

## How to use it (from the video)

The 2-phase upscale pattern: a low-res pass for speed, then a high-res pass — with the Resize node bridging the two so the context latent survives the resolution change:

```text
H3 Motion Context Load Latent -> H3 Motion Context Resize -> context_latent
                                                               (on H3 Motion Context)
```

Set `width`/`height` to the exact pixel resolution of the **new** clip you are generating — `MiniMaxH3MotionContext` rejects a `context_latent` whose resolution doesn't match.

### Node parameters

| Input | Description |
|---|---|
| `latent` | An H3 AV latent: output of `H3 Motion Context Load Latent`, or a live sampler output before Save Latent. |
| `upscale_method` | `bislerp` (default) is the only method designed for latents rather than pixels — it slerps channel vectors instead of averaging them, keeping the result in-distribution. `area`, `bicubic`, `bilinear`, `nearest-exact` are also available. |
| `width`, `height` | Target pixel size, must be a multiple of 16 (H3's VAE downsample factor); off-grid values are snapped and logged. |
| `device` | `cuda` (default) runs the interpolation in VRAM instead of system RAM. |
| `frame_chunk` | Latent steps resized per pass (default 8), bounding peak memory on long source clips instead of folding every step into one giant batch. |

### Caveat that does not go away

The pinned frames are never re-denoised. Any resize artifact (blur, ringing) lands straight in the final video, unlike a normal Hi-Res Fix which cleans the upscale up with a second sampling pass. Use this to validate that a chain joins correctly; re-check visually before treating a resized context as final. The 3D latent upscaler in the post-upscale pass mitigates this with chunked, overlapped frame processing — but it is still an upscale, not a regeneration.

## Custom nodes

Pinned via `machines/desktop/comfyui.nix` (`fetchFromGitHub` + contract tests):

| Node | Purpose |
|---|---|
| `shisa84/ComfyUI-H3MotionContextResize` | Resize only the video stream of the AV latent (v1.1 @ `0b9ffee7`) |
| `LBH-123-AI/Comfyui_Minimax_h3_latent_Upscaler` | `MinimaxH3LatentUpscaler3D` — the post-upscale pass (aux_id pinned in the example workflow) |
| `seitanism/ComfyUI-H3-Motion-Context-MultiRef` (already pinned) | The AV latent format (`{"samples": [video, audio]}`) the resize node reads and writes |

The MultiRef fork is **not imported** by the resize pack — kept as a separate pack so a `git pull` there never conflicts. The example workflow's remaining nodes (`MiniMaxH3ReferenceToVideo`, `LTXVConcatAVLatent`, `LTXVSeparateAVLatent`, guiders/samplers) ship with the workstation's ComfyUI source.

## Models

`download-h3-motion-context-resize-models` installs and verifies this profile atomically under `/models/comfyui`:

| Model | Destination | Purpose |
|---|---|---|
| `minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors` | `latent_upscale_models/` | 3D latent upscaler weights |

The HF repo ships only the `conv_v1` weights; the **BF16 file is the highest-quant checkpoint available** (fp16 and fp32.pth are deliberately not part of this profile). The upscaler ships without a declared license — the Development-only note travels with the model.

```bash
download-h3-motion-context-resize-models
```

A successful run ends with:

```text
H3_MOTION_CONTEXT_RESIZE_MODELS_READY: h3-motion-context-resize-models-v1
model root: /models/comfyui
```

**Selector note:** the video's example workflow still names the retired `minimax_h3_latent_upscaler_3d_fp16.safetensors` in its upscaler selector — re-pick the installed `minimax_h3_latent_upscaler_3d_conv_v1_bf16.safetensors` on the canvas before queueing.
