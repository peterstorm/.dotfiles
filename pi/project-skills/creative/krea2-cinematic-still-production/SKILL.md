---
name: krea2-cinematic-still-production
description: "Authors and qualifies cinematic photoreal stills with local Krea 2 for character plates and sheets, personless location plates, character-bearing establishing keyframes, and scene-aligned H3 references. Use when a Krea image looks generic, glossy, editorial, badly framed, shot through the wrong lens, insufficiently photographic, or identity-unsafe; when camera, focal length, exposure, composition, reference roles, skin, materials, or lighting need explicit control; or before generating a character sheet, location shot, establishing shot, or scene keyframe. Produces a typed asset mode, reference-role map, exact camera contract, concise Krea prompt, and fail-closed visual QA."
license: MIT
compatibility: "Pi project skill for local Krea 2 BF16 and Krea 2 Turbo still workflows. Coordinates identity-realism-production, wardrobe-asset-production, location-world-production, blocking-continuity, and cinema-director without taking over their authority."
---

# Krea 2 Cinematic Still Production

"Cinematic, ultra realistic" is not a prompt. A production still needs explicit authority routing, optics, composition, light, materials, and visible acceptance evidence.

This skill owns:

`asset mode → reference-role map → camera contract → visible scene contract → Krea prompt → full-frame/crop QA → accepted still or rejection`

It owns Krea still-image direction and qualification. It does not own face canon, wardrobe canon, location geography, blocking mechanics, video motion, or user acceptance.

## Asset-mode algebra

Choose exactly one mode before writing a prompt. Mixed modes are invalid.

1. **Identity-bearing character plate** — one complete character, one readable face, controlled background and reference lighting. Used for front wardrobe/body evidence or an accepted character-sheet source.
2. **Face-free construction plate** — front, rear, or detail evidence for body/wardrobe/prop construction. No readable face.
3. **Personless location plate** — establishing, reverse, insert, or state plate proving geography, materials and light. No people or readable faces.
4. **Character-bearing establishing keyframe** — scene-aligned composition containing principals and world. Used as a Krea keyframe or H3 appearance reference; it is not a clean location plate.
5. **Scene insert keyframe** — one close compositional proof of a face, hand, prop interface, doorway, or material that a wide cannot verify.

A character-bearing image must never be labelled a clean plate. A sheet must never substitute for its higher-resolution source plates.

## Authority routing

Write a role map before prompt prose:

| Reference | Owns | Must not own |
|---|---|---|
| accepted face authority | face geometry, skin identity, hairline and personhood | wardrobe, body, location or camera |
| face-free body/wardrobe plate | proportions, silhouette, garments, footwear | face, skin identity, location or camera |
| accepted location plate or Blender frame | geography, anchors, marks and declared composition | face, wardrobe or acting |
| prop plate | design, scale, materials and interfaces | pose, face, world or camera |
| look reference/token | palette, contrast, highlight and atmosphere register | identity, geometry or object invention |

Rules:

- Every reference gets one positive job and an explicit exclusion boundary.
- More references are not automatically better. Remove a reference unless a paired-seed test proves it earns its slot.
- A headless or blank-head source is conditioning evidence only. Generated people remain anatomically complete.
- For a user-owned self-reference, the user's real photograph is the face authority. A generated body or scene face cannot displace it.
- `identity-realism-production` applies only to fictional identities. A consented user self-reference keeps a separate self-reference lineage and does not inherit that skill's fictional-originality gate.
- A clear wrong face is a recast actor. Later close-ups cannot repair that continuity failure.
- In a wide, a face may be identity-neutral through distance, rear/three-quarter attitude, motivated occlusion, shadow, focus falloff or motion blur. It must not be readable as a different person.

## Exact camera contract

Every Krea still declares all fields in [the camera contract template](references/krea-camera-contract-template.md):

- projection;
- horizontal sensor gate;
- focal length and horizontal field of view;
- output dimensions and aspect;
- camera position or height;
- look target, subject distance, pitch and roll;
- aperture/depth-of-field target and focus plane;
- principal normalized screen position, scale and crop;
- fixed perspective constraints.

Focal length alone is incomplete. "Wide angle," "portrait lens," "cinematic framing," and "shallow depth of field" are not camera contracts.

When a Blender frame exists, derive the camera values from it. The frame remains screen-space and geometric authority; written optics prevent Krea from silently substituting an ultra-wide, telephoto, low-angle, dutch, or portrait-bokeh image.

### Default optical starting points

Use only when no accepted camera authority exists:

- full-body character plate: rectilinear 70–85 mm on a 36 mm gate, camera near torso midpoint, level, f/8, enough distance to avoid enlarged head/hands;
- personless environmental establishing plate: rectilinear 28–35 mm on a 36 mm gate, level unless geography requires pitch, f/8–f/11;
- character-bearing environmental keyframe: rectilinear 32–50 mm on a 36 mm gate, f/4–f/8 according to cast depth;
- identity close insert: rectilinear 85–105 mm on a 36 mm gate, f/4–f/5.6, both eyes within usable focus.

Defaults are proposals, never authority. Record the chosen value and why.

## Photographic reality stack

Replace style slogans with visible capture facts.

### 1. Light and exposure

- Name key direction relative to world geography, not only screen-left/right.
- State source size/quality, fill level, practical state, weather and time-of-day.
- Preserve highlight detail and dimensional shadow information; do not flatten everything with fill.
- One motivated lighting design per scene. No competing rim, beauty and volumetric effects merely to look expensive.

### 2. Human material response

