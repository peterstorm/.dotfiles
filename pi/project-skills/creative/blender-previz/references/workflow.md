# Blender → MiniMax H3 Previsualization Workflow

## Operating topology

Pi runs on `homelab`; Blender runs on `desktop`.

```text
Pi skill + project files (homelab)
  → pi-mcp-adapter stdio command
  → ssh desktop (no exposed MCP port)
  → blender-mcp Python server on desktop
  → 127.0.0.1:9876
  → Blender 5.2 add-on in the GUI event loop
```

The socket accepts arbitrary Blender Python. It must remain loopback-only. The MCP adapter, config, and this skill are discovered only when Pi starts from exactly `~/dev/creative`. The server is pinned, telemetry-disabled, and restricted by that project's `.mcp.json` to scene inspection, object inspection, viewport screenshots, and approved code execution. `blender-mcp-session` supplies a private `Xvfb -nolisten tcp` GUI event loop when the workstation is otherwise headless.

MCP is intentionally not the renderer. Save deterministic Python and `.blend` sources, then use Blender CLI/render commands so renders are repeatable without conversational state.

## What the reference-video workflow gets right

The useful sequence is:

`reference → mechanism reconstruction → original remix → static approval → story plan → independent-shot fan-out`

Retain these practices:

- count artist/operator time, shading time, and render time—not only saved generation credits;
- use Blender only for the hard 10% of shots and exhaust drawings, generated keyframes, and simple director/camera-board tools first;
- use it for cheap animatics, hard-to-describe spatial events, ultra-wide/specific lenses, locked framing, spacing, transitions, lights, mechanisms, and coherent camera imperfection;
- start from a shot-isolated contact sheet instead of a paragraph; roughly three samples per second is a useful first pass, with exact event frames added deliberately;
- make the agent reproduce an existing camera/mechanism closely before it invents anything;
- remix the proven mechanism through a separate original location/appearance sheet;
- isolate every output shot;
- create and inspect a contact sheet before rendering animation;
- keep sequence-level progress and learnings files that survive sessions and prevent repeated mistakes;
- plan and give good corrective feedback before parallel work;
- make every worker inspect its own output;
- keep proxy scenes minimal, adding shading or lights only when they are the property being tested;
- do not use proxy mannequins to direct acting, faces, or detail;
- tell the video model the guide's purpose and attention target, exactly which properties to inherit, the explicit character action, coupled events, and positive/negative locks;
- author performance separately; H3 REF2VA can take the complete Blender clip as a video reference, while separately captured real acting remains another potentially stronger performance carrier.

## Shot package

Use a numbered Development-only directory:

```text
development/previsualization/<sequence>/previs-XX/
  PROGRESS.json
  LEARNINGS.md
  <shot-id>/
    SHOT-CONTRACT.md
    references/
      reference-index.json
      contact-sheet.jpg
    blender/
      scene-v01.py
      scene-v01.blend
      SCENE-MANIFEST.json
    review/
      static/
        frame-setup.png
        frame-load.png
        frame-event.png
        frame-consequence.png
        contact-sheet.jpg
        SELF-CHECK.json
      animation/
        playblast-v01.mp4
        contact-sheet-v01.jpg
        SELF-CHECK.json
    h3/
      VIDEO-CARRIER-CONTRACT.md
      GUIDE-ROLE-CONTRACT.md
      GUIDE-MANIFEST.json
      prompt-package/
      capture-spec.json
    SHA256SUMS
```

Version instead of overwriting checksum-distinct `.py`, `.blend`, playblast, or guide artifacts.

## Eligibility gate

Use Blender when at least one scored uncertainty is hard to solve with one accepted keyframe and prose:

- specific wide/ultra-wide projection or unusual lens behavior;
- locked composition through a nontrivial camera move;
- multiple principals whose spacing/order must survive movement;
- support, collision, or exact contact geometry;
- moving architecture, unfolding set, rigid mechanism, or transition;
- deliberate camera imperfection that must be physically coherent.

Do not use it for ordinary dialogue, portrait close-ups, emotional acting, facial motion, clothing detail, or a basic push/pan/tilt. An FPV/drone-style move is not automatically a Blender problem if a conventional reference or simpler camera tool already communicates it.

## Reference-sheet extraction

