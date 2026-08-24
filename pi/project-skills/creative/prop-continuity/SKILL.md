---
name: prop-continuity
description: "Builds and verifies hero props, tools, weapons, vehicles, controls, doors, sockets, and other objects that characters handle or mechanically interact with in AI-generated image and video scenes. Use whenever a prop must keep one design, size, orientation, grip, mating interface, or state across shots; when an action involves inserting, turning, opening, carrying, assembling, or operating something; when scene content must be visually verified rather than inferred from prompts; or when a film risks repetitive action, impossible contact, prop drift, or incoherent coverage. Produces a prop bible, clean reference pack, scale and interface evidence, action-coverage plan, frame-sampled semantic QA, and fail-closed acceptance report. Pairs with cinema-director and image-asset skills but owns prop and scene-continuity gates."
license: MIT
compatibility: "Pi project skill; requires local image inspection and ffmpeg/ffprobe or equivalent frame extraction for video QA."
---

# Prop Continuity and Scene Verification

A prompt states intent. It is **not evidence that the render obeyed the intent**.

This skill owns the path from a story's physical object to an accepted scene:

`narrative function → prop canon → clean references → receptacle/world lock → scene action plan → keyframe gate → video → sampled-frame inspection → acceptance report`

Use it with `cinema-director`, `banana-pro-director-30`, or another image/video prompt skill. Those skills own cinematography and prompt grammar. This skill owns:

- whether the prop and its mating object are physically defined;
- whether scale and orientation are coherent;
- whether the screenplay allocates distinct visual actions;
- whether generated frames actually depict the requested action;
- whether a scene is accepted, rejected, or unverifiable.

Never approve a scene from its prompt, seed, filename, successful queue status, clean decode, first frame, or a single thumbnail.

## Ubiquitous language

- **Hero prop** — an object whose identity or operation matters to story comprehension.
- **Receptacle** — the fixed object or interface a prop contacts, enters, turns, latches, rests on, or operates. A socket, lock, holster, hinge, hand, vehicle mount, and control panel are all receptacles in this sense.
- **Working end** — the part of the prop that contacts the receptacle.
- **Control end** — the part the character grips, pushes, pulls, or aims.
- **Mating geometry** — the visible shapes that make prop and receptacle mechanically compatible.
- **Prop state** — one of `separate`, `aligned`, `engaged`, `operating`, `released`, or another explicitly defined story state.
- **State transition** — one physical change from one valid prop state to another.
- **Action occupancy** — the fraction of sampled frames spent on an action.
- **Proof frame** — an inspected frame that visibly proves a required state or transition.
- **Semantic acceptance** — approval based on visible content and temporal behavior, not technical validity.

## Hard rules

1. **Define before rendering.** No scene keyframe involving a hero prop is generated before its prop canon and receptacle canon pass.
2. **One geometry.** The prop has one silhouette, one working end, one control end, one material system, and one scale contract.
3. **Compatible contact.** The working end and receptacle have visibly compatible mating geometry. A vague hole, invisible socket, or contact against an unbroken surface fails.
4. **One risky transition per clip.** Insertion, extraction, latching, loading, unfolding, and mechanical engagement are separate clips unless an explicit start/end-frame method reliably controls the whole chain.
5. **Insert once.** A setup sequence may show insertion in only one scene by default. Later scenes begin from the already-engaged state. Repeating insertion requires an explicit narrative reason.
6. **Limit occupancy.** A mechanical setup action occupies at most 40% of a clip by default. For a five-second clip, insertion should resolve within two seconds; the rest must show consequence, reaction, or a different beat.
7. **No contradictory scale language.** Absolute dimensions, hand-relative ratios, body-relative ratios, and receptacle dimensions must agree before prompting.
8. **Inspect sampled frames.** Every accepted clip needs full-frame and prop-crop evidence across time.
9. **Fail closed.** Missing evidence is `UNVERIFIABLE`, never `PASS`. Any critical invariant that is `REJECT` or `UNVERIFIABLE` rejects the scene.
10. **Acceptance is revocable.** If downstream continuity reveals an earlier miss, reopen and reject the earlier scene rather than explaining the drift away.

## Stage 0 — Story and coverage gate

Before designing the prop, write one row per scene:

| Scene | Dramatic job | Start state | Primary visible action | End state | Forbidden/repeated action | Max occupancy | Proof moments |
|---|---|---|---|---|---|---:|---|

Apply these checks:

- Every scene has one dramatic job expressible without camera language.
- Adjacent scenes have different primary visible actions.
- The sequence alternates setup, effort, observation/reaction, consequence, and resolution as appropriate; it does not merely rename the same hand motion.
- A scene about listening, deciding, noticing, or consequence gives those behaviors most of its runtime.
- Prop manipulation is not used as filler while the real story beat remains invisible.
- Start and end states form a valid chain. Scene N's accepted end state equals scene N+1's start state.
- A prop transition appears only where the table assigns it.

**Reject the screenplay before generation** when three scenes all amount to “the character moves the same object toward the same place,” even if their prose labels differ.

Default action-coverage guidance for a five-second scene:

