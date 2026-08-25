# Human motion realism — research and production translation

This reference separates measured findings from conservative prompt heuristics. Population averages are **not** animation quotas. Generated-video prompting should preserve causal order and variability rather than force every measured phenomenon into every clip.

## 1. Eyes are active even during fixation

### Evidence

- Human vision uses saccades, fixations, drift, tremor, and microsaccades rather than a perfectly stationary optical axis.
- Under natural fixation, spontaneous microsaccades have been reported around 2–3 Hz and correlate with covert shifts of spatial attention (Yuval-Greenberg et al., 2014; PMID `25297096`).
- Eye and head motion are coordinated rather than independent. Data-driven gaze work observes a measurable latency between eye and head movement and a relationship between gaze position and head angular velocity (Hu et al., 2019; PMID `30794182`).
- Large eccentric saccades can recruit subtle coordinated facial, jaw, and neck activity in healthy humans (Kaski et al., 2022; PMID `35235436`).

### Production translation

Do not ask a video model to visibly render microsaccades at a numeric frequency. At ordinary shot sizes they are below reliable generation and display thresholds. Instead:

1. give the eyes one explicit target;
2. use a quick target acquisition rather than smooth eyeball drift;
3. allow tiny non-periodic fixation corrections;
4. for a larger target change, let the eyes begin before the head;
5. let the head settle while the eyes maintain the target or counter-rotate slightly;
6. recruit upper torso only when target angle, urgency, or task requires it.

A five-second close or medium shot usually needs no more than one major attention-target change. Random repeated eye darts read as anxiety, deception, or broken tracking.

## 2. Blink rate changes with task

### Evidence

Bentivoglio et al. measured 150 healthy volunteers and found mean blink rates of approximately:

- 17/min at quiet rest;
- 26/min during free conversation;
- 4.5/min while reading.

The distributions varied substantially between people, but the task effect was strong (1997; PMID `9399231`). This means “one blink every three seconds” is not a universal realism rule.

Nakano et al. found that listeners' blinks followed speakers' blinks by roughly 0.25–0.5 seconds, particularly when the speaker blink occurred at the end of or during pauses in speech (2011; PMID `20700731`).

### Production translation

- Place a blink in a **window**, not on a clock.
- Useful windows: after a gaze lands, at a phrase boundary, during a pause, after reading completes, or after a high-attention hold releases.
- Concentrated visual inspection may contain no readable blink in a short clip.
- Conversational clips may support one or occasionally two blinks, but variation is normal.
- Blinks should be bilateral, brief, and complete. Avoid alternating eyes, long closures, half-blinks that deform identity, and repeated periodic blinking.
- Do not synchronize every listener blink. Blink entrainment is a possible social behavior, not a mandatory animation event.

## 3. Gaze is social and predictive

### Evidence

- In dyadic conversation, listeners use gaze to follow the current speaker and predict upcoming turns. Challenging listening conditions increase gaze toward the speaker and can shift gaze toward the mouth (Hadley et al., 2019, PMID `31320658`; Gambi et al., 2022, PMID `35405537`).
- Cross-linguistic turn-taking research finds remarkably short transitions between speakers, often centered near roughly 200 ms, while preserving cultural and contextual variation (Stivers et al., 2009, DOI `10.1073/pnas.0903616106`).

### Production translation

- The listener generally has more sustained partner-oriented attention than a person formulating speech.
- A speaker may glance away while retrieving or organizing thought, then return gaze as the turn resolves or to check impact.
- A listener can anticipate the next speaker before speech begins, but should not snap mechanically on every turn.
- In noise, distance can close, speech can shorten, and gaze can move toward the mouth.
- Preserve a small response latency: information lands, eyes/breath register it, then head/posture/voice acts. Instant full-face and full-body reaction reads externally choreographed.

## 4. Quiet stance is dynamic, not frozen

### Evidence

Center-of-pressure research treats healthy quiet standing as continual low-amplitude postural control rather than zero motion. Standard posturography measures sway path, area, velocity, and directional variability even in healthy adults (Prieto et al., 1996, DOI `10.1109/10.532130`).

### Production translation

- State the support foot or support distribution.
- Keep knees, hips, spine, and shoulders tonically engaged rather than locked straight.
- Use a small non-periodic load redistribution only when a duration, reach, uncertainty, or environmental force motivates it.
- Breathing should move local anatomy and clothing subtly; it should not create synchronized whole-body vertical bobbing.
- Seated subjects still have seat/back/foot contacts, soft tissue compression, forearm or hand support, and occasional pressure redistribution.
- Deliberate stillness can be almost motionless while retaining breath, eye fixation life, muscle tone, and gravity.

## 5. Reaches and gestures are phrases

### Evidence

Goal-directed arm movement is characteristically smooth, with coordinated acceleration and deceleration. The minimum-jerk model remains a foundational description of unconstrained reaching trajectories (Flash & Hogan, 1985, DOI `10.1523/JNEUROSCI.05-07-01688.1985`).

Gesture and speech are biomechanically and temporally coupled; gesture strokes align with prosodically important speech events rather than occurring as unrelated hand noise (Pouw et al., 2020, DOI `10.1037/xge0000646`).

### Production translation

Use the phrase:

`rest tone → preparation → stroke or contact → optional hold → recovery → settled rest`

