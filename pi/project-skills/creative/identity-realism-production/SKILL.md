---
name: identity-realism-production
description: "Creates and qualifies mandatory production-realism face assets for locked fictional characters. Use when an accepted Krea face needs a conservative FLUX.2 Klein 9B BF16 realism pass, when preparing the highest-fidelity identity references for MiniMax H3, when comparing base and finished faces, when a scene needs a non-neutral expression variant of a locked identity, when a keyframe must contain two or more locked identities without bleed, or when guarding against identity drift during finishing. Preserves immutable A/B evidence, inherits baked identity modifiers without reapplying them, qualifies expression variants and multi-identity group keyframes, and blocks production video until the finished face passes visual identity QA."
license: MIT
compatibility: "Pi project skill for local Krea 2, FLUX.2 Klein 9B BF16, and MiniMax H3 reference production. FLUX.2 Klein 9B outputs remain subject to its non-commercial license."
---

# Identity Realism Production

Production video receives the most realistic **accepted identity**, not merely the newest render.

This skill owns:

`accepted Krea identity A → conservative Klein realism B → A/B inspection → finished identity acceptance → H3 production reference pack`

It does not redesign faces. It creates a higher-fidelity photographic derivative while preserving the accepted fictional identity.

## Ubiquitous language

- **Identity A** — the immutable user-accepted Krea face source.
- **Realism B** — the FLUX.2 Klein 9B BF16 derivative of Identity A.
- **Identity authority** — the accepted face file H3 and downstream character assets must resolve to.
- **Inherited modifier** — FameGrid or another identity-affecting process already baked into Identity A.
- **Production reference pack** — the accepted realism face plus compatible wardrobe/body and world references supplied to H3 production.
- **Preview reference** — a technically valid pre-production face that may be used for cheap iteration but is barred from final H3 production.
- **Identity drift** — any change to facial geometry, eye shape or spacing, jaw, nose, lips, skin register, hair identity, expression baseline, or apparent personhood.
- **Expression variant** — an accepted child of Realism B that changes only expression, gaze, or head attitude for one named scene need.
- **Identity bleed** — one principal's facial identity, features, or wardrobe contaminating another principal in a multi-identity generation.
- **Reference-count test** — a paired-seed comparison establishing that each identity reference in a multi-reference generation earns its place.

## Hard rules

1. **A is immutable.** Never overwrite, normalize, relight, crop, or replace the accepted Krea source.
2. **B has one parent.** Realism B derives directly from Identity A with no intervening face synthesis or identity mixing.
3. **Realism only.** Klein may refine pores, peach fuzz, subsurface scattering, eye moisture, lashes, lip texture, strand hair, and photographic material response. It may not beautify, redesign, age-shift, restyle, relight, alter expression, change crop, change background, or invent markings.
4. **No modifier reapplication.** Record inherited FameGrid strength or other modifiers from A. Never reapply them as a generic realism filter. A new modifier test is a separately labelled non-canonical experiment.
5. **Explicit A/B evidence.** Preserve and checksum both source and finish. Never silently replace A in manifests or resolver paths.
6. **User acceptance is authoritative.** Metrics and visual similarity support inspection; they cannot promote B automatically.
7. **Mandatory for production H3.** Krea-only Identity A may drive previews. Final H3 FL2VA/REF2VA production is blocked until every visible principal has an accepted Realism B identity authority.
8. **Fail closed on drift.** If B is less faithful than A, retry with a new numbered version or reject it. Do not fall back silently and do not call extra sharpness realism.
9. **Reference-pack consistency.** H3 receives the accepted B face authority through a compatible face plate or strict one-visible-face character sheet. Wardrobe and body references cannot introduce a competing face.
10. **License travels with the asset.** Every B manifest records the FLUX.2 Klein 9B non-commercial restriction.
11. **Expression variants are children of B.** A scene needing a non-neutral face derives an expression variant from accepted Realism B through Stage 6. Rule 3's expression freeze applies to the realism pass itself, not to a qualified variant. A variant never replaces B as the identity authority.
12. **Group keyframes qualify separately.** A keyframe containing two or more locked identities enters production lineage only after the Stage 7 multi-identity qualification. Single-face acceptance does not imply group acceptance.

## Stage 0 — source gate

Before finishing, verify:

- Identity A is explicitly accepted and its file SHA-256 matches the canonical manifest;
- the fictional identity contains no real-person target reference;
- inherited identity modifiers and strengths are recorded;
- source crop, expression, hair, makeup, and background are documented as preservation invariants;
- the local Klein model and encoder are exact pinned BF16 artifacts;
- the output uses a new numbered directory and seed.

## Stage 1 — conservative Klein pass

Use Identity A as the sole visual parent. The prompt must front-load preservation:

- exact face geometry and personhood;
- exact eyes, brows, nose, lips, jaw and skin tone;
- exact front hair identity and hairline;
- exact expression, head angle, framing and crop;
- exact neutral plate background and medium.

Refinement targets only micro-realism. Do not use a style reference, beauty reference, second face, or identity LoRA during B.

## Stage 2 — technical QA

Verify:

