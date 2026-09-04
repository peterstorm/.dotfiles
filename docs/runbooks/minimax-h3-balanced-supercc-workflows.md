# MiniMax H3 Balanced SuperCC Workflow Runbook

Workstation adaptation of SuperCC AI's "Most Balanced MiniMax H3 Workflow | ComfyUI"
(<https://youtu.be/5yZL3b1gHgA>) for the two-GPU RTX 6000 Pro Blackwell desktop.

## Provenance

| Field | Value |
| --- | --- |
| Author | SuperCC AI (`sonnybox` on GitHub) |
| Source workflow | <https://supercc.ai/files/1/v1.0-16qvluw/H3_T2V_Balanced.json> |
| Source revision path | `v1.0-16qvluw` |
| Source SHA-256 | `2f04b9e5329ddc625f2d7694e5e988c1db688e2ff7942ff5016fadeb3bdfe22a` |
| Adapted workflow | `comfyui/workflows/minimax-h3-balanced-supercc-v1.0-t2v.json` |
| Deployed as | `~/workflows/minimax-h3-balanced-supercc-bf16/MiniMax H3 BF16 Balanced SuperCC v1.0 - Text To Video.json` under `/var/lib/comfyui/user/default` |
| Author's tested ComfyUI | v0.33.1 — workstation runs ComfyUI 0.33.3 |

The adaptation is a pure deterministic transform of the source: model-selector
substitutions, four node bypasses, and two note rewrites. Everything else is
byte-identical to the author's export.

## Model substitutions (bf16 where possible)

The author tuned the graph around a 16 GB RTX 5070 Ti and quantized models for
speed. With ~96 GB per RTX 6000 Pro Blackwell card, the workstation runs
full-precision selectors instead:

| Stage | Author's selector | Workstation selector | Why |
| --- | --- | --- | --- |
| Diffusion (UNETLoader) | `h3/minimax_h3_fl2va_pruned_int8_convrot.safetensors` | `minimax_h3_fl2va_bf16.safetensors` | Unpruned BF16 DiT is the quality baseline; the author's own note says the pruned UNET caps 14 s @ 1 MP |
| Text encoder (CLIPLoader) | `qwen3vl_32b_minimax_h3_int8_convrot.safetensors` | `qwen3vl_32b_minimax_h3_bf16.safetensors` | Full BF16 encoder, checksum-verified local downloader |
| Video VAE (VAELoader) | `minimax_h3_video_vae_int8_convrot.safetensors` | `minimax_h3_video_vae_fp16.safetensors` | Only full-precision video VAE variant installed; int8-convrot is the author's 16 GB speed compromise |
| Audio VAE (VAELoader) | `minimax_h3_audio_vae_fp32.safetensors` | unchanged | fp32 is the only audio VAE variant |
| Turbo LoRA (SuperSelectLoraName) | `h3/minimax_h3_fl2v_lightx2v_turbo_8step_merge_0821_bf16.safetensors` | unchanged (downloaded) | Already bf16; the graph ships selected with it |

Author's turbo LoRA, downloaded and SHA-256 verified against Hugging Face:
`/models/comfyui/loras/h3/minimax_h3_fl2v_lightx2v_turbo_8step_merge_0821_bf16.safetensors`
(1,956,192,864 bytes, SHA-256 `15437c28698054a63821f3b9c4a6b729ec5fe6e387a126b942d43c62b0a5930b`,
from `sonnybox/MiniMax-H3_experimental`).

## VRAM nodes turned off (author guidance for RTX 6000 Blackwell)

The author: "over here the chunk feed forward if you have a lot of RAM. So, if
you're running this on like a [RTX] 6000 Blackwell, then you don't need this at
all. It's just going to slow you down. And same thing with the reserve VRAM."

All four low-VRAM accommodations are bypassed (`mode: 4`) in the adapted graph:

| Node | Where | Author's value | Why bypassed |
| --- | --- | --- | --- |
| `MiniMaxChunkFeedForward` | main graph id 751 | chunk 2 / 4096 | Chunked feed-forward trades speed for VRAM; not needed on Blackwell |
| `SetReserveVRAM` | main graph id 650 (turbo stage) | reserve 128 GB | Max reservation offloads all weights to RAM — only worth it on a dedicated small-VRAM box |
| `MiniMaxChunkFeedForward` | "Test Target Megapixels" subgraph #827 | chunk 2 / 4096 | Same machinery in the 1-step mechanics test pass |
| `SetReserveVRAM` | "Test Target Megapixels" subgraph #828 | reserve 128 GB | Same as above |

The remaining `SetReserveVRAM` nodes (ids 829/830, value 0) are inert
"keep the launch value" reset points and stay as shipped; the ComfyUI service
launches with `--reserve-vram 8`. The OOM Checker group's bypassed
`PreviewImage` is the author's runtime toggle: unbypass it before a run to
watch the reserve checker, re-bypass afterwards.

The `RTXVideoSuperResolution` nodes are NOT bypassed: both are load-bearing in
the author's quality pipeline (4x MEDIUM before the turbo stage re-encodes at
the megapixels target, 1.5x HIGH on the final output). Their resolutions are
calculator-driven, so they contribute detail enhancement, not resolution.

