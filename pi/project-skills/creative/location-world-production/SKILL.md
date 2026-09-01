---
name: location-world-production
description: "Builds and qualifies canonical locations, clean plates, per-scene light contracts, production-wide look continuity, ambient environment motion, and persistent set state for locally generated scenes. Use when a scene needs an establishing or reverse plate, a set that recurs across shots, entrances/exits and sightlines that blocking depends on, time-of-day and light-direction continuity across cuts, a palette/grade/lens register that spans the production, weather or ambient motion, or damage and dressing that later scenes must inherit. Produces a location bible, personless plate package, light contracts, look bible, ambient-motion contract, and fail-closed cross-shot continuity QA. Pairs with blocking-continuity, cinema-director, prop-continuity, and ensemble-action-production; it owns places, light, and look — not camera, characters, or hero props."
license: MIT
compatibility: "Pi project skill for local Krea 2 plates and MiniMax H3 clips. Plates are generation references and QA evidence; any diagram or map conditioning follows the same style-bleed qualification discipline as blocking-continuity."
---

# Location World Production

A location is not locked by one attractive establishing render. Production needs visible evidence that geography, light, look, and set state survive every cut.

This skill owns:

`world brief → location canon → clean plate package → light contract → look bible → ambient-motion contract → cross-shot continuity QA`

It complements `blocking-continuity` (screen geometry within a frame), `cinema-director` (camera language), `prop-continuity` (hero objects and receptacles), and the character asset skills. This skill owns the place itself, the light falling on it, and the production-wide look.

## Ubiquitous language

- **Location canon** — the authoritative geography of one place: architecture, fixed anchors, bounds, entrances, exits, sightlines, scale anchors, and materials.
- **Clean plate** — an accepted personless image of the location in one declared state, at reference resolution.
- **Reverse plate** — a plate proving the off-axis side of the same geography.
- **Insert plate** — a close plate proving a mechanism, doorway, control surface, or material the wide cannot resolve.
- **Set state** — the mutable condition of dressing, doors, damage, debris, weather residue, and practicals that a scene inherits.
- **Light contract** — the per-scene statement of key direction, quality, color register, practicals, time-of-day, and weather.
- **Practical** — a light source visible in frame whose on/off state and intensity are continuity facts.
- **Look bible** — the production-wide palette, grade register, lens/stock language, and atmosphere vocabulary.
- **Look token** — the short reusable prompt fragment that carries the look bible into a generation verbatim.
- **Ambient motion** — environment movement such as weather, foliage, flags, smoke drift, distant traffic, or background crowd texture that is not causally owned by a primary action.
- **Continuity proof** — visible evidence that geography, light, look, and set state survive a cut.

## Hard rules

1. **One geography.** A named location has one canonical layout. Entrances, exits, windows, and sightlines never migrate between shots without an on-screen cause.
2. **Plates are personless.** Clean plates contain no principals and no readable faces. A hero prop appears only when it is architectural canon, and then through `prop-continuity`.
3. **Blocking anchors resolve here.** Every anchor a `blocking-continuity` contract references must exist in the accepted location canon. Never let a keyframe invent load-bearing architecture.
4. **Light has a stated source.** Every scene records key direction, quality, color register, time-of-day, and weather. "Cinematic lighting" and "moody atmosphere" are not contracts.
5. **Light survives the cut.** Within a scene, key direction, time-of-day, and practical states persist across shot sizes and camera sides unless a motivated change is scripted and visible.
6. **The look is production-wide.** Palette, grade, and lens/stock register come from the look bible. A single shot does not restyle the film.
7. **Ambient motion is assigned, not assumed.** Weather, foliage, flags, smoke, and background traffic are stated with direction and intensity, or the air is explicitly still. Causal debris, impact dust, and force-driven effects belong to `action-physics-production`.
8. **Set state is inherited.** Scene N+1 begins from scene N's accepted end state. Damage, opened doors, displaced dressing, weather residue, and practical states persist until an on-screen event changes them.
9. **Version, never overwrite.** Changed geography, light policy, look revision, model path, or plate lineage creates a new numbered version. Earlier plates, prompts, seeds, and rejections remain preserved.
10. **Fail closed.** Migrated architecture, a reversed key light, an unmotivated weather or palette change, or unverifiable geography rejects the shot. Missing evidence is `UNVERIFIABLE`, never `PASS`.