- establish state: 0.5–1.0s;
- one simple transition: 0.5–2.0s;
- visible consequence or character response: at least 2.0s;
- final readable state: at least 0.5s.

These are defaults, not editing dogma. A deliberate ritual or long take may override them only when the user explicitly chooses that rhythm.

## Stage 1 — Prop canon

Create `prop-bible.md` using [the prop bible template](references/prop-bible-template.md). Resolve all `[TBD]` values that affect geometry before continuing.

The canon must include:

- narrative function and required operations;
- inventory count;
- material, finish, wear, silhouette, and rigid/flexible parts;
- absolute dimensions in one unit system;
- at least two relative scale anchors visible in ordinary shots;
- control end, working end, top, bottom, front, and direction of travel;
- permitted grips and hand placement;
- receptacle location, silhouette, dimensions, and mating geometry;
- valid prop states and legal transitions;
- prohibited lookalikes and known model failure modes.

### Scale consistency check

Translate every scale statement to approximate ratios before accepting it. Examples:

- total prop length ÷ palm length;
- total prop length ÷ forearm length;
- grip width ÷ hand width;
- working-end width ÷ receptacle opening width.

If “28 cm long” conflicts with “shorter than the forearm,” choose one observable contract and rewrite the other. Do not preserve contradictory clauses for emphasis; repetition cannot repair impossible geometry.

Use ratio tolerances rather than pretending perspective permits millimeter measurement. Define a canonical orthographic ratio and a wider in-scene tolerance. A typical starting tolerance is ±10% on the clean scale reference and ±20% in a perspective scene, tightened or widened by the prop's narrative importance.

## Stage 2 — Prop reference pack

Produce two separate artifacts. Never feed the annotated QA artifact to the image/video model.

### A. Clean generation references

Create clean, unlabelled, photoreal reference images on a flat neutral background:

1. front or hero three-quarter view;
2. opposite/rear view;
3. side profile proving thickness and working-end direction;
4. canonical grip view in the character's hand;
5. prop beside a hand/forearm scale anchor without perspective exaggeration;
6. empty receptacle close-up;
7. aligned-but-separate prop and receptacle;
8. correctly engaged final state.

For a small or mechanically ambiguous prop, prefer separate high-resolution images over one crowded sheet. The working end, receptacle opening, and engaged join must each be legible.

### B. Annotated QA sheet

Deterministically compose an inspection sheet from accepted clean images. Add labels, arrows, dimensions, working/control-end markers, ratio measurements, and the valid state sequence. This sheet is for people and visual QA only.

The prop-reference gate passes only when direct inspection confirms:

- the same prop design in every cell;
- unambiguous working-end and control-end orientation;
- agreed scale in hand and beside the body anchor;
- an actually visible receptacle;
- compatible mating geometry;
- a readable engaged state with no intersection, floating, or contact against a solid surface.

## Stage 3 — World and receptacle lock

A hero prop cannot be consistent if its receptacle is invented independently in every shot.

Create an accepted empty world plate or mechanism plate where the receptacle is:

- present in the exact canonical location;
- large enough to resolve at delivery resolution;
- visibly open or mechanically available in the separate state;
- built from the canonical material and geometry;
- unobstructed by the character at the moment the audience must understand it.

Create a close mechanism insert if the wide world plate cannot prove the interface. Never rely on textual claims that a keyhole, socket, latch, or slot exists outside the visible pixels.

## Stage 4 — Scene keyframe gate

Every scene involving the hero prop needs an accepted keyframe before video generation.

Inspect the keyframe at full frame and at a crop containing both hands, prop, and receptacle. Record `PASS`, `REJECT`, or `UNVERIFIABLE` for:

- inventory count;
- prop design;
- scale ratio;
- working-end direction;
- grip and hand anatomy;
- receptacle presence;
- mating geometry;
- assigned start state;
- screen direction and action axis;
- absence of a transition assigned to another scene.

A crop that cannot contain both working end and receptacle makes contact geometry unverifiable. Change framing or generate a dedicated insert; do not accept it on faith.

## Stage 5 — Video plan

For each clip, write:

- exact start state;
- one primary action;
- exact end state;
- earliest and latest allowed transition time;
- required proof frames;
- forbidden actions;
- continuity handoff;
- fallback simplification if the model cannot perform the mechanics.

### Choose controllability over prose

For hard contact mechanics:

1. prefer explicit accepted start and end frames when the model supports them;
2. otherwise begin from an already-engaged state and animate only operation;
3. otherwise split alignment and engagement into separate short clips;
4. otherwise imply the transition off-screen with a cut and show the accepted consequence.

Do not ask a five-second generative clip to discover an invisible socket, align a complex bit, insert it, rotate it, transfer force, animate gears, and preserve identity simultaneously. More prompt clauses do not create more control channels.

## Stage 6 — Frame-sampled semantic verification

After generation, first run technical checks: decode, dimensions, frame rate, frame count, duration, audio, and corruption. Technical success only permits semantic inspection; it never approves the scene.

Extract at least nine evenly spaced frames including 0%, 12.5%, 25%, 37.5%, 50%, 62.5%, 75%, 87.5%, and the final decodable frame. Add denser samples around every contact or state transition.

