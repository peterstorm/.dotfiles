# MiniMax H3 Blender REF2VA workflows

This suite turns an approved Blender viewport render into a direct local MiniMax H3 reference-video carrier. It is private, local, Development-only infrastructure.

Installed workflows:

`/var/lib/comfyui/user/default/workflows/minimax-h3-blender-ref2va-development/`

Operator inputs:

`/var/lib/comfyui/input/h3-blender-previz/`

## Carrier contract

Video 1 is a real REF2VA input, not merely an operator contact sheet. `VHS_LoadVideo` loads it at 24 fps and connects its frames to `MiniMaxH3ReferenceToVideo` as `<Video 1>`. Its audio output is deliberately unconnected: H3 authors sound from the prompt instead of silently inheriting an empty or scratch Blender soundtrack. Connect source audio explicitly only when it is an approved timing/voice authority.

The source video may own:

- duration and exact source cuts;
- camera trajectory, lens impression, framing, and screen direction;
- object/proxy transforms and countable role placement;
- support contacts, contact order, mechanism timing, recoil, and terminal state;
- intentionally reserved transition or effects intervals.

It owns none of the final identity, anatomy, wardrobe, material, color, texture, lighting, world design, acting, emotion, dialogue, or final sound unless the prompt explicitly assigns that role. Pictures 1–3 own Subject A, Subject B/secondary cast, and world/look appearance respectively.

Reference-to-video remains generative conditioning, not deterministic pixel-space transfer. “Video 1 owns camera” is a testable request contract, not proof that every frame transferred.

## Profiles

All profiles use the installed unpruned BF16 Ref2VA checkpoint, BF16 Qwen3-VL encoder, video/audio VAEs, 960×544 output, fixed comparison seeds, and reference resize `match`.

| Workflow | Carrier | Sampling | Status |
|---|---:|---|---|
| `01 … 5s BF16 Quality` | 124 frames | `res_multistep`, simple, 20 steps, no acceleration | Quality baseline |
| `02 … 5s Turbo 4-Step` | 124 frames | Euler/simple, 4 steps, shifts 12/3, Ref2VA Turbo strength 1 | Qualified speed control |
| `03 … 5s PDD 8-Step` | 124 frames | Euler, dedicated Ref2VA PDD sigmas, NFE 8, strengths 1/1 | Acceleration comparison |
| `04 … 15s BF16 Quality` | 362 frames | `res_multistep`, simple, 20 steps, no acceleration | Long carrier baseline |
| `05 … 15s Turbo 4-Step` | 362 frames | Euler/simple, 4 steps, shifts 12/3 | Duration-qualification candidate |
| `06 … 15s PDD 8-Step` | 362 frames | Euler, dedicated Ref2VA PDD sigmas, NFE 8 | Duration-qualification candidate |

PDD is not an ordinary LoRA. Its dedicated node loads the trunk adapter, parallel-decoding head bank, and trained sigma boundaries. Always use the Ref2VA PDD artifact for these graphs and never stack Turbo and PDD.

The H3-valid target lengths are approximately, not exactly, five and fifteen seconds: 124 frames is about 5.17 seconds and 362 frames is about 15.08 seconds at 24 fps. Render the Blender carrier to the exact selected frame count when testing frame alignment.

## Blender export

For every carrier:

1. Set 24 fps from frame one.
2. Use the final H3 aspect ratio and one stable color-management configuration.
3. Render exactly 124 or 362 frames.
4. Prefer a readable Workbench/Eevee viewport render over detail that obscures contacts.
5. Give every recurring proxy a stable, high-contrast role color.
6. When facing direction matters, use a distinct front/back/side encoding or another unambiguous orientation cue.
7. Keep helper objects, rig controls, labels, and viewport overlays out of the render.
8. Keep contacts, supports, object paths, and terminal states visible.
9. Preserve the `.blend`, Python source, render settings, and carrier checksum.
10. Upload as `BLENDER_CARRIER_5S.mp4` or `BLENDER_CARRIER_15S.mp4` under `h3-blender-previz/`.

A 1920×1080 MPEG-4 viewport master is acceptable as archival source; H3 conditions and generates at the graph’s pinned 960×544 dimensions. Do not claim the larger carrier makes the generated output 1080p.

## Prompt adaptation from the Higgsfield article

The useful structure is retained without copying its broken labels or product-specific claims:

1. **Reference definitions:** assign one role to every video and picture.
2. **Source priority:** video wins camera, edit, placement, and mechanics; pictures win only assigned appearance.
3. **Timeline contract:** enumerate intervals, locations, visible cast, physical event, and terminal state.
4. **Countable invariants:** cast count, role mapping, screen/seat geography, contact/fall count, and persistent states.
5. **Non-inheritance:** reject proxy color, materials, anatomy, lighting, grids, and helper geometry.
6. **Performance:** author gaze, emotion, dialogue, and microbehavior explicitly inside existing coverage.
7. **Dialogue rule:** dialogue does not create a new shot; off-screen speech stays off-screen.
8. **Hold summary:** restate the few load-bearing invariants at the end instead of pasting contradictory prose.

The article’s 30-second, 720-frame Seedance examples exceed the installed local H3 limit. Split them into independently reviewable carriers no longer than 362 frames. Prefer real shot boundaries. A continuous 30-second one-take needs overlapping context and seam qualification; concatenation does not prove continuous path transfer.

## Operating procedure

1. Confirm ComfyUI owns the intended GPU and the queue is idle.
2. Choose 124 frames for mechanics and controlled comparisons; choose 362 only when the longer timeline is load-bearing.
3. Upload the carrier plus all three appearance authorities in the exact labeled order.
4. Replace the template prompt’s generic descriptions and enumerate the actual timeline.
5. Run BF16, Turbo, and PDD with identical carrier, pictures, prompt, dimensions, and profile-paired seed when comparing acceleration.
6. Queue one graph at a time.
7. Preserve the native output before any edit, upscale, interpolation, or external cut.
8. Review full playback and dense frame windows around every cut, contact, reversal, occlusion, and terminal state.

## QA

Score these independently:

- camera/path adherence;
- cut count and exact cut order;
- role/color mapping and subject count;
- support and contact order;
- persistent mechanism consequence;
- identity and topology retention;
- proxy geometry, color, or lighting bleed;
- acting introduced at the wrong time;
- dialogue creating unauthorized coverage;
- audio timing and unwanted source-audio inheritance.

Turbo/PDD speed, a close visual match, and successful generation are technical evidence only. Every retained result stays Development evidence and requires explicit user selection before any Production promotion.
