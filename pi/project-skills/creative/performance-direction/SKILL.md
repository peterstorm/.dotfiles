---
name: performance-direction
description: "Directs believable character performance for locally generated image and video scenes. Use for dialogue, reaction, listening, silent tension, cockpit acting, ensemble interaction, or any face that reads frozen, glassy, generic, melodramatic, or externally choreographed. Converts scene context into a shared scene pursuit, distinct personal motives, playable partner-directed actions, listener work, turning points, and evidence-based performance QA. Pairs with human-motion-realism-production, cinema-director, and ensemble-action-production; it owns performance intent and acceptance, not physiological motion, camera, model selection, or story canon."
license: MIT
compatibility: "Pi project skill; model-agnostic, with conservative defaults for local Krea 2 keyframes and MiniMax H3 clips."
---

# Performance Direction

Believable acting is not a list of facial movements. It is visible attention under pressure.

This skill turns a complete scene into playable work:

`scene context → shared pursuit → personal motive → obstacle → partner-directed action → beat changes → listener work → sampled-frame acceptance`

Do not direct an emotion as a pose. Give the character something specific to accomplish with another person, object, or piece of information, then verify that changing attention is visible.

## Ubiquitous language

- **Shared pursuit** — the immediate social condition all characters are trying to preserve, change, or survive during the scene.
- **Personal motive** — why this character invests in that pursuit.
- **Playable action** — an active verb aimed at a partner or problem: reassure, test, conceal, recruit, disarm, corner, steady, provoke, protect.
- **Attention target** — the person, object, sound, memory, or risk the character is actively reading.
- **Listener task** — what a non-speaking character is trying to learn, prevent, or decide while listening.
- **Beat change** — a new piece of information or pressure that forces a different playable action.
- **Break point** — the moment a tactic can no longer sustain the shared pursuit.
- **Performance proof** — sampled visual evidence that attention, listening, and beat changes are legible without relying on the prompt.

## Hard rules

1. **Read the entire scene first.** Never derive acting direction from an isolated line.
2. **Characters play immediate pursuits, not themes.** A performer cannot play “the audience learns she is brave.” She can protect a teammate from noticing her fear.
3. **Use actions, not emotion labels.** Replace “sadly” with the action that creates pressure: hide the loss, make them stay, refuse their pity.
4. **No facial puppeteering.** Do not prescribe eyebrow, lip, cheek, or tear choreography as the primary instruction.
5. **Every visible character has a task.** Silent listeners and background principals cannot become idle mannequins.
6. **Attention must change for a reason.** Gaze changes follow information, risk, sound, or a tactical check; they are not decorative eye motion.
7. **One primary performance turn per short clip.** A five-second H3 clip should not attempt an entire dramatic scene.
8. **Verify the render.** A well-written task does not prove that the actor performed it.
9. **Fail closed.** Frozen attention, contradictory reactions, unmotivated gaze, or an invisible required turn rejects the clip.
10. **Respect consent and identity.** Do not synthesize intimate, humiliating, or deceptive performance with a real person's likeness without authorization.
11. **Hand off physiology.** Use `human-motion-realism-production` to derive eye-head sequencing, blink windows, breath/support behavior, gesture phases, fidget limits, response latency, and dense fast-event QA from the locked performance task.
12. **Write dialogue for a mouth, not a page.** Default conversational English to contractions and short playable thought groups. Use expanded forms only for deliberate emphasis (`It is the timing—not the song`) or a character-specific register. A contraction rendered as mechanically separated syllables fails acting QA even when the input text is correct.

## Stage 1 — scene read

Record:

- what happened immediately before;
- what each character knows and does not know;
- the scene's final beat;
- the relationship at entry;
- the relationship at exit;
- the physical activity carrying the scene;
- the one required audience-readable change.

Read backward from the final beat. If the ending does not alter the relationship, knowledge, commitment, or danger, the scene may not contain a usable turn.

## Stage 2 — shared pursuit and individual work

Write one shared pursuit in ordinary social language. Then give every principal a different motive and playable action.

| Character | Personal motive | Immediate goal | Obstacle | Playable action | Attention target | Listener task |
|---|---|---|---|---|---|---|

Good shared pursuits:

- keep the team calm until the hatch seals;
- make this conversation feel routine;
- prevent the others from realizing the signal is inside the ship;
- finish the performance without acknowledging the attack.

Weak formulations:

- reveal the theme;
- be emotional;
- look alive;
- establish backstory;
- show that she is the leader.

## Stage 3 — beat map

Tie each beat change to information or pressure.

| Beat | Trigger | Speaker action | Listener task | Attention shift | Required visible evidence |
|---|---|---|---|---|---|

Use at most one major turn in a short generated clip. Split longer dialogue into reaction, response, and consequence coverage rather than asking one generation to perform every beat.

## Prompt block

Use this compact block inside the scene prompt:

```text
PERFORMANCE TASK — [CHARACTER]
Shared pursuit: [immediate social condition everyone is trying to preserve or change].
Personal motive: [why this character invests].
Immediate goal: [what this person needs from the partner now].
Pressure: [what threatens the pursuit].
Playable action: [active verb aimed at partner/problem].
Attention work: [what the character is reading or testing and what new information changes it].
Listener work: [what the character evaluates whenever not speaking].
Turn: [single trigger] changes the action from [verb] to [verb].
Human-motion handoff: [attention target, support state, speech state, pressure, and required visible response channel] pass to human-motion-realism-production. Do not add generic fidget or blink-rate instructions here.
```

Do not duplicate camera, wardrobe, prop, or lighting instructions here. Those belong to their owning skills.

## Local-model strategy

### Krea keyframe

Use Krea to establish:

- readable partner geometry;
- unobstructed eyes when eye work matters;
- hands and hero props in a plausible resting state;
- the correct pre-turn state, not a collage of multiple emotions.

Reject the keyframe if the performance premise is already contradicted.

### H3 clip

For a five-second clip:

- establish the active attention target immediately;
- permit one simple physical activity;
- permit one tactical change;
- end on a readable consequence or decision;
- avoid simultaneous dialogue, complex locomotion, prop engagement, and a large camera move.

When exact song lip-sync is required, use a qualified local audio-reference workflow. Do not infer sync from lyrics in the prompt.

After intent is locked, apply `human-motion-realism-production`. Keep its microbehavior sparse: one attention sequence, one breath/support behavior, and at most one motivated hand or self-contact action per principal in a short clip.

## Performance QA

Listen without reading the script before judging visual sync. Reject dialogue that sounds mechanically segmented, equally stressed, or exposition-read even when every word is intelligible. Distinguish an authoring failure from a synthesis/prosody failure so a correctly contracted script is not rewritten to solve the wrong problem.

Inspect at least nine chronological samples and denser samples around the turn.

| Invariant | Verdict | Evidence |
|---|---|---|
| Attention has a readable target | PASS / REJECT / UNVERIFIABLE | timestamps |
| Listening remains active when silent | PASS / REJECT / UNVERIFIABLE | timestamps |
| The playable action is visible without prompt knowledge | PASS / REJECT / UNVERIFIABLE | timestamps |
| The turn follows its trigger | PASS / REJECT / UNVERIFIABLE | before/after frames |
| Gaze and body behavior remain physically coherent | PASS / REJECT / UNVERIFIABLE | timestamps |
| No frozen or generic idle interval dominates | PASS / REJECT / UNVERIFIABLE | occupancy estimate |
| End state is readable | PASS / REJECT / UNVERIFIABLE | final proof frame |

All critical rows must pass. `UNVERIFIABLE` rejects the clip.

Load `references/performance-brief-template.md` for the production artifact.
