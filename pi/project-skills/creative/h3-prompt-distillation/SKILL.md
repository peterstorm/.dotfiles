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

## Operating modes

Choose the product before compiling:

- **Creative montage** — optimize the audience's impression of coherent action. Use familiar action archetypes, rapid coverage changes, human or cockpit reaction inserts, positive impact consequences, and explicit escalation/landing phases. Internal cuts are useful geometry resets. This mode cannot establish exact contact topology, persistent damage, count continuity, or Mechanics-Proof.
- **Mechanics proof / carrier edit** — optimize auditability. Use one scored physical event, continuous readable coverage or an approved motion carrier, explicit endpoint mapping, and separate QA. Do not judge this mode by trailer energy.

Do not combine their grammars. A continuous mechanics-proof prompt stripped of editorial resets will usually look less exciting; a creative montage may look convincing precisely because cuts conceal or reset geometry.

## Hard rules

1. **Read the contracts, not the skills' prose.** Gather each owning skill's *handoff block* (performance task, human-motion block, blocking contract, physical-state chain, prop states, light contract, look token, reference-pack manifest). Do not re-derive or reinterpret them.
2. **One scored variable per generation.** Name what this clip must prove before drafting. Everything else is supporting or QA-only.
3. **Prose is the weakest identity carrier.** Identity, wardrobe, and world travel by reference image; composition and endpoints travel by keyframe; continuous motion — camera path, spacing, contact order, timing — travels by an approved blocking-video carrier when one exists; the prompt carries **action, camera, sound, and timing**. Never spend prompt budget re-describing what a reference already locks — name the reference and move on.
4. **Every reference has exactly one job**, stated in the manifest and respected in the prompt. More references are not better; conflicting references average.
5. **Positive language only.** H3 has no negative-prompt field. Translate every forbidden-failure into either a positive statement ("both feet stay planted through the swing") or a QA row. Never paste a forbidden-failure battery into the prompt.
6. **Observable or absent.** Every clause must name something visible or audible at a moment in time. Convert intent and emotion to camera-detectable behavior; delete mood adjectives, plot summary, and unbacked style words.
7. **The budget is enforced, not aspirational.** Generation tasks use 350–500 words for the main description. Direct video-editing descriptions scale with source complexity and may be shorter, especially when the carrier already owns motion. Mechanics-proof and carrier-owned shots use one primary action and one camera idea per shot. Creative montage uses one recognizable action exchange per implicit 1–2 second coverage beat, grouped into a small number of escalating timestamp phases; each beat may cut to a new scale or axis. Both allow at most two or three microbehavior channels per principal, dialogue that fits real speech time inside the duration, and timestamps strictly increasing and inside the clip.
8. **Endpoint timing is a preflight invariant.** Record source-carrier frames, source fps and duration together with requested and encoded target frames and duration. When the terminal camera state is scored, the carrier must explicitly map its endpoint to the target endpoint. A shorter carrier inside a longer generated timeline is blocked unless a declared deterministic conform policy says where the source endpoint lands and what fills the remainder. Prompt wording cannot repair an unowned temporal gap.
9. **Carrier-owned ensembles stay carrier-owned.** When a video carrier already defines simultaneous role schedules, the prompt binds a stable appearance and role name to each carrier mark and summarizes the shared causal spine. It does not add secondary gestures, balance corrections, reactions or endpoints absent from the carrier. Count, role separation and motion uniqueness remain full-motion QA rows; richer prose cannot make an ambiguous carrier topology exact.
10. **Repetition is only for identity.** Recurring characters and garments use the same descriptors verbatim at every appearance — that repetition is load-bearing. All other repetition is budget waste; contradictory scale or geometry clauses are a defect, not emphasis.
11. **Choose grammar by operating mode.** Use the pinned official `h3-prompt-writing` document grammar for carrier edits, dialogue-sensitive work, and prompts whose reference relationships need formal retention analysis. A locally qualified prompt-led creative montage may instead use direct cinematic grammar: one-reference-job preamble, global action/look brief, chronological timestamp phases, landing, and sound. Do not wrap a proven direct montage in extra metadata merely for formality. In either grammar, reject any formatter output that adds an action, changes causal order, renumbers or invents a reference, or drops an endpoint.
12. **One enhancer pass.** A prompt authored or enhanced once (the local prompt author, Director) is final input; never run a second enhancer over a compiled prompt.
13. **Distillation is traceable.** Every ledger row ends as `prompt`, `reference`, `keyframe`, `qa`, or `dropped:<reason>`. A critical constraint that lands in `dropped` blocks the generation.
14. **Reword only after seeds.** Run four fixed seeds before changing wording; change one cause at a time — prompt, reference, seed, or mode — never several.

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

