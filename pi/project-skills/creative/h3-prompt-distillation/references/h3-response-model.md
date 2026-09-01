# MiniMax H3 Response Model

What H3 demonstrably obeys, ignores, and degrades on. Sources: the pinned official
`h3-prompt-writing` adapter (MiniMax-AI/MiniMax-H3 @ d21241f0, `base-en.txt` and
`ref-en.txt`), the local runbooks (`comfyui-krea2-minimax-h3-muse-runbook.md`,
`local-ai-video-script-runbook.md`, Turbo-LoRA qualification), and community
behavioral reports (RunDiffusion H3 guide, H3 Prompt Hub, Naxdy prompt enhancer),
researched 2026-09-01. Behavioral claims from community sources are priors to
verify locally, not laws.

## 1. The grammar is a document, not a caption

H3 prompts are fixed-order documents. Base modes (T2VA/I2VA/FL2VA/L2VA): an exact
mode-specific instruction line (except T2VA), blank line, then
`integrated_multimodal_description`, `overall_soundscape`, `non_diegetic_music`.
Ref2VA: `subject_definitions`, `summary` (with `[task type]` prefix),
`retention_analysis` (fixed relationship markers), `detailed_description`,
`overall_soundscape`, `non_diegetic_music`. Field names, order, labels
(`<Picture N>`, `<Video N>`, `<Audio N>`, `<Subject N>`), `[Shot N]`/timestamp
notation, `(S1)` speaker IDs, and `<d>[Language] ...</d>` dialogue blocks are
exact. The official adapter owns this syntax; never freelance it.

## 2. The response budget is official, not folklore

- `detailed_description` for generation tasks: **350–500 English words**.
  Dialogue-dense clips prioritize fitting the complete spoken timeline over word
  count. A single shot does not justify a shorter description — distribute detail
  by information load.
- Description duration must equal the requested duration (4–15 s). Dialogue must
  fit real speech time; H3 does not gracefully truncate — lip sync fails instead.
- Timestamps: first shot never has one; later shots use strictly increasing
  `At MM:SS.mmm` inside the clip. Out-of-range timestamps are **silently
  ignored**, not errored.
- Overload response is graded, not binary: too many actions/cuts/words produce
  rushed motion, and **human microbehavior is dropped first**.

## 3. What H3 obeys well

- Observable actions in playback order with cause → contact/release → reaction.
- Explicit camera as a natural sentence: motion type + amplitude + speed from the
  official vocabulary (Push In, Pan Left, Tracking Shot, Static Shot, ...). Omit
  medium amplitude / normal speed.
- Verbatim `<d>` dialogue with stable speaker IDs, voiceover marked with the
  exact phrase `says in an off-screen voiceover` + "lips remain completely
  closed", `<scenetrans>`/`<cutoff>` for cuts and truncation.
- A style declaration at the opening ([Shot 1] for base modes; one or two
  sentences before [Shot 1] for Ref2VA) — this is where the look token belongs.
- Explicit end states — the shot needs a landing, or it drifts.
- Identity descriptors repeated **verbatim** at every appearance of a recurring
  character or garment.
- `N/A` in `non_diegetic_music` to force silence.
- On-screen text in double quotes, verbatim, untranslated.

## 4. What H3 ignores or does badly

- **Unstated camera → continuous drift and reframing.** Always state the camera;
  state static explicitly ("the camera holds a static shot").
- **Negative language.** There is no negative-prompt field; "no/never/avoid"
  clauses waste budget. State the positive visible truth instead.
- **Mood adjectives and plot summary.** "Cinematic", "beautiful", "tense" do
  nothing unless backed by composition, lens, motion, light, and sound.
- **Compound camera ideas in one shot** (static + shake + orbit) → unpredictable.
- **Long dialogue** → failed lip sync, not trimmed speech.
- **Omitted `non_diegetic_music`** → H3 invents background music.
- **Detached sound** — sound described away from its causing action gets
  ambiguous timing. Keep synchronized sound beside its cause; ambience only in
  the soundscape field.
- **Endpoint-only FL2VA prompts** — describing the two stills instead of the
  motion path between them warps the transition. FL2VA favors a single shot and
  wants the path: first-frame state → intermediate changes → narrowing
  differences → last-frame state.

## 5. Reference behavior (Ref2VA)

- **Every reference gets exactly one declared job.** Undeclared multi-purpose
  images cause H3 to copy the wrong part.
- **More references degrade.** Conflicting identity references average or pick
  arbitrarily. Reference economy: one approved full-look image usually beats a
  face lock plus a conflicting outfit frame. Add a reference only when it owns a
  distinct role; qualify counts with a paired-seed reference-count test.
- Motion/camera transfer from `<Video N>` requires the transferred action or
  move to be described; otherwise it is treated as loose visual guidance. The
  motion authority outranks prose for its assigned movement — text must not add
  beats absent from it.
- Audio reference transfers **timbre and delivery, not the signal**; it is not a
  voice clone. Map voice to speaker explicitly (`<Audio 1> is the voice-timbre
  reference for <Subject 1> (S1)`) or reference dialogue leaks into the result.
- Storyboards go through the reference workflow, never as a first frame — a
  storyboard first frame dominates the opening or stays visible.
- Sharp, well-lit reference images extract better than blurry ones. API-tier
  constraints (up to 9 images ≥256×256, AR 0.4–2.5; ≤3 videos and ≤3 audio clips,
  2–15 s each, ≤15 s per category) still shape good local practice.
- Label semantics: `<Subject N>` is reusable content, `<Picture N>` a concrete
  frame/planning anchor, `<Video N>` whole-video structure only, `<Audio N>`
  audio roles; numbering is per-category and order is semantic — never renumber
  or reorder.

## 6. Channel physics

Prose is the weakest carrier. Ranked by constraint strength:

1. **Keyframes** — exact composition, opening/closing states (FL2VA endpoints).
2. **References** — identity, wardrobe, world, style, motion, voice timbre.
3. **Prompt** — action order, camera, dialogue, synchronized sound, timing;
   plus the anchor phrases binding references to moments.
4. **QA** — everything verified from pixels afterward.

A constraint stated in prose that a stronger channel could carry is budget spent
buying weaker enforcement.

## 7. Operational discipline

- **One enhancer pass.** Muse/Director author once; never re-enhance a compiled
  prompt; inspect enhancer output for renumbered references or contradicted
  scene cards.
- **Staged qualification**: prove generic mechanics with anonymous subjects
  first, then add identity references, then audio, then cuts.
- **Four fixed seeds before rewording**; change one cause at a time (prompt,
  reference, seed, mode).
- The prompt is intent, never evidence — sampled-frame QA decides acceptance.

## 8. Local stack notes

- FL2VA and REF2VA are separate serialized graphs; production baseline is BF16,
  50 steps, shifts 12/3 (FL2VA Turbo 4-step uses task shifts 6/3), CFG 1,
  batch 1. Task-matched Turbo LoRAs only; never cross families.
- Wushu Action V7 runs stack the research adapter at strength 0.5 after the
  official Ref2VA Turbo LoRA and prepend `wushu_action,` to the prompt —
  Development-only, no authority.
- Keep text, titles, and logos out of diffusion outputs; add them in post.
