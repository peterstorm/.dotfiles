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

- **Action unit** — one short H3 clip containing one dominant physical transition.
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
- one dominant physical transition;
- what must remain visible to prove it.

Split the plan when one clip asks for several independent risky transitions. Prefer 4–6 second action units. A longer H3 duration is available but does not justify packing a complete fight into one generation.

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

## Stage 3 — proof and style coverage

The critical mechanic needs a proof shot:

- wide or medium-wide enough to see supports, trajectory, contact, and both bodies;
- static, restrained tracking, or modest operator movement through the contact event;
- no cut, whip, occlusion, debris cloud, or close crop that hides undefined mechanics.

A separate style shot may use an aggressive angle, tighter impact insert, orbit, whip, shake, or speed change. Never use style coverage as the only evidence that contact happened correctly.

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

- `PASS` — every required atomic question has visible evidence and the user accepts the mechanics.
- `REJECT` — a critical support, trajectory, contact, reaction, identity, or end-state invariant fails.
- `UNVERIFIABLE` — proof is hidden, missing, ambiguous, or dependent on a failed earlier event.

## Pre-delivery checklist

- [ ] One dominant transition and readable dramatic job
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