Before Stage 1, write the temporal contract: source frame count, source fps, source duration, requested target duration, encoded target frame count/duration, endpoint mapping, and remainder policy. If any value is unknown, inspect the consuming graph. If the source and target timelines differ and endpoint mapping is not explicit, stop before prompting.

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
- A carrier used to score terminal camera motion must be conformed to the graph's encoded target grid before generation. The conform operation is deterministic evidence and records whether it retimes, pads, holds, or trims; silent model-side alignment is not an endpoint contract.
- For multi-person carriers, every visible proxy region has exactly one semantic role. Balls, props and people require unambiguous labels or masks; a shared appearance key that can be read as either a person or a prop blocks count-sensitive generation.

## Stage 3 — maximal draft

Write the over-complete draft from the `prompt`-channel rows only, in playback order.

- **Mechanics proof / carrier edit:** style opening, then per shot — composition, subjects by reference label, one primary action with cause → contact/release → reaction, one natural camera sentence, synchronized sound, and end state.
- **Creative montage:** declare each reference's one job once; state the familiar action archetype, production look, pace, and permission to cut; divide the duration into hook → exchange → reversal → landing phases. Inside each phase, write short recognizable action/reaction pairs and alternate exterior action with close, cockpit, reaction, low-angle, tracking, or wide coverage. Impact effects communicate force but remain QA-ineligible as mechanics evidence.

Then add the full-video soundscape and score. This draft may exceed the budget. Its job is completeness of the prompt channel, so distillation cuts consciously rather than by accident.

## Stage 4 — distillation passes

Apply in order, re-reading the draft after each:

1. **De-duplicate against carriers.** Delete every clause a reference or keyframe already locks, keeping only the label anchor ("the woman from <Picture 1>").
2. **Match action density to mode.** Mechanics-proof and carrier-owned shots retain one primary action. Creative montage may carry several actions only when each is a familiar one-beat exchange separated by an explicit or implicit cut; prune any exchange that cannot fit in roughly 1–2 seconds. For a carrier-owned ensemble, the primary action is the carrier's shared event, while each supporting role gets only its carrier-defined contribution.
3. **One camera idea per shot.** Collapse compound moves; state static explicitly when the frame must not move.
4. **Positive conversion.** Rewrite every "no/never/avoid" as the visible state that is true instead, or demote it to QA.
5. **Observable conversion.** Replace intent, emotion, and mood words with behavior, light, and sound.
6. **Microbehavior pruning.** At most two or three channels per principal, each caused; delete generic "natural movement" residue.
7. **Dialogue timing.** Read lines aloud against the duration; cut words, not delivery.
8. **Sound layer separation.** Dialogue/diegetic events stay in the timeline; ambience to the soundscape field; score to the music field; `N/A` written explicitly when silence is wanted.
9. **Word budget.** Trim generation tasks to 350–500 words (dialogue-dense clips prioritize the complete spoken timeline instead). For direct video editing, stop once the source relationship, intended edits, action spine, camera relationship, sound and end state are explicit; padding a carrier-owned edit back to 350 words reintroduces competition. If a generation draft cannot fit, the shot is overloaded — split it; do not compress causality away.

## Stage 5 — mode-aware formatting

For official-document jobs, hand the distilled prompt, mode, duration, and reference manifest to the pinned `h3-prompt-writing` adapter and verify exact field order, labels, timestamps, dialogue, and duration. For a direct creative montage, preserve the proven direct structure and wording: reference-role preamble, generation brief, look/pacing paragraph, timestamp phases, landing, and sound. Never run either result through a second enhancer.

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
- [ ] Source and encoded target timelines recorded; terminal endpoint mapping and remainder policy explicit
- [ ] Multi-person carrier roles and prop regions are semantically unambiguous
- [ ] Exactly one scored variable named
- [ ] Every constraint ledgered with criticality
- [ ] Channel allocation complete; prompt carries only action/camera/sound/timing
- [ ] References each have one job; manifest matches prompt labels
- [ ] Maximal draft written before any cutting
- [ ] All nine distillation passes applied
- [ ] Word, action, camera, microbehavior, and dialogue budgets met
- [ ] Grammar matches the declared operating mode; any adapter changed format only
- [ ] Creative montage includes a strong hook, rapid coverage resets, escalation, and a readable landing
- [ ] Creative montage effects are not misreported as mechanics evidence
- [ ] Fidelity diff shows no silently dropped critical constraint
- [ ] Prompt package archived; seed discipline recorded