Create:

- one chronological full-frame contact sheet;
- one chronological crop sheet centered on hands + prop + receptacle;
- individual full-resolution proof frames for start state, transition, end state, and consequence.

Then complete [the scene verification report](references/scene-verification-template.md) by **looking at the extracted images**.

### Mandatory semantic checks

- **Requested content:** the scene visibly performs its assigned dramatic job.
- **Action identity:** the primary action is what the plan named, not an easier substitute.
- **Action occupancy:** sampled frames do not spend too much time on setup or a repeated action.
- **State order:** states occur in legal chronological order, with no spontaneous reset.
- **Prop count:** no duplication, disappearance, fusion, or replacement.
- **Design continuity:** silhouette, material, working end, and control end remain canonical.
- **Scale continuity:** measured ratios stay within the declared perspective tolerance.
- **Orientation continuity:** the working end faces and meets the receptacle; the prop is not reversed or upside down.
- **Receptacle continuity:** the interface exists before contact and remains physically legible during engagement.
- **Contact physics:** no floating, tunneling, impossible intersection, disconnected motion, or rotation around the wrong pivot.
- **Character intent:** gaze, posture, hand placement, effort, reaction, and stillness support the beat.
- **World continuity:** environment, action axis, light, and mechanism state do not reset or drift.
- **Narrative consequence:** the end of the clip visibly changes something the next scene can inherit.

### Action occupancy from samples

Label each sampled frame with the visible action state. Count labels as an approximate temporal measure. If insertion is allowed for at most 40% of a nine-frame sample, no more than three or four samples may show active insertion. If later scenes show insertion despite starting `engaged`, reject them immediately.

Sampling can miss a brief defect. When a critical transition falls between samples, extract every frame or a dense 4–8 fps window around it.

### Verdict semantics

- `PASS` — visible evidence proves the invariant.
- `REJECT` — visible evidence contradicts the invariant.
- `UNVERIFIABLE` — framing, blur, occlusion, or missing evidence prevents a conclusion.

Critical checks require `PASS`. `UNVERIFIABLE` is not “probably okay.”

## Stage 7 — Sequence and final-edit gate

Before assembly, compare adjacent accepted clips:

- last proof frame of scene N against first proof frame of scene N+1;
- prop state, scale, orientation, hand, side of body, and screen position;
- receptacle state and world geometry;
- character posture and gaze;
- whether the next scene repeats the prior transition instead of inheriting it.

After assembly, sample across every cut plus nine frames across the whole film. Verify that the edit tells the planned story without relying on notes or prompts. A technically correct join of semantically rejected clips remains rejected.

## Rejection and repair policy

| Failure | Required repair |
|---|---|
| Repeated insertion or setup | Rewrite coverage; start later clips already engaged or cut directly to consequence. |
| Missing receptacle | Regenerate the world/mechanism plate and keyframe before video. |
| Reversed/upside-down prop | Correct the clean reference orientation and keyframe; do not repair only in prose. |
| Scale drift | Rebuild the in-hand scale reference, reduce perspective change, or use a closer controlled shot. |
| Impossible mating geometry | Redesign prop/receptacle as one compatible pair and regenerate both. |
| Complex interaction collapses | Split the transition, use start/end frames, or imply it across a cut. |
| Action occupies most of scene | Shorten the transition and allocate runtime to reaction or consequence. |
| Critical detail occluded | Reframe or add an insert; classify current render `UNVERIFIABLE`. |
| One bad intermediate frame | Reject unless the frame is removed by an intentional edit that preserves temporal coherence. |

Never explain a visible failure into acceptance. “Motion blur,” “perspective,” “the model struggles with props,” and “the prompt said otherwise” are diagnostic notes, not waivers.

## Required deliverables

A production using a hero prop is incomplete without:

- `prop-bible.md`;
- clean generation references;
- annotated QA scale/interface sheet;
- scene action-coverage table;
- accepted receptacle/world evidence;
- per-scene keyframe assessment;
- per-scene full-frame and prop-crop contact sheets;
- per-scene verification reports;
- adjacent-scene continuity comparison;
- final-edit semantic report;
- checksum manifest for accepted evidence.

Keep rejected generations and their reports as evidence, clearly separated from accepted references.

## Final acceptance checklist

- [ ] The screenplay gives adjacent scenes different visible actions.
- [ ] Insertion or equivalent setup happens once unless explicitly justified.
- [ ] Absolute and relative scale descriptions agree.
- [ ] Working end, control end, grip, and orientation are unambiguous.
- [ ] Prop and receptacle are a visibly compatible designed pair.
- [ ] Clean reference pack and annotated QA sheet both exist.
- [ ] Every keyframe passed full-frame and prop-crop inspection.
- [ ] Every clip passed technical checks and sampled-frame semantic QA.
- [ ] Action occupancy is within plan.
- [ ] Every critical invariant is `PASS`, never `UNVERIFIABLE`.
- [ ] Adjacent clips inherit state rather than resetting the action.
- [ ] The final edit was inspected as a film, not merely decoded as a file.