## Required custom nodes (pinned in `machines/desktop/comfyui.nix`)

| Node types | Pack | Pin |
| --- | --- | --- |
| `SetReserveVRAM`, `DualSamplerEulerAncestral`, `DualSamplerCustomAdvanced`, `SigmaAncestry`, `SigmasRescale`, `SuperSelectLoraName`, `ImageSizeCalculator` | `sonnybox/ComfyUI-SuperNodes` | rev `6a271834567f26576c046259493f0934c6c57d84` |
| `RTXVideoSuperResolution` | `Comfy-Org/Nvidia_RTX_Nodes_ComfyUI` + `nvidia-vfx` wheel (LicenseRef-NvidiaProprietary, Development-only authorization) | rev `892515e3eb9a4920a131a502a047e47adca9eb0d` |
| `MiniMaxChunkFeedForward` | `kijai/ComfyUI-KJNodes` | already installed |
| `ComfyMathExpression` | native ComfyUI 0.33.3 (`nodes_math.py`) | ComfyUI 0.33.3 pin |

`nvidia-vfx` (NVIDIA VFX SDK Python bindings) ships a wheel-stub sdist whose
backend pulls the proprietary binary from `pypi.nvidia.com`; the workstation
pins the `cp312-abi3` manylinux wheel directly (SHA-256
`e51d9e6faa68466e45b83be7928321af4b0c561c7c5536a8cb2b7e6aba25f905`). The wheel
bundles cuDNN 9, NPP 12, TensorRT 10, and the NGX VSR libraries — no runtime
model downloads; `libcuda.so.1` comes from the host driver.

## Deployment

`installCreativeWorkflows` (ExecStartPre of the `comfyui` service) stages
`comfyui/workflows/minimax-h3-balanced-supercc-v1.0-t2v.json` into
`minimax-h3-balanced-supercc-bf16` and atomically swaps it into the user
workflows directory on every service start. The SuperNodes and NVIDIA RTX packs
mount through `declarativeNodes`.

To apply before the next rebuild, copy the adapted workflow into the user
workflows directory directly:

```sh
ssh desktop 'mkdir -p /var/lib/comfyui/user/default/workflows/minimax-h3-balanced-supercc-bf16'
scp "comfyui/workflows/minimax-h3-balanced-supercc-v1.0-t2v.json" \
  "desktop:/var/lib/comfyui/user/default/workflows/minimax-h3-balanced-supercc-bf16/MiniMax H3 BF16 Balanced SuperCC v1.0 - Text To Video.json"
```

## Usage

1. Settings live in the "Common Settings" side panel: prompt, duration,
   megapixels, aspect ratio.
2. Prompt structure follows the author's T2V guide (three sections:
   `integrated_multimodal_description`, `overall_soundscape`,
   `non_diegetic_music`) — see the Google Doc linked from the video.
3. The workflow produces two outputs: the base-stage draft
   (`video/h3-draft`) and the final turbo output.
4. Re-enable the bypassed low-VRAM nodes only when re-tuning for a
   small-VRAM box; on this workstation they only slow generation down.
