---
name: h3-prompt-distillation
description: "Compiles the locked contracts of every relevant creative skill into one MiniMax H3 prompt at the density H3 actually responds to. Use whenever a shot has contracts from two or more owning skills (performance, human motion, blocking, action physics, prop, wardrobe, identity, location/light/look), when a prompt feels overloaded, when H3 ignores instructions or rushes actions, or before any production H3 generation. Produces a constraint ledger, channel allocation (reference/keyframe/prompt/QA), a maximal draft, a distilled prompt, an official-format handoff, and a fidelity diff proving no critical constraint was silently dropped."
license: MIT
compatibility: "Pi project skill for local MiniMax H3 FL2VA/REF2VA production. Sits between the specialist skills and MiniMax's pinned official h3-prompt-writing adapter; the adapter owns final syntax, this skill owns what survives into it."
---

# H3 Prompt Distillation

The specialist skills generate far more constraints than one H3 prompt can carry. H3's official response budget for a generation-task description is roughly **350–500 English words** — a shot's combined performance, motion, blocking, physics, prop, wardrobe, and light contracts are several times that. Pasting everything overloads the model; it rushes actions, drops human microbehavior first, and averages conflicting signals.

This skill owns the compilation:

`gather locked contracts → constraint ledger → channel allocation → maximal draft → distillation passes → official adapter formatting → fidelity diff → prompt package`

The prompt is not a specification. It is the **subset of the specification the model can act on**, with every remaining constraint deliberately carried by a reference, a keyframe, or the QA ledger instead.

Load [the H3 response model](references/h3-response-model.md) whenever this skill runs. It records what H3 obeys, what it ignores, and why.

## Ubiquitous language

- **Owning skill** — the specialist skill whose contract governs one aspect of the shot.
- **Constraint ledger** — every locked constraint for the shot, one row each, with source and criticality.
- **Scored variable** — the one thing this generation exists to prove; it always survives distillation.
- **Carrier channel** — where a constraint travels: `reference`, `keyframe`, `prompt`, or `qa`.
- **Maximal draft** — the over-complete first prompt containing every prompt-channel constraint before reduction.
- **Response budget** — the density H3 demonstrably acts on: word count, actions per shot, camera ideas per shot, microbehavior channels, dialogue seconds.
- **Distilled prompt** — the draft after reduction to the response budget, before official formatting.
- **Fidelity diff** — the row-by-row proof of where every ledger constraint ended up.
- **Prompt package** — the archived brief, ledger, drafts, final prompt, references in order, seed, and settings.

## Hard rules

1. **Read the contracts, not the skills' prose.** Gather each owning skill's *handoff block* (performance task, human-motion block, blocking contract, physical-state chain, prop states, light contract, look token, reference-pack manifest). Do not re-derive or reinterpret them.
2. **One scored variable per generation.** Name what this clip must prove before drafting. Everything else is supporting or QA-only.
3. **Prose is the weakest identity carrier.** Identity, wardrobe, and world travel by reference image; composition and endpoints travel by keyframe; continuous motion — camera path, spacing, contact order, timing — travels by an approved blocking-video carrier when one exists; the prompt carries **action, camera, sound, and timing**. Never spend prompt budget re-describing what a reference already locks — name the reference and move on.
4. **Every reference has exactly one job**, stated in the manifest and respected in the prompt. More references are not better; conflicting references average.
5. **Positive language only.** H3 has no negative-prompt field. Translate every forbidden-failure into either a positive statement ("both feet stay planted through the swing") or a QA row. Never paste a forbidden-failure battery into the prompt.
6. **Observable or absent.** Every clause must name something visible or audible at a moment in time. Convert intent and emotion to camera-detectable behavior; delete mood adjectives, plot summary, and unbacked style words.
7. **The budget is enforced, not aspirational.** 350–500 words for the main description; one primary action per shot; one camera idea per shot; at most two or three microbehavior channels per principal; dialogue that fits real speech time inside the duration; timestamps strictly increasing and inside the clip.
8. **Repetition is only for identity.** Recurring characters and garments use the same descriptors verbatim at every appearance — that repetition is load-bearing. All other repetition is budget waste; contradictory scale or geometry clauses are a defect, not emphasis.
9. **The adapter formats; it does not author.** The pinned official `h3-prompt-writing` skill owns field names, section order, labels, and timing notation. Reject its output if it adds an action, changes causal order, renumbers or invents a reference, or drops an endpoint.
10. **One enhancer pass.** A prompt authored or enhanced once (Muse, Director) is final input; never run a second enhancer over a compiled prompt.
11. **Distillation is traceable.** Every ledger row ends as `prompt`, `reference`, `keyframe`, `qa`, or `dropped:<reason>`. A critical constraint that lands in `dropped` blocks the generation.
12. **Reword only after seeds.** Run four fixed seeds before changing wording; change one cause at a time — prompt, reference, seed, or mode — never several.

## Stage 0 — gather

List the owning skills actually relevant to this shot and collect their locked handoff blocks verbatim:

| Owning skill | Handoff artifact | Locked? |
|---|---|---|
| performance-direction | performance task block | |
| human-motion-realism-production | microbehavior block | |
| blocking-continuity | blocking contract | |
| action-physics-production | physical-state contract + action chain | |
| prop-continuity | prop states + transition plan | |
| identity-realism-production | face authority + reference pack | |
| wardrobe-asset-production | wardrobe package | |
| location-world-production | light contract + look token + ambient contract | |
| cinema-director | coverage/camera assignment | |
| blender-previz | blocking-video carrier contract + playblast/state stills | |

An unlocked contract blocks compilation — distilling an unfinished specification produces a confident prompt for the wrong shot. Skip rows that genuinely do not apply; do not invent contracts for them.

