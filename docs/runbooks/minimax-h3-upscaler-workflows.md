# MiniMax H3 Upscaler Workflows

## Executable local path

Use **User workflows → `minimax-h3-upscaler-local-safe` → `01 MiniMax H3 Output - SeedVR2 7B FP16 Natural Video 2K`**.

This graph performs visual finishing with the pinned Apache-2.0 SeedVR2 7B FP16 natural model. It is the same deterministic video profile qualified under `image-upscaler-qualification-v1`:

- fixed seed `42`;
- 1536-pixel short edge and 2688-pixel maximum edge;
- nine-frame batches with two-frame temporal overlap;
- tiled FP16 VAE;
- LAB color correction;
- zero injected noise.

Before queueing, wait for an idle ComfyUI queue and run:

```bash
creative-model-phase prepare upscale
```

Select the native H3 video in the input node. The result is a **Finishing Derivative**. Preserve the native H3 master, review identity/topology/text/palette/flicker at dense intervals, and remux checksum-authoritative dialogue after visual finishing.

## Why the old workflows were removed

`minimax-h3-upscaler-research-only` contained three unchanged third-party examples that could not execute in the pinned workstation closure:

- the I2V and R2V examples require unavailable `MinimaxH3LatentUpscaler3D` and `VHS_VideoCombine` classes;
- the Ultimate example requires unavailable `MMH3*` split/upscale classes and `CLIPLoaderGGUF`;
- all three select missing quantized/pruned H3 models or incompatible/missing Turbo LoRAs;
- the learned 3D latent-upscaler checkpoint is not installed;
- the companion learned-upscaler node repository has no explicit code license at the audited revision.

The installer now removes that broken browser directory. Checksum-identical originals remain preserved as private Development research in `development/research/minimax-h3-encyclopedia-01/workflows/h3-latent-upscaler/`; they are not executable authorities.

The four SeedVR2 qualification graphs also had a cosmetic upstream `Note` node unavailable in the pinned ComfyUI closure. The declarative builder now removes that disconnected node from every installed SeedVR2 graph.