Cut the source down to the single mechanism-bearing shot and select the useful interval before sampling. Start near three frames per second as the video's practical default; then add the exact onset, contact, reversal, or terminal frame that matters. More frames are not inherently better—the sheet must make the mechanism legible without burying the state changes. Record source, rights status, timecodes, and extraction cadence in `reference-index.json`.

## Mechanism before remix

A reference contact sheet is analysis evidence, not final-film authority. Record its rights status. Rebuild only the spatial/camera mechanism:

1. identify stable anchors, pivots, stops, contact planes, and scale;
2. identify camera projection, height, heading, and frame occupancy;
3. reconstruct the state sequence in neutral proxy geometry;
4. compare reference and reconstruction contact sheets;
5. lock the understood mechanism;
6. build or select a separate location/appearance sheet for the original world;
7. move the mechanism into that geography, identities, and story purpose.

Do not copy protected character or production design. Mechanism understanding is the point.

## Scene construction contract

- 24 fps and the intended H3 aspect ratio from frame one;
- metric units and explicit human/world scale;
- one active camera;
- deterministic names for every principal, anchor, light, and camera rig;
- camera transform separated from a target/aim rig where useful;
- clean keyframes first, deterministic low-amplitude noise second;
- neutral proxy materials with enough contrast to read overlaps;
- proxy body segments only when they prove contact/support;
- no texture search, asset-generation API, face, wardrobe, hair, or decorative scatter;
- save source and scene after every approved gate.

## Contact-sheet gate

Before animation, render at least:

`setup → load → event/contact → consequence`

The static contact sheet must prove:

- lens/crop and frame occupancy;
- principal count, screen order, and scale;
- supports and contact planes;
- event visibility without occlusion;
- mechanism state and persistent consequence;
- no unnecessary detail likely to contaminate an H3 guide.

Reject before animation if any row fails. A fast still correction is cheaper than hundreds of wrong frames.

## Animation and self-check

Animate only the transforms necessary to show camera and mechanism. Proxy acting should remain absent unless a body translation is itself the scored spatial event.

Review both the playblast and sampled frames. Check camera discontinuity, clipping, speed, support loss, early reaction, hidden contact, and unintended object motion. Feedback changes one cause at a time. Update `PROGRESS.json` only after evidence exists; promote reusable corrections into `LEARNINGS.md` before later workers launch.

## Handoff adaptation boundary

The source article hands a complete Blender blockout clip to Seedance 2.5. Local H3 supports the analogous carrier through its REF2VA family: `MiniMaxH3ReferenceToVideo` accepts the playblast as `<Video 1>`, encodes it with the video VAE, and supplies its reference latents to the Ref2VA DiT.

The dedicated suite is installed under `minimax-h3-blender-ref2va-development` with paired 124-frame and 362-frame profiles:

- unpruned BF16 quality: `res_multistep`, simple, 20 steps, no acceleration;
- task-matched Ref2VA Turbo: Euler/simple, 4 steps, shifts 12/3, strength 1;
- dedicated Ref2VA PDD: Euler, NFE 8, shifts 12/3, trunk/head strengths 1/1, off-grid error.

The 15-second Turbo and PDD profiles are duration-qualification candidates, not previously qualified speed controls. Never stack Turbo and PDD. This remains generative reference-to-video, not deterministic pixel-space transfer: every claimed camera, cut, path, contact, and state property must be verified in the H3 result.

The sponsored Higgsfield add-on and creator-specific Bridge are optional interfaces, not required methodology. This installation keeps external asset/network integrations off and uses pinned Blender MCP instead.

## H3 carrier selection

### REF2VA video carrier — default for continuous mechanics

Use the full Blender playblast when camera movement, cuts, body/object paths, contact order, or mechanism timing between anchors is load-bearing:

1. render at 24 fps to exactly 124 frames (~5.17 seconds) or 362 frames (~15.08 seconds);
2. use the 124-frame family for precise mechanics and BF16/Turbo/PDD comparison;
3. use 362 frames only when the longer continuous path or pre-planned edit is load-bearing;
4. load the carrier as `<Video 1>` and provide accepted Subject A, Subject B/secondary cast, and world/look pictures;
5. declare that `<Video 1>` owns transforms and timing but no final identity, anatomy, wardrobe, materials, color, lighting, acting, dialogue, or world design;
6. compare acceleration variants with the identical carrier, pictures, prompt, dimensions, and profile-paired seed;
7. inspect densely around every cut, contact, occlusion, reversal, transition, and terminal state.

