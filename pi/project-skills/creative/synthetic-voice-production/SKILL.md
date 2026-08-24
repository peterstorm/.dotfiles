---
name: synthetic-voice-production
description: "Designs, selects, freezes, clones, converts, and qualifies wholly original synthetic speaking and singing voices for fictional characters. Use for VoiceDesign auditions, blind voice selection, VoiceAnchor manifests, dialogue cloning, singing conversion, stem assignment, range tests, pronunciation QA, or canonical-vocal music production. Separates immutable timbre identity from mutable performance direction, requires versioned local-only evidence, and rejects real-person target references or blended identity conversion."
license: MIT
compatibility: "Pi project skill for local Qwen3-TTS dialogue workflows and isolated-stem singing conversion with checksum and listening QA."
---

# Synthetic Voice Production

A generated voice is not canon merely because a model produced intelligible audio. Canon requires an original identity, a user-selected immutable anchor, reproducible evidence, and separate acceptance for speaking and singing.

This skill owns:

`voice brief → deterministic blind auditions → user selection → immutable VoiceAnchor → dialogue cloning qualification → isolated singing conversion → canonical-vocal mix`

It complements `performance-direction`. This skill owns identity and technical lineage; performance direction owns emotion, cadence, intention, and delivery.

## Ubiquitous language

- **Voice identity** — stable perceived timbre and speaker identity, independent of emotion or melody.
- **VoiceAnchor** — the immutable accepted reference audio, transcript, generation instruction, seed, model revision, hashes, and selection decision for one fictional character.
- **Performance direction** — mutable delivery data such as urgency, intimacy, cadence, accent strength, melody, dynamics, and register.
- **Guide vocal** — temporary composition/performance material that carries timing or melody but not canonical identity.
- **Assigned stem** — one isolated solo, double, harmony, breath, or ad-lib track belonging to exactly one canonical voice.
- **Range gate** — listening and measurement tests across required speaking or singing registers.
- **Audition set** — exactly three deterministic candidates for one role unless the user requests a new numbered round.
- **Voice version** — an immutable numbered audition, clone, conversion, or mix package. New model, instruction, source, seed policy, or processing chain creates a new version.

## Non-negotiable safety and originality

- Use wholly original synthetic targets only.
- Do not use a real performer, actor, singer, celebrity, private person, leaked sample, or third-party character voice as the identity target.
- Genre, energy, range, and delivery can be described abstractly; identity cannot be specified by imitation.
- Record model licenses and source authorization before production.
- Use local models only. Do not silently substitute a hosted API or another model family.

## Identity/performance firewall

The `VoiceAnchor` freezes identity. It does not freeze:

- emotional state;
- speaking rate or pause pattern;
- accent strength;
- pitch contour within the qualified range;
- melody, harmony, dynamics, or vocal register;
- microphone perspective or scene acoustics.

Never replace an anchor because a performance direction changed. Never encode a temporary emotion as part of the identity description unless it is intentionally permanent and the user accepts that limitation.

## Stage 0 — immutable runtime and evidence gate

Before auditions:

- pin repository and model revisions;
- verify every model artifact by exact size and SHA-256;
- build and record an immutable runtime image ID;
- force offline/local-only model loading during generation;
- record deterministic seeds and decoding settings;
- create a new numbered output root instead of overwriting prior auditions.

A technical failure preserves partial evidence but never writes a completion marker.

## Stage 1 — audition design

Create three candidates per role. Hold transcript and baseline performance as constant as practical so the user compares timbre rather than different acting choices.

Each candidate needs:

- original text-only voice instruction;
- shared audition transcript in the production language;
- unique deterministic seed;
- role-fit target stated without real-person references;
- identical file format and comparable level;
- blind A/B/C presentation, with descriptive instructions hidden from the first listening pass.

Technical QA checks decode, duration, sample rate, channel count, clipping, long silence, and checksums. It does not replace listening.

## Stage 2 — user selection

The user is authoritative. For each role the valid decision is one of:

- select A, B, or C;
- reject all and request a new numbered audition round;
- hold two finalists for a controlled tie-break using the same text and performance direction.

Do not average candidates, morph them together, or select automatically from similarity metrics.

## Stage 3 — freeze the VoiceAnchor

The immutable manifest records:

- fictional character and role;
- accepted audio file and exact transcript;
- original voice-design instruction;
- model repository, revision, artifact hashes, runtime image ID, seed, and generation parameters;
- file format, duration, sample rate, channels, and SHA-256;
- user decision date;
- allowed production language and optional accent controls;
- speaking and singing qualification state.

Copy the accepted file; do not destructively normalize, trim, denoise, or replace it. Derived processing gets a new file and hash.

## Stage 4 — dialogue cloning qualification

Clone from the frozen anchor with a pinned local base model. Test at minimum:

1. neutral informational speech;
2. intimate quiet speech;
3. urgent command speech;
4. fast low-volume speech;
5. names, numbers, and project-specific pronunciation;
6. optional code-switching only after the primary language passes.

Inspect intelligibility, identity retention, prosody freedom, sibilants, breaths, pacing, and artifacts. Passing neutral speech does not imply urgent or intimate speech passes.

## Stage 5 — singing conversion qualification

Use a clean isolated source stem that carries melody and performance but is not the target identity. Qualify:

- low, middle, and high register;
- sustained vowels;
- consonant attacks;
- soft onset and forceful onset;
- vibrato and straight tone;
- rapid lyric articulation;
- breath, fry, and ad-lib material when required.

Escalate from zero-shot conversion to per-character training only if documented range tests fail. A more complex model is not automatically more canonical.

## Stage 6 — stem-safe production

Convert separately:

- every solo line;
- every double;
- every harmony part;
- every ad-lib;
- breaths or vocal effects whose identity matters.

Never convert a blended chorus into one averaged identity. Never assign two canonical identities to one merged source stem. Preserve an explicit member/stem map through the final mix.

## Versioning and preservation

Create a new version when changing model revision, anchor, transcript, seed policy, conversion model, source stem, pitch strategy, or processing chain. A retry for a technical fault may remain within the version when its reason and seed are recorded.

Every version preserves:

- specifications and prompts;
- source and anchor hashes;
- runtime receipt;
- raw and derived audio;
- measurements and listening notes;
- accepted and rejected decisions;
- checksums and a manifest identifying canonical files.

## Acceptance states

Use only:

- `PASS` — evidence exists and listening acceptance is explicit;
- `REJECT` — evidence demonstrates failure or the user rejects the voice;
- `UNVERIFIABLE` — required evidence or listening is missing.

Technical QA can mark an artifact ready for listening. It cannot mark a VoiceAnchor canonical.

## Pre-delivery checklist

- [ ] Original synthetic target; no real-person identity reference
- [ ] Exact model artifacts and immutable runtime verified
- [ ] New numbered version; prior evidence untouched
- [ ] Three deterministic blind candidates per role
- [ ] User selection or explicit reject-all decision recorded
- [ ] VoiceAnchor identity separated from performance direction
- [ ] Dialogue range and pronunciation gates passed
- [ ] Singing ranges qualified before production conversion
- [ ] Solos, doubles, harmonies, and ad-libs converted separately
- [ ] Raw/derived distinction, manifests, receipts, and checksums preserved