## Stage 0 — world brief and originality gate

Before any plate generation, record:

- the narrative function of the place and every scene it must serve;
- the required states: intact/damaged, day/night, empty/dressed, sealed/breached;
- originality: no recreation of another property's signature set, skyline, or interior whose recognizability depends on that property;
- the new immutable version identifier, model path, workflow revision, seed policy, and output root;
- which existing location version, if any, this supersedes and why.

## Stage 1 — location canon

Create the location bible from [the location bible template](references/location-bible-template.md). Resolve every `[TBD]` that affects geometry, light logic, or scale before generating plates.

The canon must include:

- a prose geography readable without images: rooms/zones, their connections, and approximate dimensions in one unit system;
- an anchor table compatible with `blocking-continuity`:

| Anchor | Position (zone + relative placement) | Function | Entrance/exit | Must remain fixed |
|---|---|---|---|---|

- sightlines: which anchors are visible from each principal playing area, and which are hidden;
- permitted action axes and the default camera side per axis;
- at least two human-scale anchors (door height, seat, rail, console) visible in ordinary coverage;
- material system per surface: floor, walls, glass, metal, fabric, terrain;
- fixed light sources: windows, sky access, practicals, and their world positions;
- prohibited lookalikes and known model failure modes for this kind of space.

## Stage 2 — clean plate package

Generate separate personless plates, not one crowded sheet:

1. **Establishing plate** — the canonical wide proving overall geography in the location's default state.
2. **Reverse plate** — the opposing view proving the off-axis side, including whatever the establishing plate hides.
3. **Insert plates** — one per mechanism, doorway, control surface, or material that blocking, props, or story comprehension needs at close range.
4. **State variants** — one plate per required state (damaged, night, breached), each derived from the accepted default plate as its lineage parent.

### Plate acceptance

Inspect at full frame and useful crops. `PASS` requires:

- geography matches the written canon: every anchor present, placed, and proportioned;
- entrances, exits, and sightlines match the canon exactly;
- human-scale anchors read at plausible scale;
- no person, readable face, text, logo, or watermark;
- material system as specified rather than generic;
- the plate's declared light state actually visible: key direction, practicals, and time-of-day;
- resolution sufficient for downstream crops and reference use.

A beautiful plate with migrated architecture is `REJECT`. An occluded required anchor is `UNVERIFIABLE`.

## Stage 3 — light contract

Write one contract per scene before its keyframes:

```text
LIGHT CONTRACT — [SCENE]
Time and weather: [time-of-day], [weather state].
Key: from [geographic direction — e.g. the hatch side, the window wall], [hard/soft], [color register].
Fill and ambience: [level and character of non-key light].
Practicals: [each visible source and its on/off state and intensity].
Continuity: matches [adjacent scene or plate]; changes only when [motivated on-screen event].
```

Rules:

- state key direction relative to the geography, not only screen-left/right — camera sides change between shots while the world does not;
- when the camera crosses the axis, restate the expected screen-side of the key so QA can check the flip is geometrically correct rather than a model error;
- a practical that is on in one shot is on in the next unless someone visibly changes it;
- a time-of-day change inside a scene requires an explicit narrative reason.

## Stage 4 — look bible

Define once per production, versioned:

- palette: three to five anchor colors with their assigned owners (world, wardrobe accent, threat cue), coordinated with the ensemble group palette;
- grade register: contrast, saturation, black level, and highlight behavior in plain language;
- lens/stock/atmosphere vocabulary shared with `cinema-director`;
- one **look token** — a short prompt fragment carrying the above — entered verbatim into Krea and H3 prompts;
- forbidden drift: the specific failure looks for this production (e.g. sudden teal-orange grade, heavy vignette, changed grain, glossy render sheen).

