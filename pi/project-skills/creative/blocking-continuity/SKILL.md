---
name: blocking-continuity
description: "Plans and verifies multi-character screen geometry for locally generated scenes. Use for blocking maps, staging diagrams, cockpit layouts, band formations, fight geography, eyelines, screen direction, entrances, trajectories, or recurring positions across shot sizes. Produces a geometry-only blocking contract, normalized coordinates, deterministic map specification, keyframe checks, local-model A/B guidance, and fail-closed spatial QA. Pairs with cinema-director and ensemble-action-production; it owns spatial disposition, not visual style or character design."
license: MIT
compatibility: "Pi project skill; diagrams are planning evidence by default. Direct conditioning of Krea 2 or MiniMax H3 with a diagram requires per-workflow style-bleed qualification."
---

# Blocking Continuity

A blocking map describes **where**, **facing which way**, **at what scale**, and **when movement occurs**. It must not become a competing style reference.

The safe path is:

`scene geography → normalized blocking contract → human-readable map → Krea keyframe → spatial QA → H3 clip → sampled-frame QA`

A diagram is planning evidence by default. Do not feed it directly into a generation graph until an A/B test proves that it improves geometry without leaking line work, colors, labels, or background artifacts.

## Ubiquitous language

- **Blocking contract** — the authoritative spatial specification for all principals and anchors in one shot.
- **Principal** — a character, vehicle, creature, or hero object whose position matters.
- **Anchor** — stable architecture or furniture used to describe positions.
- **Normalized coordinate** — an `(x, y)` position in frame space from `0.0` to `1.0`.
- **Facing vector** — the principal's facing direction in screen space.
- **Screen side** — left, center, or right as seen by the camera.
- **Cross** — a principal's motivated move from one mark to another.
- **Trajectory** — a path for a principal, prop, projectile, or camera.
- **Re-anchor** — a post-cut statement of positions, eyelines, and screen direction.
- **Style bleed** — diagram appearance contaminating the generated shot.
- **Spatial proof** — visible evidence that count, positions, facing, scale, and paths are correct.

## Hard rules

1. **Geometry only.** Maps do not define face, wardrobe, materials, lighting, location texture, or grade.
2. **One principal ID per entity.** Use stable IDs such as `A`, `B`, `C`; never rename within a sequence.
3. **IDs live in metadata, not rendered pixels.** Do not draw letters, labels, or typography on a conditioning map.
4. **Coordinates are explicit.** Prose such as “near her” is insufficient when position matters.
5. **Crops are geometry.** Record which body parts or vehicles are outside frame; never complete them silently.
6. **Props are anatomically anchored.** Record contact relative to hand, shoulder, throat, hip, seat, control, or socket.
7. **Re-anchor after every cut.** Shot size or camera changes require a new blocking contract.
8. **One motivated cross per short clip.** Complex exchanges become separate clips.
9. **Reference order is not a guarantee.** Local H3 may not honor “position only”; qualification evidence controls use.
10. **Fail closed.** Wrong count, swapped identities, screen-direction reversal, style bleed, or unverifiable positions reject the shot.

## Blocking contract

Use normalized image coordinates with origin at top-left.

| ID | Identity reference | x | y | visible scale | facing | gaze target | pose | crop | anchor/contact |
|---|---|---:|---:|---|---|---|---|---|---|

Add anchors:

| Anchor | Bounds `(x1,y1,x2,y2)` | Function | Must remain fixed |
|---|---|---|---|

Add motion only when required:

| Path | Principal | Start | Trigger | Route | End | Duration | Forbidden crossing |
|---|---|---|---|---|---|---:|---|

## Diagram specification

For a generated or deterministic planning map:

- white or transparent neutral background;
- thin outline figures;
- muted, distinct outline color per principal;
- no fills, shading, texture, labels, letters, or typography;
- only anchors required to understand geometry;
- exact aspect ratio and crop of the target shot;
- paths drawn separately from identity silhouettes;
- versioned filename and manifest entry.

The color is a planning handle only. It never defines wardrobe or grade.

## Safe local use modes

### Mode A — planning only (default)

Use the map to write the Krea prompt and inspect the resulting keyframe. Do not attach the map to Krea or H3. This has zero diagram-style contamination risk.

### Mode B — Krea composition reference (qualification required)

A/B against Mode A with the same seed and prompt. Accept direct map conditioning only if:

- count and positions improve;
- identity and wardrobe do not drift;
- map colors do not enter wardrobe or lighting;
- no line/grid/white-background artifacts appear;
- the full-resolution result passes visual inspection.

### Mode C — H3 reference image (experimental)

Do not combine a map with multiple identity images in a production REF2VA graph until tested. A map consumes reference capacity and may compete with identity/style signals. Prefer an accepted Krea keyframe that already embodies the blocking.

## Shot connector

Describe positions positively without graphic vocabulary:

```text
BLOCKING CONTRACT
A: [identity], mark (x,y), [screen side], [scale/crop], facing [direction], gaze to [target].
B: [identity], mark (x,y), [screen side], [scale/crop], facing [direction], gaze to [target].
Anchors: [fixed architecture/furniture].
Movement: [principal] crosses from [start] to [end] only after [trigger].
All visual style, identity, wardrobe, lighting, and environment come from the approved keyframe and canonical references. Positions remain fixed until the scripted trigger.
```

Do not mention diagram colors in the final video prompt unless the diagram is an attached, qualified reference.

## Continuity across cuts

For every cut, record:

- camera side of the action axis;
- principal order from frame-left to frame-right;
- eyeline direction;
- nearest/farthest principal;
- entrance and exit edges;
- any deliberate axis crossing and its establishing shot.

A tighter shot inherits the previous geography unless an on-screen move changes it.

## Spatial QA

Inspect the accepted keyframe before video. Then inspect at least nine frames across the H3 result, plus dense samples around movement or contact.

| Invariant | Verdict | Evidence |
|---|---|---|
| Correct principal count | PASS / REJECT / UNVERIFIABLE | frame/timestamp |
| IDs remain attached to the correct identities | PASS / REJECT / UNVERIFIABLE | crops |
| Marks and screen-side order match | PASS / REJECT / UNVERIFIABLE | frame/timestamp |
| Facing and eyelines are coherent | PASS / REJECT / UNVERIFIABLE | frame/timestamp |
| Scale and crop match the contract | PASS / REJECT / UNVERIFIABLE | frame/timestamp |
| Cross begins only on its trigger | PASS / REJECT / UNVERIFIABLE | before/after frames |
| No unplanned identity swap or collision | PASS / REJECT / UNVERIFIABLE | timestamps |
| No diagram style/color contamination | PASS / REJECT / UNVERIFIABLE | full frames |

All critical rows must pass. `UNVERIFIABLE` rejects the shot.

Load `references/blocking-contract-template.md` for the production artifact.