## Stage 1 — constraint ledger

Flatten every gathered block into atomic rows:

| # | Source skill | Constraint | Criticality |
|---|---|---|---|

Criticality is one of:

- `scored` — the variable this generation proves (exactly one);
- `supporting` — must be right for the clip to be usable;
- `qa-only` — must be *verified* but does not need to be *stated*.

Most continuity constraints are `qa-only`: the model cannot be talked into continuity it isn't given a carrier for, and QA will catch the drift either way.

## Stage 2 — channel allocation

Assign each row a carrier:

- `video carrier` — an approved blocking playblast from `blender-previz`, loaded as `<Video 1>` in REF2VA: camera path, cuts, spacing, poses, contact order, and mechanism timing. The strongest motion channel when one exists.
- `reference` — identity, wardrobe, world, style, motion, voice timbre. Update the reference manifest; the prompt names the label and its role once.
- `keyframe` — exact composition, opening/closing states, blocking marks. FL2VA endpoints beat prose endpoints; a keyframe that embodies the blocking beats a described mark.
- `prompt` — action order, camera behavior, dialogue, synchronized sound, timing, and the minimum anchor phrases that bind references to moments.
- `qa` — everything verified from pixels after generation.

Allocation heuristic: **if a stronger channel can carry it, the prompt must not.** The prompt gets what only prose can do — the causal, temporal, audible spine of the shot.

### Video carrier rules

- This skill declares the render targets `blender-previz` must hit — frame rate, aspect, exact frame count, and state-still frames — from the consuming graph; the current local profiles are documented in `docs/runbooks/minimax-h3-blender-ref2va.md`.
- Encode the carrier contract's owned/not-owned split through the official grammar: what `<Video 1>` provides in `subject_definitions`, its preservation level in `retention_analysis`, and its role positively in the description. Not-owned properties (identity, proxy appearance, gray materials, lighting) are covered by the appearance references and the style-bleed QA row — never by negative prompt clauses.
- The carrier is generative guidance, not deterministic pixel transfer: every claimed camera, cut, path, contact, and state property still needs sampled-frame QA.
- Raw proxy state stills are Development A/B material only; prefer Krea-resolved stills that keep the Blender projection and spacing while carrying accepted appearance.
- The carrier plus appearance pictures form one reference stack — the paired-seed reference-count test applies to it like any other.

## Stage 3 — maximal draft

Write the over-complete draft from the `prompt`-channel rows only, in playback order: style opening, then per shot — composition, subjects (by reference label), one primary action with cause → contact/release → reaction, camera as one natural motion sentence (type + amplitude + speed), dialogue in `<d>` with speaker IDs, synchronized sound beside its cause, end state. Then the full-video soundscape and score fields.

This draft may exceed the budget. Its job is completeness of the prompt channel, so distillation cuts consciously rather than by accident.

## Stage 4 — distillation passes

Apply in order, re-reading the draft after each:

1. **De-duplicate against carriers.** Delete every clause a reference or keyframe already locks, keeping only the label anchor ("the woman from <Picture 1>").
2. **One primary action per shot.** Move extra beats to the next shot unit or cut them; a 5-second clip performs one turn.
3. **One camera idea per shot.** Collapse compound moves; state static explicitly when the frame must not move.
4. **Positive conversion.** Rewrite every "no/never/avoid" as the visible state that is true instead, or demote it to QA.
5. **Observable conversion.** Replace intent, emotion, and mood words with behavior, light, and sound.
6. **Microbehavior pruning.** At most two or three channels per principal, each caused; delete generic "natural movement" residue.
7. **Dialogue timing.** Read lines aloud against the duration; cut words, not delivery.
8. **Sound layer separation.** Dialogue/diegetic events stay in the timeline; ambience to the soundscape field; score to the music field; `N/A` written explicitly when silence is wanted.
9. **Word budget.** Trim to 350–500 words (dialogue-dense clips prioritize the complete spoken timeline instead). If the draft cannot fit, the shot is overloaded — split it; do not compress causality away.

## Stage 5 — official formatting

Hand the distilled prompt, mode, duration, and reference manifest to the pinned `h3-prompt-writing` adapter. Verify its output preserves exact field names and order, the mode's fixed instruction line, strictly increasing in-range timestamps, verbatim `<d>` content, consistent reference labels, and the stated durations. Reject and re-run on any authorial change.

## Stage 6 — fidelity diff

Complete the ledger:

| # | Constraint | Carrier | Where |
|---|---|---|---|

- every `scored` and `supporting` row resolves to a real carrier — a named prompt clause, reference label, or keyframe;
- every `qa` row appears in the shot's QA plan;
- any `dropped` row carries a reason and cannot be `scored` or `supporting`;
- the reference manifest, keyframes, and prompt tell the same story — no orphan labels, no contradictions.

## Stage 7 — prompt package

Archive together: the shot brief, gathered handoff blocks, constraint ledger, maximal draft, distilled prompt, final formatted prompt, reference files in exact order, seed policy, model/LoRA/sampler settings, and the fidelity diff. Rewording after generation creates a new numbered package; four fixed seeds run before any rewording.

## Pre-delivery checklist

- [ ] All relevant owning-skill contracts gathered and locked
- [ ] Exactly one scored variable named
- [ ] Every constraint ledgered with criticality
- [ ] Channel allocation complete; prompt carries only action/camera/sound/timing
- [ ] References each have one job; manifest matches prompt labels
- [ ] Maximal draft written before any cutting
- [ ] All nine distillation passes applied
- [ ] Word, action, camera, microbehavior, and dialogue budgets met
- [ ] Official adapter changed format only
- [ ] Fidelity diff shows no silently dropped critical constraint
- [ ] Prompt package archived; seed discipline recorded
