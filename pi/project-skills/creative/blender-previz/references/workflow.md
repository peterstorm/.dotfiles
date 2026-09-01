# Blender Blocking-Video Workflow

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
- do not use proxy mannequins to direct acting, faces, or detail.

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
    handoff/
      CARRIER-CONTRACT.md
      STATE-STILLS-MANIFEST.json
    SHA256SUMS
```

Version instead of overwriting checksum-distinct `.py`, `.blend`, playblast, or still artifacts.

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

- the requested frame rate and delivery aspect ratio from frame one;
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
- no unnecessary detail likely to contaminate a downstream guide.

Reject before animation if any row fails. A fast still correction is cheaper than hundreds of wrong frames.

## Animation and self-check

Animate only the transforms necessary to show camera and mechanism. Proxy acting should remain absent unless a body translation is itself the scored spatial event.

Review both the playblast and sampled frames. Check camera discontinuity, clipping, speed, support loss, early reaction, hidden contact, and unintended object motion. Feedback changes one cause at a time. Update `PROGRESS.json` only after evidence exists; promote reusable corrections into `LEARNINGS.md` before later workers launch.

## Handoff package

The consuming skill declares the render targets: frame rate, aspect ratio, exact frame count, and which timeline positions need exported state stills. Deliver:

- the approved playblast at exactly those targets;
- `CARRIER-CONTRACT.md` — what the video proves (camera path, spacing, screen order, contact order, mechanism timing, screen direction) and what it must never carry forward (identity, anatomy, wardrobe, materials, color, lighting, acting, world design);
- `STATE-STILLS-MANIFEST.json` — each exported still, its exact frame index, and the state it evidences;
- checksums for every artifact.

Raw neutral geometry is intentional: it makes the spatial mechanism legible without asserting appearance. Everything downstream — carrier-versus-guide selection, reference stacks, prompt authoring, generation profiles, and generation QA — belongs to the consuming skill (`h3-prompt-distillation` for local H3 production) and its runbooks.

## Rendering strategy on RTX PRO 6000 Blackwell

For previsualization, use Workbench or Eevee. Minimal blockouts should render quickly and gain more from low scene complexity than from photoreal settings. The installation smoke test rendered four 960×544 Eevee frames in one Blender process in **1.396 seconds wall time** while the Qwen container remained active; that default-cube result proves the fast path, not the cost of a real scene. Eevee normally uses one graphics device, so two GPUs do not automatically halve one-shot render time. Parallelize independent shots only after the shot plan is locked and GPU ownership is available.

Cycles/OptiX is not the default. The stock pinned Nix Blender build is intentionally sufficient for Workbench/Eevee and CPU Cycles, but not a qualified dual-GPU OptiX production renderer. Qualify a CUDA-enabled build separately before claiming dual-GPU Cycles speed.

## Acceptance boundary

Blender correctness, render completion, and playblast approval are spatial evidence only. They never establish Mechanics-Proof, and they say nothing about what a generative model will do with the carrier. Generation, its QA, and Production promotion belong to the consuming skill and remain separate user decisions.