For reaching and object contact:

- shoulder and torso establish the reach path;
- hand accelerates, then decelerates approaching the target;
- fingers pre-shape before contact;
- grip closes only after contact;
- object reaction follows contact;
- hand and shoulder settle after completion.

For speech gesture:

- preparation may begin before the emphasized word;
- the stroke aligns with the stressed concept or syllable;
- a hold can bridge hesitation or protect the conversational floor;
- recovery returns the hand to a plausible support/rest state.

Avoid endless hand circulation, independent finger swimming, identical repeated gestures, and hands frozen in an expressive shape after the communicative job is over.

## 6. Fidgeting is not generic realism dust

Fidgeting and self-adaptors are context-sensitive. Hair touching, thumb rubbing, garment adjustment, object checking, jaw tension, foot pressure, and posture changes can communicate cognitive load, self-regulation, impatience, concealment, or physical discomfort. Adding all of them creates caricature.

### Production heuristic

For a 4–6 second generated clip, choose at most one low-amplitude fidget channel per principal, and only when the performance task supplies a cause. Examples:

- concealing alarm → thumb presses once against a ring, then releases;
- waiting under scrutiny → weight moves toward the rear foot after the partner looks away;
- troubleshooting → eyes acquire the readout, fingers stop moving while reading, then one control adjustment follows;
- preparing to lie → breath catches, gaze leaves briefly to formulate, then returns before the answer;
- calm authority → purposeful stillness with stable support, one breath, and one deliberate gaze transfer; no decorative fidget.

## 7. Avoid synchronized biological loops

Generated video often turns “natural movement” into a loop: repeated nodding, blinking at equal intervals, constant shoulder breathing, finger flutter, or identical sway cycles.

Reject or repair when:

- timing repeats at a stable period without an external beat;
- multiple body channels peak together repeatedly;
- every principal blinks, breathes, or shifts weight in synchrony;
- eye motion continues after attention has settled;
- a listener mirrors the speaker with zero latency;
- movement never reaches a settled state.

Variation alone is not enough; causal timing is the primary realism signal.

## 8. Shot-size implications

### Extreme close-up

Eyes and lids dominate. Use one attention target, one acquisition or held fixation, and a context-timed blink only if needed. Dense frame QA is mandatory because eyelid geometry can morph identity.

### Close-up / medium close-up

Eyes lead; head follows on meaningful shifts. Jaw, throat, breath, and small hand behavior may be visible. Do not animate all simultaneously.

### Medium / full body

Support state and weight transfer matter more than visible microsaccades. Preserve feet, seat, or contact surfaces. Hands require plausible rest tone.

### Wide / ensemble

Distinct timing between principals matters more than tiny facial behavior. Give each principal one readable task and offset their head, support, or gesture timing. Avoid synchronized mannequin idles.

## 9. Evidence-aware prompt examples

### Silent listening

```text
Her attention stays on the speaker's eyes. When the off-screen sentence ends, her eyes drop once to the speaker's hand, her head follows only a few degrees, then she returns to the eyes after a short processing beat. One brief bilateral blink is permitted during the return, not periodically. She breathes quietly through the lower ribs, weight held through the seat and both feet, hands resting with living muscle tone and no finger movement.
```

### Cockpit diagnosis

```text
Her eyes acquire the warning readout first; the head follows a fraction later and settles. She holds the read without blinking, then releases one breath and blinks once after comprehension. Her right hand remains supported on the console until the read completes, then lifts, fingers pre-shaped for the recessed control, makes contact, depresses it, and returns to the console edge. No floating hand, no repeated tapping, no scanning eye loop.
```

### Purposeful stillness

```text
She remains deliberately still to avoid alarming the team. The stillness retains quiet rib breathing, stable load through the rear foot, tiny fixation corrections on her partner, and living jaw and neck tone. No random fidget, no repeated nod, no shoulder bob, and no frozen glassy eyes.
```

## 10. Source ledger

| Finding | Source |
|---|---|
| Blink rate varies strongly by task | Bentivoglio et al., “Analysis of blink rate patterns in normal subjects,” 1997, PMID `9399231` |
| Listener blink entrainment at speech breakpoints | Nakano et al., “Eyeblink entrainment at breakpoints of speech,” 2011, PMID `20700731` |
| Spontaneous microsaccades and covert attention | Yuval-Greenberg et al., “Spontaneous microsaccades reflect shifts in covert attention,” 2014, PMID `25297096` |
| Eye–head movement latency in gaze prediction | Hu et al., “SGaze,” 2019, PMID `30794182` |
| Gaze-linked facial/jaw recruitment | Kaski et al., 2022, PMID `35235436` |
| Speech, movement, and gaze in noisy dyadic conversation | Hadley et al., 2019, PMID `31320658` |
| Predictive gaze and turn comprehension | Gambi et al., 2022, PMID `35405537` |
| Conversational turn-transition timing | Stivers et al., 2009, DOI `10.1073/pnas.0903616106` |
| Quiet-standing postural sway | Prieto et al., 1996, DOI `10.1109/10.532130` |
| Smooth goal-directed reaching | Flash & Hogan, 1985, DOI `10.1523/JNEUROSCI.05-07-01688.1985` |
| Gesture–speech synchrony | Pouw et al., 2020, DOI `10.1037/xge0000646` |