- one decodable image at the intended dimensions;
- exactly one person and one visible face;
- no crop loss, duplicate, panel, inset, watermark, pseudo-text, or background substitution;
- request graph, model/encoder names, seed, prompt, history, runtime state, and checksums are preserved;
- no cloud or hosted media service was used.

Technical QA produces `READY_FOR_VISUAL_QA`, never `PASS`.

## Stage 3 — visual A/B identity QA

Inspect A and B side by side at full frame and matched crops:

| Invariant | A | B | Result | Notes |
|---|---|---|---|---|
| head and jaw geometry | | | | |
| eye shape, spacing, tilt and iris | | | | |
| brows and lashes | | | | |
| nose bridge, tip and nostrils | | | | |
| lips, philtrum and mouth width | | | | |
| skin tone and identity markers | | | | |
| hairline, part, color and silhouette | | | | |
| expression and gaze | | | | |
| crop, pose and background | | | | |
| pore, hair and eye micro-realism | | | | |

B passes only when every identity row passes and micro-realism is visibly improved. A sharper but different person is `REJECT`.

## Stage 4 — promotion

Promotion requires explicit user acceptance. The manifest then records:

- Identity A path and hash;
- Realism B path and hash;
- Klein model, encoder, precision, seed, prompt and history;
- inherited modifier provenance;
- user decision date;
- non-commercial license status;
- resolver role: `h3-production-face-authority`.

A remains canonical history and rollback authority. B becomes the production identity authority, not a destructive replacement.

## Stage 5 — H3 handoff

Before final H3 generation:

- every visible principal resolves to an accepted Realism B;
- the wardrobe/body reference either contains that accepted face or is explicitly face-free;
- a strict character sheet contains exactly one visible face, sourced from B;
- no rejected direct build, mannequin head, earlier face experiment, or unaccepted finish enters the reference stack;
- FL2VA and REF2VA remain separate serialized graphs;
- preview footage is clearly barred from final delivery if it used Identity A only.

## Stage 6 — expression-range variants

Use this stage when `performance-direction` requires a pre-turn emotional state, or a scene keyframe needs any non-neutral expression, gaze, or head attitude from a locked identity.

- Derive every variant directly from accepted Realism B. B is the sole visual parent; no second face, style reference, or identity LoRA.
- One variant per named expression need. "A range of emotions" is not a request; "guarded fear while listening" is.
- The variant may change only expression, gaze direction, and head attitude. Framing, crop, hair identity, lighting register, and background remain B's.
- Inspect each variant against B using the Stage 3 table with one substitution: the expression row instead verifies that the **requested** expression is achieved and readable. Every other identity row must still pass — a frightened face that belongs to a different person is `REJECT`.
- Promotion requires explicit user acceptance. The manifest records role `expression-variant`, its parent B path and hash, and the named expression need.
- Variants serve scene keyframes. They never become the H3 face authority; production reference packs continue to resolve to B. An unaccepted variant is barred from lineage exactly like a rejected finish.

## Stage 7 — multi-identity keyframe qualification

Required before any keyframe containing two or more locked identities becomes a production lineage parent or H3 reference.

- Run a paired-seed reference-count test: generate with N identity references and with N−1 at the same seed and prompt. Keep the extra reference only if it demonstrably improves its principal without degrading the others. Never assume more references improve separation.
- Crop every visible face and compare each against its own accepted authority (Realism B or accepted expression variant) using the Stage 3 identity rows.
- Reject on any identity bleed: face averaging between principals, feature migration, identity swap, wardrobe or hair migrating from one principal to another, a duplicated principal, or an extra person.
- Record acceptance per principal, not per image. One drifted face rejects the keyframe even when the others are perfect.
- Geometry, marks, and screen sides remain `blocking-continuity`'s contract; this stage judges identity only.
- An accepted group keyframe is a qualified lineage parent for group H3 shots. Keep most H3 coverage at one to three readable faces; a full-group wide starts from an accepted group keyframe or does not run.

## Versioning

Create a new numbered realism version when changing the source A, Klein model or encoder revision, prompt, seed, sampling graph, resolution, crop, or finishing policy. Retries remain preserved with reasons. Never rewrite `realism-01` into a corrected `realism-01`.

## Acceptance states

- `PASS` — explicit user acceptance and complete visual/technical evidence.
- `REJECT` — visible identity drift, no meaningful realism gain, artifact, or user rejection.
- `UNVERIFIABLE` — missing source hash, graph, output, comparison, or user decision.

Only `PASS` may enter final H3 production.

## Pre-delivery checklist

- [ ] Accepted Krea Identity A exact-hash verified
- [ ] Inherited FameGrid/modifier state recorded and not reapplied
- [ ] Klein 9B BF16 local-only pass derived directly from A
- [ ] A and B both archived with prompts, histories and checksums
- [ ] Full-frame and matched face-crop comparison inspected
- [ ] No identity, expression, crop, hair, or background drift
- [ ] Realism improvement visible rather than assumed
- [ ] User explicitly accepted B
- [ ] Klein non-commercial license attached
- [ ] Expression variants derive from B, pass identity QA, and never replace the face authority
- [ ] Multi-identity keyframes passed the reference-count test and per-principal bleed QA
- [ ] Final H3 reference pack resolves to accepted B or production remains blocked
