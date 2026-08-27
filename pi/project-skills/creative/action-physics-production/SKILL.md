---
name: action-physics-production
description: "Plans, conditions, and verifies physically readable action for local MiniMax H3 production. Use for fights, falls, throws, impacts, vehicle motion, collisions, destruction, recoil, jumps, landings, object trajectories, or any action where support, force, contact order, momentum, material response, or settling must remain credible. Produces a physical-state contract, short action units, motion-reference strategy, proof-shot plan, official H3 handoff, sampled-frame atomic QA, and versioned repair ledger."
license: MIT
compatibility: "Pi project skill for local MiniMax H3 FL2VA/REF2VA. Coordinates cinema-director, blocking-continuity, prop-continuity, identity-realism-production, ensemble-action-production, and MiniMax's pinned official h3-prompt-writing adapter."
---

# Action Physics Production

Cinematic action and physical causality are separate responsibilities. The body owns the move; the camera reveals and emphasizes it.

This skill owns:

`dramatic action → physical-state contract → conditioning strategy → proof/style coverage → official H3 translation → sampled-frame physics QA → targeted repair`

It does not promise scientific simulation. It makes support, cause, contact, reaction, trajectory, and end state explicit enough to plan and verify.

## Ubiquitous language

- **Mechanics-proof unit** — one short H3 shot containing one dominant physical transition, composed so contact and support can be scored.
- **Creative coverage unit** — one H3 generation containing several timestamped shots whose separate functions create a cinematic action impression; each shot still carries only one primary action.
- **Support state** — every body/object contact currently carrying weight or resisting motion.
- **Support polygon** — the ground/contact area within which a body can remain balanced.
- **Force path** — ordered transmission from initiating source through body/object to target or environment.
- **Contact event** — the frame interval in which two bodies or objects physically meet.
- **Reaction order** — cause first, contact second, target response third.
- **Settled state** — the readable final positions, velocities, balance, damage, and persistent debris after the action.
- **Proof shot** — coverage prioritizing readable mechanics, usually wide or medium-wide with restrained camera motion.
- **Style shot** — adjacent coverage emphasizing impact or emotion without being the sole evidence for mechanics.
- **Motion authority** — an authorized reference video, mocap take, animation, or physics previs assigned only to motion/timing.
- **Physics ledger** — atomic PASS/REJECT/UNVERIFIABLE findings tied to sampled frames and crops.

## Non-negotiable local and rights boundary

- Generate with locally installed H3 only; do not use hosted media APIs.
- A motion authority must be original, licensed, public-domain, or separately authorized. Do not ingest an unlicensed film/stunt clip as production conditioning.
- Production H3 characters must use accepted `identity-realism-production` face authorities.
- H3 FL2VA and REF2VA remain separate serialized graphs; never load both concurrently.
- Full production uses the qualified BF16 path, 50 steps, CFG 1, batch 1, and no Turbo LoRA.
- The pinned official `h3-prompt-writing` skill is the final syntax adapter. It may translate locked facts; it may not redesign the action.

## Stage 0 — dramatic and geography gate

Before mechanics, record:

- dramatic job and audience reappraisal;
- all actors, objects, obstacles, exits, and hazards;
- normalized positions and facing directions from `blocking-continuity`;
- screen direction and permitted camera side;
- exact start and end states;
- whether the job is `mechanics-proof` or `creative-montage`;
- the dominant physical transition in every mechanics-proof shot;
- what must remain visible to prove each scored contact.

Use a 3–6 second single-shot mechanics-proof unit when exact support, contact topology, deformation, or reaction order is the scored variable. Use a 6–10 second creative coverage unit only when the job is editorial energy, coverage discovery, or holistic fight impression. A creative montage may contain several hard-cut shots, but every shot gets one primary action and a distinct editorial function. Montage success never proves hidden mechanics.

## Stage 1 — physical-state contract

Complete every section before H3 formatting.

### Initial state

- position, orientation, and distance for every major body/object;
- support contacts and load-bearing limb, wheel, surface, cable, or structure;
- center-of-mass relation to the support polygon for human or vehicle balance;
- existing linear and rotational motion with direction;
- surface material, slope, friction register, and deformation state;
- prop grip, working end, receptacle, and engagement state when applicable.

### Initiating cause

- actor or mechanism that supplies force;
- anatomical segment or object that initiates;
- direction and line of action;
- resistance, grip, traction, anchor, or reaction surface;
- visible anticipation or loading before acceleration.

