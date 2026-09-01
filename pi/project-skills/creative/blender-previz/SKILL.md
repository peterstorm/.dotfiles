---
name: blender-previz
description: "Builds and reviews minimal Blender mechanics previsualization for AI-film shots, then hands an approved playblast to local MiniMax H3 Reference-to-Video or uses sparse guide frames when that carrier is preferable. Use for Blender, 3D blockouts, previsualization, animatics, difficult lenses or framing, camera paths, character spacing, moving architecture, contact geometry, mechanisms, Blender MCP interaction, viewport review, contact sheets, playblasts, or converting a Blender scene into an H3 REF2VA video carrier or two/four-guide inputs. Not for face design, acting, dialogue performance, detailed final rendering, or ordinary shots that a keyframe and prompt already solve."
license: MIT
compatibility: "Pi project skill, available only from ~/dev/creative. Live authoring requires its pinned pi-mcp-adapter and .mcp.json plus blender-mcp-session running in Blender 5.2 on desktop. The wrapper supplies a private virtual GUI when the workstation is headless."
---

# Blender Mechanics Previz

Blender is a spatial instrument, not the final image maker. Use it only when a shot is difficult because of **projection, framing, spacing, support/contact, a mechanism, a transition, or a camera path**. For faces, acting, dialogue, wardrobe nuance, or a simple camera move, stay in the accepted Krea/MiniMax pipeline.

Read [the canonical workflow](references/workflow.md) before creating or changing a scene.

## Authority boundary

- **Blender owns:** lens hypothesis, camera and object transforms, scale, screen direction, spacing, supports, contact planes, occlusion, mechanism states, and candidate timeline anchors.
- **Blender is never acting authority.** Proxy motion may show only the spatial event necessary to explain a mechanism. It does not author face, gaze, gesture, emotion, performance, wardrobe detail, or final world texture.
- **MCP is the live authoring surface.** It inspects the open scene, executes small reviewed Blender-Python changes, and returns viewport screenshots.
- **The CLI is the render surface.** Save source and `.blend`, then render deterministic stills/playblasts outside the conversational socket.
- **MiniMax is final-motion authority, subject to review.** Local REF2VA can encode the full Blender playblast as `<Video 1>` through `MiniMaxH3ReferenceToVideo`; treat camera, timing, poses, support, and mechanism as declared carrier roles, not guaranteed pixel-space transfer. Two/four still guides remain an alternate anchor strategy.
- Every retained Blender or H3 result is Development evidence. A completed H3 capture remains `captured-awaiting-user-review`, `authority: none`, and `semanticAcceptance: false` until explicit user selection.

## Hard rules

1. Pass the eligibility gate before opening Blender. Record the hard problem and exhaust the cheaper ladder first: drawing/storyboard, accepted reference still, generated keyframe, or a simple camera-board tool. Open Blender only when those cannot solve it.
2. Keep one shot per `.blend`; mechanisms shared by shots may have a separate versioned source scene.
3. Reconstruct a reference mechanism before inventing a remix: **reference → mechanism reconstruction → original remix**.
4. Keep geometry minimal: neutral proxy materials, stable IDs, only architecture needed for parallax/contact, no faces, textures, decorative clutter, or simulated acting.
5. Save reviewable Python source beside every `.blend`. MCP code is not the only record of a scene.
6. Render a contact sheet before animation. Approve setup, event/contact, consequence, lens, crop, and spacing before paying for all frames.
7. Inspect before and after every meaningful MCP mutation with scene info and a viewport screenshot.
8. Execute small idempotent Python chunks. Name created datablocks deterministically; update-or-replace by name instead of accumulating duplicates.
9. Keep the add-on socket on desktop loopback. Pi reaches the MCP stdio process through SSH; never open TCP 9876 in the firewall.
10. Telemetry and external asset integrations stay disabled. Do not install downloaded add-ons or run code copied from unreviewed scenes.
11. Plan and give corrective feedback before fan-out. The parent owns sequence-level `PROGRESS.json` and `LEARNINGS.md`; independent-shot workers read both, self-check their output, and never edit shared files.
12. Generation success, a pretty render, or a close camera match never establishes Mechanics-Proof or Production authority.