The look token is the only sanctioned way style language enters a scene prompt. Shot-level prompts may not add competing style vocabulary.

## Stage 5 — ambient-motion contract

Per scene, name each active channel with direction and intensity, or declare still air:

- weather: precipitation type, direction, and density;
- air: wind direction and strength, and which materials show it (flags, foliage, garments, smoke, dust);
- background life: distant traffic, birds, machinery, or crowd texture, kept sparse and non-repeating;
- water, fire, or steam sources and their steady-state behavior.

Rules:

- wind direction agrees with garment and hair behavior (`human-motion-realism-production`) and with any causal debris (`action-physics-production`);
- ambient motion must never upstage or substitute for the primary action;
- background crowd texture gets at most one readable behavior per region — no synchronized loops, no principal-quality detail;
- ambient channels persist across cuts within a scene exactly like light.

## Stage 6 — cross-shot continuity QA

Inspect the accepted keyframe before video. Then inspect at least nine chronological frames of the H3 result, plus dense samples around any light change, weather event, or state transition.

| Invariant | Verdict | Evidence |
|---|---|---|
| Geography matches canon: anchors present, placed, proportioned | PASS / REJECT / UNVERIFIABLE | frames/crops |
| No architecture migration, invention, or silent removal | PASS / REJECT / UNVERIFIABLE | adjacent-shot comparison |
| Entrances, exits, and sightlines match canon | PASS / REJECT / UNVERIFIABLE | frames |
| Human-scale anchors stay consistent | PASS / REJECT / UNVERIFIABLE | crops |
| Key direction and quality match the light contract | PASS / REJECT / UNVERIFIABLE | frames |
| Light and time-of-day survive the cut | PASS / REJECT / UNVERIFIABLE | cross-cut comparison |
| Practicals hold state | PASS / REJECT / UNVERIFIABLE | crops |
| Palette and grade stay within the look bible | PASS / REJECT / UNVERIFIABLE | full frames |
| Ambient motion matches the contract in direction and intensity | PASS / REJECT / UNVERIFIABLE | intervals |
| No unmotivated weather or atmosphere change | PASS / REJECT / UNVERIFIABLE | intervals |
| Set state inherited from the prior accepted scene | PASS / REJECT / UNVERIFIABLE | last/first proof frames |

All critical rows must pass. `UNVERIFIABLE` rejects the shot.

## Stage 7 — targeted repair

- migrated or invented architecture → regenerate the keyframe from the accepted plate lineage; do not repair geography in prose alone;
- reversed or wandering key → restate the key in geographic terms, add the expected screen-side for this camera position, and re-anchor;
- palette or grade drift → strengthen the look token, remove competing style words from the shot prompt, and compare against the same seed;
- ambient overreach → cut channels until the primary action reads, then add back one at a time;
- set-state reset → derive the keyframe from the prior scene's accepted end-state frame or the matching state-variant plate;
- unresolvable wide → add an insert plate rather than accepting `UNVERIFIABLE` geography.

Create a new numbered version for any changed canon, plate lineage, light policy, or look revision. Preserve rejected plates and ledgers.

## Pre-delivery checklist

- [ ] Location bible complete; no geometry-affecting `[TBD]` remains
- [ ] Establishing, reverse, and required insert plates accepted personless
- [ ] Every blocking anchor resolves to canon architecture
- [ ] State variants derive from accepted lineage parents
- [ ] Every scene has a light contract with a geographic key direction
- [ ] Practical states tracked across the scene
- [ ] Look bible and look token versioned; shot prompts carry no competing style language
- [ ] Ambient-motion contract written or still air declared
- [ ] Wind, garments, and debris agree across owning skills
- [ ] Cross-shot QA passed for geography, light, look, ambient, and set state
- [ ] Set state chains scene to scene without silent resets
- [ ] Versions, prompts, seeds, plates, and rejections preserved