### Action chain

Write one ordered chain:

`load/support → initiate → accelerate → contact or release → momentum transfer → recoil/follow-through → recovery or loss of balance → settle`

For human movement, state planted foot, pivot, hip and torso sequence, limb trajectory, and balance consequence. For objects/vehicles, state thrust/traction, path, contact normal, rotation, deformation, and stopping mechanism.

### Secondary physics

Assign only effects causally connected to the primary event:

- hair and garment lag, stretch, swing, and settling;
- dust, fragments, fluid, suspension, recoil, flex, or breakage;
- shadow/reflection motion consistent with moving objects;
- sound onset at contact or mechanical release, never before it.

### End state

- final position and orientation of every major body/object;
- balanced, recovering, airborne, pinned, sliding, rotating, or stopped state;
- persistent damage, displaced props, dust, debris, and garment state;
- exact last-frame composition when FL2VA is used.

## Stage 2 — conditioning decision

Choose the narrowest H3 family that constrains the important uncertainty.

### FL2VA

Use when opening and landing states are the critical contract: takeoff/landing, pre-impact/final wreck, standing/completed fall, closed/open mechanism, or exact positional transition. First and last frames constrain endpoints but do not prove correct intermediate force or contact timing.

### REF2VA

Use when timing, trajectory, pose sequence, performance, or camera path must follow a motion authority. Assign each reference one role:

- character/wardrobe identity;
- environment/style;
- motion and timing;
- camera path or edit rhythm.

A video motion authority outranks prose for the assigned movement. Text must not add extra techniques, reversals, contacts, or beats absent from the authority.

### Previs hierarchy

For high-risk mechanics prefer, in order:

1. original stunt/sports performance captured for the project;
2. project-owned mocap or keyframed animation;
3. local physics-engine previs for vehicles, collisions, rigid bodies, and destruction;
4. authored first/last keyframes when endpoints matter more than intermediate contact;
5. text only for simple low-contact movement.

## Stage 3 — proof and creative-montage coverage

### Mechanics-proof mode

The critical mechanic needs a proof shot:

- wide or medium-wide enough to see supports, trajectory, contact, and both bodies;
- static, restrained tracking, or modest operator movement through the contact event;
- no cut, whip, occlusion, debris cloud, or close crop that hides undefined mechanics.

A separate style shot may use an aggressive angle, tighter impact insert, orbit, whip, shake, or speed change. Never use style coverage as the only evidence that contact happened correctly.

### Creative-montage mode

Use H3's native timestamped multi-shot grammar when the user is evaluating cinematic impact rather than one exact collision. Build a coverage matrix before writing:

- each shot has a purpose such as threat cue, geography, proof impact, material insert, subjective reversal, or wide consequence;
- each shot changes scale, camera height, axis, lens category, and compositional information—not focal length alone;
- each shot carries one primary action with visible cause, contact or release, reaction, and consequence;
- adjacent detail coverage inherits an already-established action instead of inventing hidden mechanics;
- later shots preserve visible damage and changed advantage;
- requested hard-cut times are explicit and strictly increasing.

`cinema-director` may supply the coverage matrix, degree-first FOV ladder, capture cadence, and camera physicality. The official `h3-prompt-writing` adapter still owns final Ref2VA section names, reference labels, timing notation, and audio fields.

Internally generated cuts are valid Development evidence for previsualization and holistic action scouting. Use independent source generations and external editing when exact cut frames, source-shot selection, or authority continuity matters.

## Stage 3.5 — Turbo scouting profile

The Ref2VA adapter is distilled and officially recommended for four NFEs. Four NFEs is the operational default for creative and mechanics work; it is not a demonstrated universal quality ceiling.

Do not increase steps because an output feels heavier, more physical, or more cinematic. Extra internal cuts, closer framing, shake, debris, and material detail can improve the impression of physics without improving contact topology or force transfer. When four-step inference cannot provide reliable internal coverage, generate independent four-step source shots and edit externally.

Any separately authorized 8–12-step use is an **off-label Turbo-LoRA extrapolation** and must be labeled exactly that. Treat it as controlled Development research, not routine production. Hold LoRA strength, shifts, sampler, scheduler, seed, resolution, duration, reference resize, references, and prompt constant; score cut fidelity and mechanics independently.

Prefer one appearance reference when only one subject requires exact recurrence. Add a second unusual-subject reference only through a paired-seed reference-count test; never assume that more references improve subject separation or action freedom.