## Start a live session

Start Pi from the exact project root; the skill and adapter are intentionally absent elsewhere:

```bash
cd ~/dev/creative
pi
```

From there, start Blender on `desktop` in a durable tmux session:

```bash
ssh desktop 'tmux new-session -d -s blender-previz blender-mcp-session'
```

Pass an absolute `.blend` path after `blender-mcp-session` when resuming a scene. With no desktop display, the wrapper creates a private non-TCP Xvfb display so Blender still has the GUI event loop required by MCP. It enables the pinned add-on, disables telemetry and network asset integrations, and starts the loopback server. Stop it explicitly with `ssh desktop 'tmux kill-session -t blender-previz'`.

From Pi on `homelab`, connect through the project-installed adapter:

```text
mcp({ connect: "blender" })
mcp({ tool: "blender_get_scene_info", args: { user_prompt: "Inspect before editing" } })
mcp({ tool: "blender_get_viewport_screenshot", args: { max_size: 1000, user_prompt: "Check framing and spacing" } })
```

Use `blender_execute_blender_code` only after reviewing the exact code. Its approval gate should be granted once per trusted session, never globally. After each mutation, inspect scene info and screenshot again.

## Shot loop

1. **Eligibility:** name the lens/framing/spacing/mechanism uncertainty.
2. **Reference study:** isolate one rights-cleared source shot, select only its useful interval, and make a contact sheet. Start around three samples per second, then add exact transition/contact frames; identify camera and mechanism, not surface style.
3. **Mechanism reconstruction:** recreate the source mechanism as closely as neutral geometry permits, compare it frame by frame, and prove the state sequence before invention.
4. **Original remix:** create an original location/appearance sheet, then transplant the understood mechanism into that geography and blocking.
5. **Static review:** render setup, load, event/contact, and consequence stills as a contact sheet before animation.
6. **Animation review:** animate only required camera/object transforms; add small deterministic camera imperfection after the clean path works.
7. **Playblast review:** inspect full-frame continuity and a sampled contact sheet. Revise one cause at a time.
8. **Prepare the carrier:** render the approved 24 fps Blender playblast to exactly 124 or 362 frames and upload it as `<Video 1>`. Use the six profiles under `minimax-h3-blender-ref2va-development`: BF16 quality, task-matched Turbo 4-step, or dedicated PDD 8-step. Compare acceleration with identical carrier, appearance references, prompt, dimensions, and paired seed; never stack Turbo and PDD.
9. **Choose alternatives deliberately:** use the 124-frame profiles for precise mechanics and controlled comparisons; use 362 frames only when the long camera/edit timeline is load-bearing. Use two still guides for endpoint-dominant shots or four for setup/load/event/consequence when sparse states matter more than the complete path. Resolve raw proxy stills through Krea if they cause style bleed.
10. **H3 prompt:** declare the shot purpose and attention target; state what `<Video 1>`, each picture, or each guide owns and must not own; then separately state explicit acting/action, causal dependencies, timing, sound/music cues, and positive/negative locks.
11. **Capture and QA:** use the generic ComfyUI capture path, compare sampled frames against the Blender contract, and await explicit user review.

## Completion report

Report:

- eligibility reason and scored variable;
- source reference and rights status;
- Blender/Python versions and source checksums;
- lens/sensor hypothesis and camera path summary;
- proxy IDs, scale, support/contact, and mechanism states;
- static and animation self-check results plus learnings promoted for later shots;
- selected H3 carrier: REF2VA source-video checksum and role, or sparse guide frames and whether raw or Krea-resolved;
- H3 workflow/profile and prompt-package path;
- geometry, interpolation, identity, and style-bleed findings;
- Development status and unresolved authority limits.