A 30-second article-style master exceeds local H3’s limit. Split it at real shot boundaries into independently reviewable carriers. A continuous one-take requires overlap and explicit seam qualification; concatenation does not prove path continuity.

Raw neutral geometry is intentional: it gives H3 a readable motion scaffold while pictures and prompt assign final appearance. It can still leak, so include explicit forbidden-transfer terms and record style bleed during QA. Read `~/.dotfiles/docs/runbooks/minimax-h3-blender-ref2va.md` for graph details and operator procedure.

### Two still guides

Use when opening and closing composition dominate:

- first/last framing;
- lens impression;
- screen direction;
- open/closed mechanism state;
- simple camera interpolation.

### Four still guides

Use when four distinct states are load-bearing:

`setup → load → event/contact → consequence`

Read the exact guide indices from the selected ComfyUI graph and export/resolve Blender frames at those timeline positions. Never assume even spacing or claim the motion between anchors was transferred.

### Raw proxy versus resolved guide

Raw Blender guides are suitable only for a controlled Development A/B. They can leak gray geometry, proxy proportion, and synthetic lighting into H3. The preferred production candidate is a Krea-resolved still that preserves Blender projection/spacing while carrying accepted identity, wardrobe, and location appearance.

Every guide gets one declared job. If four guides consume the graph's useful reference capacity, bake approved appearance into those resolved stills or fall back to two endpoint guides plus identity references. Qualify this empirically; do not infer it from graph connectivity.

## Carrier split

| Carrier | Owns |
|---|---|
| Blender contract/playblast | planning evidence plus REF2VA `<Video 1>` carrier for camera, space, timing, poses, mechanism, support, and contact |
| H3 guide stills | alternate/supplemental visible anchor composition and mechanism state at exact frames |
| Appearance references | accepted identity, wardrobe, machine surface, and world appearance |
| H3 prompt | causal action, acting, microbehavior, camera motion between anchors, timing, dialogue, and sound |
| QA ledger | interpolation, style bleed, identity, topology, contact order, and consequence |

The prompt must say which motion/geometry/camera properties to inherit from `<Video 1>` or guides and author final identity and performance separately. Do not let mannequin appearance carry into the result or assume a proxy pose communicates emotion.

### Prompt structure adapted from the video

Write the handoff in explicit layers:

1. **Purpose/attention:** what the model should read from the guides—such as the rising background, light response, camera path, spacing, or mechanism.
2. **Positive locks:** lens impression, framing, screen order, movement speed, contact order, and any state that must persist.
3. **Negative locks:** acting, mannequin appearance, gray materials, proxy anatomy, unwanted camera drift, or background motion that must not transfer.
4. **Explicit action/performance:** where each character is, what they do, and the intended energy/emotion; never assume it is obvious from a blockout.
5. **Coupled incidents:** state causal links such as “as the blocks accelerate, the characters run” rather than describing each motion independently.
6. **Timing and music:** identify beats, reactions, light changes, or mechanism events that respond to sound when music synchronization is part of the shot.
7. **Editorial intent:** request close-ups or more/less acting only as explicit shot direction, not as geometry inferred from mannequins.

## Rendering strategy on RTX PRO 6000 Blackwell

For previsualization, use Workbench or Eevee. Minimal blockouts should render quickly and gain more from low scene complexity than from photoreal settings. The installation smoke test rendered four 960×544 Eevee frames in one Blender process in **1.396 seconds wall time** while the Qwen container remained active; that default-cube result proves the fast path, not the cost of a real scene. Eevee normally uses one graphics device, so two GPUs do not automatically halve one-shot render time. Parallelize independent shots only after the shot plan is locked and GPU ownership is available.

Cycles/OptiX is not the default. The stock pinned Nix Blender build is intentionally sufficient for Workbench/Eevee and CPU Cycles, but not a qualified dual-GPU OptiX production renderer. Qualify a CUDA-enabled build separately before claiming dual-GPU Cycles speed.

## Acceptance boundary

Blender correctness, render completion, guide alignment, and H3 generation success are technical evidence only. They never establish Mechanics-Proof. Captured outputs stay `captured-awaiting-user-review` until the user explicitly selects a result; Production promotion remains separate.
