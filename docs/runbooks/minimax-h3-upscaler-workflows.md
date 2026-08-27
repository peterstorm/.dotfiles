# MiniMax H3 Upscaler Workflows

## Executable local paths

Open **User workflows → `minimax-h3-upscaler-local-safe`**. The folder contains the four profiles tested against the same native H3 control clip:

1. **`00 MiniMax H3 Output - Lanczos 2x Zero Hallucination Video`** — exact 2× interpolation; the faithful default when the source already contains irreducible anatomy, topology, or texture artifacts.
2. **`01 MiniMax H3 Output - Real-ESRGAN x4plus to 2x Video`** — pinned BSD-3-Clause learned 4× upscale followed by Lanczos reduction to a matched 2× delivery size.
3. **`02 MiniMax H3 Output - Real-ESRGAN General x4v3 to 2x Video`** — compact pinned Real-ESRGAN alternative with the same 4×→2× path.
4. **`03 MiniMax H3 Output - SeedVR2 7B FP16 Natural Video 2K`** — temporal generative restoration at a 1536-pixel short edge and 2688-pixel cap; preserved for comparison after the first H3 trial was rejected for invented surface grit, harder edges, and excess local contrast.

The two Real-ESRGAN graphs process frames independently. They may sharpen more pleasantly than SeedVR2, but they can amplify source defects or produce temporal shimmer. Lanczos adds no semantic detail and therefore cannot repair defects already baked into the native H3 render. No profile can reconstruct authoritative geometry absent from the source.

Before queueing a learned profile, wait for an idle ComfyUI queue and run:

```bash
creative-model-phase prepare upscale
```

Select the native H3 video in the input node. Every result is a **Finishing Derivative**. Preserve the native H3 master, compare at 100% and in motion, review identity/topology/text/palette/flicker at dense intervals, and remux checksum-authoritative dialogue after visual finishing. Reopen the workflow after refreshing ComfyUI so a browser-resident obsolete graph is not reused.

### Tested-control result

On the 960×544, 243-frame H3 control, all three new workflows produced 1920×1088, 24 fps, 243-frame outputs with the original 10.125-second duration. Framewise SSIM against a Lanczos-resized native control was:

- Lanczos 2×: `0.989363`;
- Real-ESRGAN x4plus→2×: `0.978504`;
- Real-ESRGAN General x4v3→2×: `0.975573`;
- SeedVR2 7B natural at 2688×1524: `0.951704`.

SSIM is only a fidelity diagnostic, not an aesthetic ranking, but it confirms that the rejected SeedVR2 result altered the source substantially more than the three added alternatives.

## Why the old workflows were removed

`minimax-h3-upscaler-research-only` contained three unchanged third-party examples that could not execute in the pinned workstation closure:

- the I2V and R2V examples require unavailable `MinimaxH3LatentUpscaler3D` and `VHS_VideoCombine` classes;
- the Ultimate example requires unavailable `MMH3*` split/upscale classes and `CLIPLoaderGGUF`;
- all three select missing quantized/pruned H3 models or incompatible/missing Turbo LoRAs;
- the learned 3D latent-upscaler checkpoint is not installed;
- the companion learned-upscaler node repository has no explicit code license at the audited revision.

The installer now removes that broken browser directory. Checksum-identical originals remain preserved as private Development research in `development/research/minimax-h3-encyclopedia-01/workflows/h3-latent-upscaler/`; they are not executable authorities.

The four SeedVR2 qualification graphs also had a cosmetic upstream `Note` node unavailable in the pinned ComfyUI closure. The declarative builder now removes that disconnected node from every installed SeedVR2 graph.
