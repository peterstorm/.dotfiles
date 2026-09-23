# Qwen Image 2.1 BF16 — Krea 2 creative adaptations

## Source and license

Official [ComfyUI model bundle](https://huggingface.co/Comfy-Org/Qwen-Image-2.1)
revision `5dc5850eb514a3685f6a03a2641728a8f7549c69`. Official
[ComfyUI workflow templates](https://github.com/Comfy-Org/workflow_templates)
revision `371a7b7171bbd11e9cc92ef615ba5ad223d7e5b4` are vendored with
SHA-256 assertions in `comfyui/workflows/qwen-image-2.1-official/`.

**License: Qwen Research License, not Apache/MIT.** Non-commercial research or
evaluation only; commercial use requires a separate license. The downloader
records this restriction with the checkpoint closure. Do not promote outputs
to production/commercial authority on the basis of these workflows.

All three artifacts are the highest-quality matching ComfyUI release: unpruned
BF16 diffusion (`14,230,280,616` bytes), BF16 Qwen3-VL-8B text encoder
(`17,534,334,616` bytes), BF16 Qwen Image 2.1 VAE (`675,509,688` bytes).
The exact upstream LFS SHA-256 and sizes are in
`scripts/comfyui/qwen-image-2.1-bf16.manifest`. No INT8, W4A8, or Krea
checkpoint may replace them.

Run idempotently on **desktop**:

```bash
download-qwen-image-2.1-bf16
```

This installer downloads from an exact HF commit to staging, checks each full
SHA-256 and byte count, installs verified files atomically, and writes the
completion receipt **last**. It does not load weights or allocate GPU memory.

## Workflows

On the **isolated ComfyUI 0.37 instance** (loopback port `8189`), open
`User workflows → qwen-image-2.1-bf16-krea-adaptations-v1.1/`:

1. **Krea RAW composition** — copies the creative composition/prompt from the
   existing pinned Krea 2 RAW maximum-quality T2I profile; official Qwen 2.1
   text-to-image graph, 1 MP, 50 Euler/simple steps, CFG 1.
2. **Krea 2K direct** — copies the pinned Pixaroma/Krea 2 2K composition; uses
   native Qwen 2.1 4 MP output instead of Krea's 1.5× latent extra pass.
   This can be substantially more memory-intensive; qualify at 1 MP first.
3. **Krea single-view identity edit** — copies the Krea RAW single-view
   preservation instruction into the official Qwen 2.1 image-edit subgraph.
   The original second demo-image input is disconnected; select your **one**
   local reference in the LoadImage node before running. Krea's
   identity-edit LoRA and grounded-encode nodes are **not** compatible with
   Qwen's model family and are deliberately omitted.

These are **adaptations**, not direct Krea checkpoint substitutions. ComfyUI
0.37.0 introduced native `TextEncodeQwenImage21`/`QwenImage21Cache`; the
desktop closure pins that release and validates existing custom nodes during
the Nix build. The source templates supply Qwen-specific conditioning, VAE,
latent and sampling paths. Qwen's prompt enhancer artifacts are optional and
only published in INT8; they are omitted rather than lowering this BF16 stack.

**Database isolation is essential:** upstream ComfyUI 0.37 migration `0007`
rebuilds the existing asset catalog and discards tags, custom metadata, and
renames. The old `comfyui.service` stays pinned to 0.34 on loopback `8188` with
its existing `/var/lib/comfyui/user/comfyui.db` intact. The new inactive
`comfyui-qwen21.service` owns `/var/lib/comfyui-qwen21/user/comfyui.db` and
port `8189`; it has no `wantedBy`. Its prestart verifies the full local BF16
closure offline (no runtime model downloads) and installs only its own versioned
workflows. Never point this service at the old database or start either ComfyUI
service beside the GLM container.

The running `glm53-flash-spark-tp2-v14` deployment stays active. Neither
ComfyUI service is started and no image generation is run. Only execute after
an explicit, transactional GPU workload switch, then inspect the first 1 MP
results before attempting the native-2K variant.
