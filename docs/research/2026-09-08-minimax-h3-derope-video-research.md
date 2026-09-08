# MiniMax H3 De-RoPE anti-smearing — video research receipt

- Video: [ComfyUI: Fixing MiniMax H3 Motion Smearing with De-RoPE](https://youtu.be/IlVPJI9ceKM)
- Channel: Machine Delusions
- Video ID: `IlVPJI9ceKM`
- Published: 2026-09-06
- Duration: 14:59
- Caption source: YouTube `en-orig` automatic captions
- Raw VTT SHA-256: `2c9db1827306940673de75c07411aa46be3f30e56038aac2bac3a90381ae6f44`
- Public implementation credited by the video: [`matlowai/ComfyUI-MAINodes`](https://github.com/matlowai/ComfyUI-MAINodes)
- Pinned implementation: v1.1.3, commit `f4868b4a08e8a504ce86db54a17961d399ffa2bc`, GPL-3.0

## Finding

The “anti-smearing nodes” are MatlowAI's **Motion Lab De-RoPE** nodes. This is not spatial sharpening or ordinary frame interpolation. MiniMax H3 compresses groups of pixel frames into one temporal latent representation; rapid pose changes can therefore average into smeared, torn, or missing anatomy. De-RoPE gives only high-motion regions more temporal room, re-diffuses that slowed content, and then returns to the original clock by exact frame selection.

The public stable chain is:

1. `H3 Jerk Oracle` reads the pass-1 latent and creates an adaptive integer hold map for high-motion bursts.
2. `H3 Time Smear` repeats pass-1 decoded frames according to that map.
3. `H3 Audio Smear` stretches pass-1 audio onto the same clock; `VAEEncodeAudio` seeds it into pass 2.
4. `VAEEncode` encodes the slowed frames.
5. `H3 V2V Init` creates the pass-2 joint video/audio latent.
6. `H3 Inject Schedule` performs a partial second diffusion pass.
7. `H3 Exact Recover` drops held frames exactly, restoring the original frame count at 24 fps.
8. `H3 Audio Recover` restores audio timing and defaults to the original pass-1 performance.
9. `H3 Jerk Heatmap` is the review surface used to see where the oracle intervened.
10. `H3 Manual Hold Map` is the targeted variant: review the heatmap, then restrict regeneration to explicit problem ranges.

## Timestamped evidence

- **01:00–03:03:** explains the temporal-compression cause: gentle motion survives, while rapid changes within one compressed temporal representation are averaged into blur/smear.
- **03:06–03:53:** states the remedy: detect hectic motion, add hold frames, diffuse the slowed video, discard the extra frames, and return to normal speed.
- **04:03–04:10:** identifies a two-pass system.
- **09:22–10:31:** walks the graph: pass-1 latent into the motion oracle, oracle to hold map, re-encode, partial second pass on the stretched video, then hold-map recovery to clean 24 fps.
- **10:38–11:01:** the demonstrated baseline uses no Turbo LoRA and 25 shared scheduled steps.
- **11:01–11:27:** refinement below/about 0.5 behaves more like enhancement; stronger values increasingly reinterpret motion, like denoise in an upscale pass.
- **12:02–13:58:** outcome is content-dependent. High-motion spans improve substantially, while untouched or poorly detected regions can be unchanged or worse.
- **14:02–14:13:** the Patreon workflow is account-gated; the implementation credit points to public `ComfyUI-MAINodes`.

## Implementation decision

Do not reproduce or bypass the account-gated Patreon graph. Generate new local workflows from MatlowAI's public, GPL-3.0 example workflows at the pinned release:

- automatic FL2VA oracle flow;
- targeted FL2VA flow with `H3 Manual Hold Map`;
- REF2VA flow with audio seeding and separate original-performance/seeded-foley outputs.

All three are adapted to the workstation's installed full-BF16 diffusion model and BF16 text encoder. They preserve the video's 25-step, no-Turbo-LoRA quality baseline and live in a new immutable Development-only directory. Existing H3 workflows remain untouched.
