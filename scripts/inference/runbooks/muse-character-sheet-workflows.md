# ComfyUI Muse Character Sheet Workflows (Maximum-Quality BF16)

Two character reference-sheet workflows adapted from the MUSE collective's video graphs (`muse-character-sheet-klein` on FLUX.2 [klein] 9B, `muse-character-sheet` on Krea 2 Turbo) to the workstation's checksum-verified BF16 set. Both sheets produce multi-view character reference sheets with white-background cleanup and face/hand detail passes.

## Installed workflows

```text
/var/lib/comfyui/user/default/workflows/muse-character-sheet-klein-bf16/
└── 01 Muse Character Sheet Klein - Maximum Quality BF16.json
/var/lib/comfyui/user/default/workflows/muse-character-sheet-krea2-bf16/
└── 02 Muse Character Sheet Krea2 - Maximum Quality BF16.json
```

These are dedicated graphs. They do not modify or replace any MiniMax H3 or Krea 2 workflow. Workflow versions are immutable: change the filename and destination directory before changing the graph in a future release.

## Workstation model substitutions (highest quant)

Every selector is pinned to the local BF16 profile; nothing in either graph downloads at runtime:

| Selector | Video value | Workstation value |
|---|---|---|
| Klein diffusion model | fp8 | `diffusion_models/flux-2-klein-9b-bf16.safetensors` |
| Klein text encoder | fp8 | `text_encoders/qwen_3_8b_bf16.safetensors` |
| Klein VAE | — | `vae/flux2-vae.safetensors` |
| Krea 2 diffusion model | int8-convrot | `diffusion_models/krea2_turbo_bf16.safetensors` |
| Krea 2 text encoder | fp8_scaled | `text_encoders/qwen3vl_4b_bf16.safetensors` |
| Krea 2 VAE | — | `vae/qwen_image_vae.safetensors` |
| Krea 2 Identity Edit LoRA | — | `loras/Krea2/krea2_identity_edit_v1_2.safetensors` (strength 1.0) |

Both Muse Model Loader nodes are forced to Maximum Quality with the pinned-memory control left at Default, so they never lower ComfyUI's page-locked pool for the heavy H3 Director stack sharing this session. The Klein `kv_cache` widget is pinned to `off`: FluxKVCache is built for the 9B-KV checkpoint (fp8-only upstream), the plain 9B has no KV-cache support, and the `auto` detection is filename-based, so a MODEL arriving through the loader's model_override socket would fall back to always-on KV.

## Custom nodes

Pinned via `machines/desktop/comfyui.nix` (`fetchFromGitHub` + contract tests):

| Node | Purpose |
|---|---|
| `muse-collective-26/muse-character-sheet-klein` | Klein sheet graph |
| `muse-collective-26/muse-character-sheet` | Krea 2 sheet graph |
| `muse-collective-26/muse-model-loader` | Maximum-quality model routing (headers + named widgets) |
| `1038lab/ComfyUI-RMBG` (trimmed pack) | RMBG-2.0 white-background cleanup |
| `iljung1106/ComfyUI-Krea2-NAG` | Normalized Attention Guidance for Krea 2 |
| `LAOGOU-666/Comfyui-Memory_Cleanup` | VRAM/RAM state reset between runs |
| `ltdrdata/ComfyUI-Impact-Pack` + `ComfyUI-Impact-Subpack` | Face Detail detailer (node default `face_detail=True`) |

`segment-anything` is fetched fresh from PyPI (nixpkgs lacks it); the RMBG pack ships only `AILab_RMBG.py`, `AILab_utils.py`, and `web/` because the remaining model families need an onnxruntime/grounddino/decord stack this profile never loads.

## Models

`download-muse-character-sheet-models` installs and verifies this profile atomically under `/models/comfyui`:

| Model | Destination | Purpose |
|---|---|---|
| `RMBG-2.0/model.safetensors` | `RMBG/RMBG-2.0/` | White-background cleanup |
| `Detailer-KREA2.safetensors` | `loras/Krea2/` | Muse Model Loader `lora_3` detailer LoRA |
| `krea2filterbypass3.safetensors` | `loras/Krea2/` | Filter-bypass projector patch |
| `face_yolov8m.pt` | `ultralytics/bbox/` | Face Detail detector |
| `hand_yolov8s.pt` | `ultralytics/bbox/` | Hand detector |
| `person_yolov8m-seg.pt` | `ultralytics/segm/` | Person segmentation |

The downloader also re-verifies the locally installed BF16 checkpoints (Klein model/text encoder/VAE, Krea 2 model/text encoder/VAE, Identity Edit LoRA) by SHA-256 before declaring the profile ready.

RMBG-2.0 ships under bria's custom license (gated on Hugging Face); the Ultralytics detector models are AGPL-3.0; the two Krea 2 LoRAs ship without a declared license — the Development-only note travels with the model. After reviewing the terms, install or re-verify the profile with:

```bash
MUSE_SHEET_ACCEPT_RMBG_LICENSE=yes download-muse-character-sheet-models
```

A successful run ends with:

```text
MUSE_CHARACTER_SHEET_MODELS_READY: muse-character-sheet-models-v1
model root: /models/comfyui
```
