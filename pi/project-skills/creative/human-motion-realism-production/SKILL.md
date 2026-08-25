---
name: human-motion-realism-production
description: "Directs and verifies lifelike human microbehavior in locally generated video. Use when eyes look static or glassy, people appear frozen or mannequin-like, blinking/fidgeting feels random, dialogue reactions are instantaneous, hands float, posture lacks weight, or breathing, gaze shifts, eye-head coordination, listener behavior, gesture timing, and settling need realism. Converts attention, support, speech, and task state into sparse motivated motion cues and frame-sampled QA. Pairs with performance-direction and cinema-director; it owns physiological execution, not acting intent or camera style."
license: MIT
compatibility: "Pi project skill; model-agnostic, with conservative prompt density for local MiniMax H3 clips. Research-derived priors are production heuristics, never rigid biological quotas."
---

# Human Motion Realism Production

Human beings are never mathematically static, but realism does not come from adding random motion everywhere. It comes from **sparse movement caused by attention, support, breathing, speech, contact, and decision**.

This skill owns:

`performance task + physical state → motivated microbehavior contract → compact prompt cues → dense sampled-frame QA → targeted repair`

It does not own dramatic intent (`performance-direction`), camera/capture (`cinema-director`), screen geometry (`blocking-continuity`), or force/contact mechanics (`action-physics-production`).

Load [the research and production reference](references/human-motion-realism.md) whenever this skill is used for video prompting or QA.

## Ubiquitous language

- **Attention target** — the person, object, sound, interface, or remembered location currently being sampled.
- **Gaze acquisition** — the coordinated eye, head, and optionally upper-torso movement that establishes a new attention target.
- **Fixation life** — tiny non-decorative eye corrections that keep a held gaze from reading as a frozen texture.
- **Support state** — the feet, seat, back, arm, hand, or surface currently carrying body weight.
- **Support adjustment** — a small load redistribution caused by fatigue, reach, speech, uncertainty, or a changed task.
- **Respiratory motion** — subtle rib, sternum, shoulder, throat, and garment movement caused by breathing or speech.
- **Gesture phrase** — preparation, expressive stroke, optional hold, and recovery to rest.
- **Response latency** — the short physically visible interval between receiving information and beginning the response.
- **Motivated fidget** — a low-amplitude self-contact or object adjustment caused by a playable pressure, not generic motion noise.
- **Purposeful stillness** — deliberate low-movement behavior that still contains fixation life, breathing, muscle tone, and support.
- **Microbehavior proof** — frame evidence that motion follows cause, remains anatomically coherent, and avoids periodic or random animation.

## Hard rules

1. **Cause every movement.** Gaze, blink, breath, weight shift, self-touch, and gesture must follow attention, speech, support, contact, or pressure.
2. **Do not animate every channel.** A five-second clip usually needs one primary action and only two or three supporting microbehavior channels.
3. **Eyes acquire; they do not drift.** Target changes use a quick saccadic relocation followed by fixation. Avoid smooth independent eyeball sliding.
4. **Large gaze shifts recruit the head.** Eyes usually begin the acquisition; head and sometimes upper torso follow according to target eccentricity.
5. **Blink timing is contextual, not metronomic.** Favor gaze transitions, phrase boundaries, pauses, or release after concentrated looking. Never request “blink every N seconds.”
6. **Stillness retains physiology.** Quiet characters breathe, maintain muscle tone, make tiny fixation corrections, and carry weight through explicit supports.
7. **Fidgeting is sparse and character/task specific.** One thumb rub, cuff adjustment, pressure change, or object check can help; continuous finger swimming and repeated loops reject the clip.
8. **Gestures have phases.** Preparation precedes the stroke; recovery follows it. Hands do not pop into expressive poses or remain suspended without purpose.
9. **Responses are not instantaneous.** Perception precedes orientation, decision, and action. Preserve a readable latency unless reflex is the dramatic fact.
10. **Verify densely.** Sparse nine-frame sampling is insufficient for blinks, saccades, and contact-adjacent hand behavior.
11. **Never sacrifice identity.** Eye, lid, mouth, hand, or head motion that morphs identity or anatomy rejects the clip.
12. **Research values are priors, not quotas.** Scene truth and visible evidence outrank numeric averages.

## Stage 1 — behavioral baseline

Record one row per visible principal:

| Principal | task | attention target | support state | speech state | arousal/load | permitted microbehavior | forbidden loop |
|---|---|---|---|---|---|---|---|

Then state whether the shot requires active movement or purposeful stillness. Do not use “natural movement” or “subtle fidgeting” without naming the cause and body channel.

## Stage 2 — microbehavior contract

Choose only the channels the shot can support.

### Attention and gaze

Record:

- starting target;
- trigger for any target change;
- acquisition order: eyes → head → optional upper torso;
- hold duration in scene terms, not a rigid stopwatch quota;
- return target or final fixation;
- whether the eyes must remain readable in frame.

For a small nearby shift, eyes may move without the head. For a moderate or large shift, the eyes lead and the head follows after a short latency. The eyes may counter-rotate slightly as the head settles.

### Blink plan

State a **window and cause**, never a recurring rate:

- after the gaze lands;
- at a speech pause or phrase boundary;
- after a concentrated read completes;
- during a listener's processing beat.

Use zero, one, or occasionally two readable blinks in a short clip according to task. A blink must be bilateral, brief, physically complete, and identity-preserving.

### Breath and support

Name:

- load-bearing foot/seat/back/hand;
- one subtle breath cycle or speech-breath phase when visible;
- whether the breath reaches ribs, sternum, throat, shoulders, or clothing;
- any motivated support adjustment and its trigger;
- the final settled support state.

Do not use whole-body vertical bobbing as a substitute for breath.

### Gesture and hands

A hand action follows:

`rest tone → preparation → stroke/contact → optional hold → recovery → settled rest`

For a reach, the hand accelerates and decelerates smoothly, fingers pre-shape before contact, grip closes after contact, and the arm settles through the shoulder rather than freezing at the endpoint.

### Conversation and reaction

For each beat, identify:

- who currently owns the floor;
- where the speaker looks while formulating versus completing the turn;
- the listener task and gaze target;
- the information trigger;
- the response latency;
- the first visible response channel: eyes, breath, jaw, head, hand, or posture;
- the later deliberate action.

Listeners cannot become idle mannequins. They also must not mirror every speaker movement instantly.

## Stage 3 — compact prompt handoff

Pass this block to the video prompt only after dramatic intent and physical state are locked:

```text
HUMAN MOTION REALISM — [PRINCIPAL]
Attention: starts on [target]. [Trigger] causes a quick eye acquisition toward [new target]; the head follows [small/moderate amount] and settles while the eyes hold the target.
Blink window: [zero/one/two] natural bilateral blink(s), permitted only [cause/window], never periodic.
Breath and support: weight carried through [supports]; [subtle breath behavior]; [motivated support adjustment or purposeful stillness].
Hands/gesture: [rest state → preparation → stroke/contact → recovery], with no finger swimming or suspended pose.
Response latency: [information] lands first; visible response begins after [short processing beat] through [first channel], then [deliberate action].
```

Delete unused lines. Do not paste the whole block into every prompt. In crowded ensemble shots, assign one distinctive microbehavior sequence per principal rather than five simultaneous cues each.

## Stage 4 — local H3 strategy

For a 4–6 second clip:

- one dominant action;
- at most one major gaze-target change per principal;
- one visible response beat;
- zero to two context-driven blinks, not a prescribed rate;
- one breath/support behavior;
- one hand or garment adjustment only if motivated;
- one readable settled end state.

Split clips that also require complex locomotion, dialogue, prop manipulation, and a large camera move. Human microbehavior is the first signal H3 drops when the prompt is overloaded.

## Stage 5 — dense QA

Inspect normal playback first. Then inspect consecutive frames around every blink, gaze shift, hand contact, support change, and reaction onset.

| Invariant | Verdict | Evidence |
|---|---|---|
| Attention target is readable | PASS / REJECT / UNVERIFIABLE | timestamp/frame |
| Eye relocation precedes or coherently coordinates with head turn | PASS / REJECT / UNVERIFIABLE | consecutive frames |
| Fixation holds without glassy freeze or independent eye drift | PASS / REJECT / UNVERIFIABLE | interval |
| Blink is bilateral, brief, complete, and contextually placed | PASS / REJECT / UNVERIFIABLE | frame range |
| Breath is local and subtle rather than whole-body bobbing | PASS / REJECT / UNVERIFIABLE | interval |
| Weight remains supported and any adjustment has a cause | PASS / REJECT / UNVERIFIABLE | feet/seat crop |
| Gesture has preparation, stroke/contact, and recovery | PASS / REJECT / UNVERIFIABLE | frame range |
| Listener remains active without instant mirroring | PASS / REJECT / UNVERIFIABLE | interval |
| Response follows information with readable latency | PASS / REJECT / UNVERIFIABLE | before/after frames |
| No periodic fidget, finger swimming, head bob, or idle loop | PASS / REJECT / UNVERIFIABLE | full clip |
| Identity and anatomy survive eye/lid/head/hand motion | PASS / REJECT / UNVERIFIABLE | crops |
| End state settles physically | PASS / REJECT / UNVERIFIABLE | final frames |

`UNVERIFIABLE` rejects a required behavior. Do not infer realism from the prompt.

## Stage 6 — targeted repair

- glassy eyes → add one motivated target acquisition and shorten the hold; do not add random eye darts;
- eyes slide independently → specify quick acquisition, fixation, and eye-led head follow;
- mechanical blinking → remove rate language and tie one blink to a phrase/gaze boundary;
- frozen listener → strengthen the listener task and first response channel;
- excessive fidget → reduce to one pressure-linked self-contact or support change;
- body bobbing → localize breath to ribs/sternum/garment and lock support;
- hand swimming → define rest, one preparation, one contact/stroke, and recovery;
- instant reaction → insert a perception/processing beat before orientation or action;
- mannequin stillness → retain the pose but add breath, muscle tone, fixation life, and load-bearing support;
- overloaded result → split the clip rather than adding more realism language.

Create a new numbered prompt/output version for any changed behavior contract. Preserve the rejected clip and sampled-frame ledger.

## Pre-delivery checklist

- [ ] Every visible principal has a task and attention target
- [ ] Every requested microbehavior has a cause
- [ ] Large gaze changes coordinate eyes and head
- [ ] Blink windows are contextual, never periodic
- [ ] Support and breathing are explicit
- [ ] Gestures include preparation and recovery
- [ ] Fidgeting is sparse and character-specific
- [ ] Purposeful stillness is physiological, not frozen
- [ ] Response latency is readable
- [ ] Dense frame QA is planned around fast events
- [ ] Camera language remains with cinema-director
- [ ] Dramatic intent remains with performance-direction
