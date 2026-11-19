# MiniMax H3 Motion Context and Multi-Keyframes

## Installed workflows

Open **User workflows → `minimax-h3-motion-context-development`**:

1. **Custom Keyframes — BF16 Base** — three exact-frame anchors at frames 1, 62, and 124; BF16 FL2VA, `res_multistep`, 20 steps, shifts 12/3, 960×544.
2. **Custom Keyframes — BF16 FL2VA Turbo 4-Step** — the same three-anchor topology with the task-matched FL2VA four-step Turbo LoRA, Euler/simple, shifts 6/3, 1344×768.
3. **AV Extension — BF16 REF2VA Turbo 4-Step** — current direct-latent extension topology with the task-matched Ref2VA four-step Turbo LoRA, Euler/simple, shifts 12/3, 960×544, and one active extension by default.
4. **Two Guides — Maximum Quality BF16** — two chained core `MiniMaxH3AddGuide` nodes at frames 124 and 243, unpruned BF16 FL2VA and Qwen3-VL-32B, 1344×768, 362 frames, `res_multistep`/simple, 50 steps, and shifts 12/3.
5. **Two Guides — BF16 FL2VA Turbo 4-Step** — the same two-guide graph with the task-matched FL2VA four-step adapter, Euler/simple, shifts 6/3, and 1344×768.
6. **Four Guides — Maximum Quality BF16** — four chained guides at frames 73, 160, 234, and 324 within the documented 15-second limit, using the same unpruned maximum-quality profile.
7. **Four Guides — BF16 FL2VA Turbo 4-Step** — the same four-guide topology with the qualified FL2VA four-step profile.

The two/four-guide topology was independently adapted from PixelEasel's
[2-and-4-guide demonstration](https://www.youtube.com/watch?v=6BcIgZj1-I0).
Its source workflow files provide no explicit redistribution license, so they
remain fixed-output inputs to a private local Nix build rather than repository
artifacts. Their exact SHA-256 values are enforced before transformation. The
local graphs remove `easy cleanGpuUsed`, replace quantized selectors with the
installed BF16 closure, add explicit sigma shifting, and constrain the upstream
20-second four-guide example to H3's documented 15-second limit.

The custom node is GPL-3.0 `seitanism/ComfyUI-H3-Motion-Context-MultiRef` at immutable revision `87de57ba619297503fa49c9594c0c021d5b0c261`. Its isolated CPU/mock regression suite runs during the Nix build. The installed node provides custom keyframes, legacy Motion Context/Trim, current masked AV continuation, direct streaming to VideoHelperSuite, and optional reference conditioning.

## Dual-role guide workflow

Every image in workflows 4–7 is used as an exact-frame guide and as a visual reference:
it connects once to `MiniMaxH3AddGuide` for frame placement and once to
`MiniMaxH3ReferenceToVideo` for visual retention. The
prompt must name the same frame numbers shown by the guide widgets. This pairing
improves visual retention, but each keyframe remains a strong steer, not a compositing guarantee. Keep lighting, lens, framing, camera position, identity,
and environment mutually compatible across all guide images.

Replace `h3-guides/GUIDE_1.png` through `GUIDE_4.png` as applicable. If a guide
frame changes, update the corresponding prompt frame in the same saved workflow
before queueing. Do not extend the four-guide graph back to 20 seconds; local H3
qualification remains bounded to 4–15 seconds.

## Fight workflow

Use multi-keyframes as **setup → event → consequence**:

- Keyframe 1: planted support, guard, geography, and screen direction.
- Keyframe 2: one contact, block, evasion, or grapple state.
- Keyframe 3: recoil, displacement, damage, or settled consequence.

Each image owns one visible state. The prompt describes the single causal path between them. An anchor constrains a frame but does not prove correct interpolation, contact topology, or force transfer.

For a Mechanics-Proof shot, keep one exchange in one short generation and inspect dense frames around contact. For Creative Montage, use the AV Extension workflow to continue camera direction, motion, lighting, and sound across separately reviewable clips. Never use a successful seam or cinematic impression as evidence that mechanics passed.

## Timing

- H3 runs at 24 fps.
- The default 124-frame keyframe graph is approximately 5.17 seconds.
- **39 frames** is the preferred continuation context because it is both a valid H3 temporal run and an exact video/audio boundary.
- Keep every source or extension clip **15 seconds or less**.
- Start with one extension. Add later extensions in order only after reviewing the previous seam.

Long chains accumulate identity, topology, lighting, motion, and audio errors. For exact editorial cuts, generate independent source shots and edit externally.

## Turbo profiles

The upstream current AV Extension example selected an FL2V eight-step adapter on a Ref2VA base. The local workflow does not preserve that cross-family combination. It uses the installed official Ref2V four-step LoRA with the matching BF16 Ref2VA checkpoint.

The custom-keyframe Turbo graph uses the installed FL2V four-step 768p LoRA with the matching BF16 FL2VA checkpoint. The Base graph remains available as the quality/control comparison.

Four-step means exactly four Euler/simple sampling steps. Do not increase steps and continue calling the run the qualified four-step profile.

## Operating procedure

1. Ensure ComfyUI is the active GPU profile and the queue is idle.
2. Replace every placeholder input.
3. For custom keyframes, keep frame positions within the target frame count and in strictly increasing order.
4. For AV Extension, start with one active extension and one primary action beat per clip.
5. Preserve source clips and native H3 outputs before blending, upscaling, or editing.
6. Review full frames plus dense contact and seam windows.
7. Record model, LoRA, strength, sampler, scheduler, steps, shifts, dimensions, frame count, context, seed, prompt, and input checksums.

All seven workflows are private local Development tools. Installation and technical execution do not create Production authority.
