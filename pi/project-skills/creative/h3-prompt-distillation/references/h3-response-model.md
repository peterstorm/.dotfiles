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
- For prompt-led creative montage, a direct structure of reference-role preamble → global brief → look/pacing → timestamped hook/exchange/reversal/landing phases can outperform a constraint-heavy proof document. This is locally qualified behavior, not a replacement for formal carrier or dialogue grammar.
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
- **More references can degrade.** Conflicting identity references average or pick
  arbitrarily. Reference economy: one approved full-look image usually beats a
  face lock plus a conflicting outfit frame. A three-picture stack can remain
  coherent when the jobs are non-overlapping and explicitly bound — machine
  appearance, pilot face/hair, opponent appearance — but it requires a paired
  reference-count test and full-motion review.
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

1. **Video carrier** — an approved blocking playblast as `<Video 1>`: continuous
   camera path, cuts, spacing, poses, contact order, mechanism timing. Strongest
   channel for motion; still generative guidance, never pixel transfer.
2. **Keyframes** — exact composition, opening/closing states (FL2VA endpoints).
3. **References** — identity, wardrobe, world, style, motion, voice timbre.
4. **Prompt** — action order, camera, dialogue, synchronized sound, timing;
   plus the anchor phrases binding references to moments.
5. **QA** — everything verified from pixels afterward.

A constraint stated in prose that a stronger channel could carry is budget spent
buying weaker enforcement.

## 7. Operational discipline

- **One enhancer pass.** The prompt author/Director author once; never re-enhance a compiled
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
- Dedicated Ref2VA PDD-8 accepts higher multiple-of-32 spatial latents. Local
  qualified baseline is 960×544 (0.5 MP); bounded quality research may use
  1152×640 (0.7 MP) or 1280×736 (0.9 MP). Treat resolution as a full latent-
  generation cost, not a free output upscale, and record wall time separately.
  Resolution does not repair generated animation cadence.
- Wushu Action V7 runs stack the research adapter at strength 0.5 after the
  official Ref2VA Turbo LoRA and prepend `wushu_action,` to the prompt —
  Development-only, no authority.
- Blender blocking carriers use the `minimax-h3-blender-ref2va-development`
  profiles (124-frame default; 362-frame duration-qualification candidates —
  note 362 frames is nominally 15.08 s against the documented ≤15 s reference
  limit, so confirm the frame-vs-seconds boundary before qualifying). Never
  stack Turbo and PDD adapters; see `docs/runbooks/minimax-h3-blender-ref2va.md`.
- Keep text, titles, and logos out of diffusion outputs; add them in post.

## 9. Local evidence: v20 Turbo-4 / PDD-8 ensemble A/B

AFTERSIGNAL Development qualifications 26 and 27 used checksum-identical prompt, seed, references and Blender v20 carrier. The prompt followed the official six-section Ref2VA grammar, used 352 words in `detailed_description`, contained no negative clauses, assigned four players visibly different appearances and actions, and expressed the camera once. Qualification 26 used the official Ref2VA Turbo LoRA at four steps; qualification 27 used the dedicated Ref2VA PDD adapter at eight NFE.

Human review found both variants substantially better than the earlier overloaded prompt, but neither completed the full camera move and both produced strange human behavior. Sampled frames also raised an unresolved extra-player/count concern. Therefore:

- positive official-format prompting materially improved world readability and role differentiation, but did not guarantee terminal trajectory completion or natural concurrent performance;
- changing four-step Turbo to eight-step PDD did not by itself solve the shared endpoint or ensemble-motion failures;
- prompt detail is not a substitute for temporal conformance or unambiguous carrier topology;
- when a carrier owns simultaneous actions, additional per-person microbehavior can compete with the carrier instead of clarifying it;
- full-motion human review remains the authority for count, independent movement and endpoint completion.

The v20 carrier is 80 frames at 24 fps (3.333 seconds), while both requested four-second H3 runs encoded 107 frames (4.458 seconds). The shared unfinished camera move is evidence of an endpoint-mapping failure; the duration mismatch is the leading hypothesis, not yet a proven sole cause. Future endpoint-scored runs must record source and encoded target timelines and use a deterministic conform policy before generation.

## 10. Local evidence: direct mecha creative-montage grammar

The 15-second DeeVid-style diagnostic used 389 words, zero negative clauses, fast internal cuts, familiar mecha/kaiju action archetypes, cockpit reaction inserts, positive impact effects, escalation phases, and an explicit final landing. Earlier AEGIS proof prompts were similar in length but carried 13–25 constraint terms, one unusual contact stretched across ten seconds, continuous wide coverage, two unusual conditioned geometries, and no editorial reset.

Three matched diagnostic stages separate the main causes:

- the direct prompt under FL2VA Turbo-8 showed severe artifacting;
- dedicated FL2VA PDD-8 cleaned the image but left possible late duplication;
- task-matched Ref2VA PDD-8 with separate AEGIS and Rhea jobs produced a substantially more coherent creative result.

A later three-reference test bound AEGIS appearance, Rhea face/hair, and the accepted HUSH Full Combat Lock appearance in a 415-word direct prompt with zero negative clauses. At 960×544 it retained all three broad identities in sampled frames and produced energetic combat coverage. This supports the following response model:

- PDD quality, prompt grammar, and reference semantics are complementary; none is a secret phrase by itself;
- cockpit/reaction inserts are geometry resets as well as storytelling;
- familiar punch/block/pin/recovery archetypes are easier than novel exact contact topology;
- smoke, sparks, debris, shake, and close coverage sell force but cannot establish mechanics;
- direct creative montage and continuous Mechanics-Proof are separate products and must not share acceptance criteria.

The matched 1152×640 run generated 41.2% more pixels and took 437.4 seconds versus 256.4 seconds at 960×544 — a 70.6% wall-time increase. The matched 1280×736 run took 658.2 seconds: 27.8% more pixels and 50.5% more wall time than 0.7 MP. All files remained constant native 24 fps; perceived choppiness therefore belongs to generated animation, not container cadence. Resolution changes the latent trajectory even at the same seed, so these are not deterministic upscales and identity/action preference still requires full-motion review.