- Skin has fine pores, peach fuzz, subtle tone variation, localized translucency and restrained natural specular response.
- Eyes have moist highlights without glass or doll appearance.
- Hair resolves as grouped masses plus individual flyaway strands, not a plastic helmet.
- Hands, ears, neck and face share one plausible skin and blood-flow register.
- Realism does not mean automatic beautification, age shifting, face slimming, fashion retouching or symmetry correction.

### 3. Surface separation

Name the physical response of every hero material: woven wool, cotton jersey, oxidized steel, painted concrete, chain-link wire, rubber, leather, glass, asphalt, wood, foliage. Materials must differ through roughness, weave, edge wear, compression, reflection and subsurface behavior—not through adjective stacking.

### 4. Optical behavior

- Rectilinear perspective unless another projection is explicit.
- Natural focus transition, restrained aberration and plausible flare only when a visible source motivates it.
- Grain or sensor texture stays fine and subordinate to real detail.
- Avoid aggressive vignette, crunchy clarity, HDR halos, fake bloom, wax skin, CGI cleanliness and uniform micro-sharpening.

### 5. Lived-in evidence

Locations need bounded wear appropriate to their use: edge chips, dust in recesses, tire marks, stains, patched paint, weathering and irregular dressing. Random clutter is not realism. Every added object needs a location or story function.

## Mode-specific construction

### Identity-bearing character plate

Coordinate `wardrobe-asset-production` and `identity-realism-production`.

- exactly one person, one body and one readable face;
- crown through soles when full-body evidence is required;
- squared stance and clear hands unless a performance pose is explicitly the asset;
- neutral background and broad reference illumination;
- accepted face authority gets its own reference role;
- body/wardrobe gets a separate face-free role when direct generation has failed;
- use separate front, rear and details; assemble a sheet only after source plates pass.

A beautiful different person is `REJECT`.

### Personless location plate

Coordinate `location-world-production`.

- no people or readable faces;
- geometry and anchors match the location canon;
- human scale is proven through architecture or ordinary objects, not extras;
- explicit light contract and look token;
- reverse and insert plates are separate generations at declared camera positions.

### Character-bearing establishing keyframe

Coordinate `blocking-continuity`, `location-world-production`, identity and wardrobe owners.

- record exact principal count and stable IDs;
- give every principal a normalized mark, scale, facing, gaze, pose and crop;
- declare the visual anchor and permitted center deviation;
- arrange supporting cast and props around that anchor;
- use the accepted world lineage and camera contract;
- if a principal face is readable, supply its accepted identity authority;
- if identity cannot be held at this scale, design an identity-neutral but anatomically complete view rather than accepting a generic replacement face.

A still implies action only. It cannot prove mechanics, timing, contact, acceleration, ballistics or causality.

## Krea prompt order

Use [the prompt contract template](references/krea-prompt-contract-template.md). Keep the final prompt concise and front-loaded:

1. asset mode, exact count and purpose;
2. reference-role assignments and exclusion boundaries;
3. screen geometry and composition;
4. exact camera contract;
5. subject identity/body/wardrobe visibility;
6. world anchors and light contract;
7. physical materials and photographic reality stack;
8. short failure-mode tail containing only observed risks.

Do not repeat a fact in multiple sections. Do not ask the model for internal production context, authority labels, checksum language or acceptance states.

## Model and iteration policy

- Local Krea 2 only through serialized `creative-model-phase` ownership.
- Krea 2 Turbo is the composition/calibration path when its pinned workflow contract applies.
- Once composition and reference routing pass, use the pinned full-quality BF16 path for a final-quality still when the quality gain is required.
- Change one scored variable per paired retry: seed, reference count/strength, camera wording, composition wording, or sampler profile. Do not change all at once.
- Preserve every graph, prompt, seed, output, rejection, user decision and checksum under a new numbered artifact path.

## Full-frame and crop QA

Technical completion is never visual acceptance. Inspect:

| Gate | Required evidence |
|---|---|
| mode | output is the declared asset type; no sheet/plate/keyframe role confusion |
| count | exact people, faces, props and panels |
| composition | marks, visual anchor, center tolerance, scale and crop |
| optics | perspective, lens feel, height, pitch, roll, focus and distortion match contract |
| identity | every readable principal matches its own accepted authority; no recast or bleed |
| anatomy | complete coherent bodies, hands, feet, head and contacts |
| geography | anchors, exits, scale and set state match canon |
| light | direction, quality, practicals, weather and exposure match contract |
| materials | skin, hair, fabric, metal, glass, rubber and surfaces remain physically distinct |
| artifacts | no pseudo-text, watermark, collage, duplicate, inset, HDR halo, wax skin or CGI sheen |
| downstream role | still proves only what its role permits |

Verdicts are `PASS`, `REJECT`, or `UNVERIFIABLE`. Every critical row must visibly pass. Only explicit user acceptance can promote the asset.

## Pre-delivery checklist

- [ ] Exactly one asset mode selected
- [ ] Reference role map complete with exclusion boundaries
- [ ] Exact camera contract written; no generic lens language
- [ ] Composition uses normalized marks and a declared visual anchor
- [ ] Readable faces resolve to accepted identity authorities
- [ ] Headless references remain input-only; output anatomy is complete
- [ ] Light source, direction, quality, weather and practicals stated
- [ ] Hero materials have distinct physical responses
- [ ] Prompt is front-loaded, concise and non-repetitive
- [ ] Turbo is used for calibration and full-quality BF16 only when warranted
- [ ] Full-frame and useful crops inspected against every gate
- [ ] Rejected evidence preserved and barred from downstream use
- [ ] User acceptance recorded before promotion