## Stage 4 — official H3 handoff

Pass the following locked inputs to `h3-prompt-writing`:

- selected H3 mode;
- exact duration and shot count;
- asset-role map matching physical input order;
- spatial map and screen direction;
- physical-state contract;
- ordered action chain;
- proof/style camera assignments;
- continuity and forbidden-failure lists;
- sound/contact timing;
- required first/last frame when applicable.

The adapter must preserve the official field names, section order, labels, and timing notation. Reject the translation if it adds an action, changes causal order, drops an endpoint, or assigns one reference two conflicting roles.

## Stage 5 — forbidden failures

Every action unit carries only the failures relevant to it, selected from:

- support-foot or wheel sliding without matching force;
- unsupported floating or frozen hang time;
- body, limb, prop, or environment interpenetration;
- teleportation or discontinuous trajectory;
- reaction beginning before contact;
- target response incompatible with force direction;
- spontaneous momentum reversal;
- absent recoil, follow-through, or balance consequence;
- prop, debris, damage, or body disappearing between frames;
- joint inversion, limb-count drift, or volume collapse;
- sound preceding its physical cause;
- camera movement or cut concealing an undefined transition.

Do not paste the entire battery into every prompt. Choose the failure modes implied by the contract so signal remains strong.

## Stage 6 — sampled-frame atomic QA

A successful queue and clean decode are technical evidence only. Extract full-frame contacts and crops around supports, hands, feet, wheels, props, and collision zones.

Ask dependency-ordered questions:

1. Are all required actors and objects present before the action?
2. Are the specified supports planted and load-bearing before acceleration?
3. Does anticipation/loading visibly precede initiation?
4. Is the primary trajectory continuous?
5. Does the contact or release event visibly occur?
6. Does the target/environment react only after that event?
7. Is reaction direction compatible with the force path?
8. Does the initiator show recoil, follow-through, or a balance consequence?
9. Do secondary materials respond after the primary event and settle plausibly?
10. Does the clip reach the exact persistent end state?
11. Do identity, limb count, object count, wardrobe, damage, and environment remain continuous?

If an upstream question fails, dependent claims are `UNVERIFIABLE`; do not infer contact physics from a later dramatic pose. Automated/VLM review may flag obvious anomalies but cannot establish conservation laws or replace human inspection.

## Stage 7 — targeted repair

Repair the smallest failed unit:

- support failure → strengthen starting stance/keyframe or replace motion authority;
- missed contact → shorten the clip and isolate the contact event;
- reaction-order failure → split initiation and consequence into separate units;
- trajectory failure → supply motion video or local previs;
- camera concealment → regenerate the proof shot, not the whole sequence;
- secondary-effect failure → keep accepted primary motion and regenerate only consequence coverage where possible.

Create a new numbered workflow/output version for changed conditioning, keyframes, references, or action contracts. Preserve rejected clips, prompts, seeds, histories, sampled frames, and ledgers.

## Acceptance states

- `MECHANICS_PASS` — every required atomic question has visible evidence and the user accepts the mechanics.
- `CINEMATIC_PASS` — the requested cuts, coverage functions, action impression, and broad continuity succeed; this does not imply mechanics proof.
- `REJECT` — a critical invariant for the declared mode fails.
- `UNVERIFIABLE` — proof is hidden, missing, ambiguous, or dependent on a failed earlier event.

## Pre-delivery checklist

- [ ] Mode declared: mechanics-proof or creative-montage
- [ ] One dominant transition per scored shot and readable dramatic job
- [ ] Creative montage has distinct coverage functions, scales, heights, axes, and lenses
- [ ] Turbo extrapolation above four steps is explicitly labeled and paired against the speed control
- [ ] Reference count matches the narrowest identity requirement
- [ ] Geography and screen direction locked
- [ ] Initial supports, center of mass, motion, materials, and grips recorded
- [ ] Initiating force and ordered force path explicit
- [ ] Contact/release precedes reaction
- [ ] End state and persistent consequences explicit
- [ ] FL2VA/REF2VA decision matches the uncertainty
- [ ] Motion authority rights and exact role recorded
- [ ] Proof shot protects mechanics; style shot remains separate
- [ ] Official H3 adapter changed format only, not action
- [ ] Production faces resolve to accepted Klein realism authorities
- [ ] Sampled-frame atomic QA complete
- [ ] Failed units versioned and repaired without overwriting evidence
