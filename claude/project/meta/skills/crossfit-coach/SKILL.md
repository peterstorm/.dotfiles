---
name: crossfit-coach
description: "Create and schedule CrossFit workouts on Garmin Connect. Use when user asks to 'create a CrossFit workout', 'make a WOD', 'build an EMOM', 'schedule a CrossFit session', 'AMRAP workout', 'Tabata', 'for time workout', or any request to create a non-running workout for Garmin."
allowed-tools: Read, Bash, Write, Glob
---

# CrossFit Workout Builder for Garmin Connect

Creates structured CrossFit workouts (EMOM, AMRAP, For Time, Tabata) and schedules them on Garmin Connect via the `garmin-schedule-workout.ts` script.

## Garmin Workout Constraints

- **Sport type:** HIIT — `{ "sportTypeId": 9, "sportTypeKey": "hiit", "displayOrder": 7 }` (full sportTypeId table in vault note)
- **Schedule script:** `bun /home/peterstorm/dev/claude-plugins/reclaw/scripts/garmin-schedule-workout.ts YYYY-MM-DD`
- **Input:** Workout JSON on stdin
- **Max steps per workout:** 50 (Garmin limit)

## Input Parsing

Parse `$ARGUMENTS` or conversational context for:

1. **Workout format** — EMOM, AMRAP, For Time, Tabata, or custom
2. **Movements** — exercises with reps/cals (e.g., "15 cal row", "8 deadlifts", "12 burpees")
3. **Duration/rounds** — total time or number of cycles
4. **Weights** — if mentioned (e.g., "60kg deadlifts")
5. **Target date** — when to schedule (default: today; resolve with `date +%F`)

If the user gives a WOD description, parse it. If they ask for a workout, design one appropriate for CrossFit.

## Review Recent Training History (REQUIRED before designing)

**Never design a CrossFit/strength workout without first looking back at recent sessions.** Skip this only when the user has already specified the exact workout (movements, reps, weights) and is asking you to schedule it verbatim.

### What to read

```
find ~/dev/notes/remotevault/personal/fitness/ -name "*.md" -not -name "MOC.md" | sort -r | head -30
```

Walk back up to **30 days** and read every fitness note that contains a `CrossFit/Strength Analysis` section. From each, extract:

- Date and session format (EMOM / AMRAP / For Time / Strength / Mixed)
- Per-movement loads and reps from `completedSets` (e.g. "Back Squat 5×5 @ 100kg", "Pull-ups 4×8 strict")
- Total training load, anaerobic TE, duration, RPE/feel
- Movement patterns (lower-body barbell, gymnastics pulling, monostructural, etc.)
- Any progressive-overload verdict line ("Net: overload" / "regression on deadlift" / "maintenance")

Also pull the last 1–2 days of fitness notes for **today's readiness context**: training readiness score, sleep, HRV, recovery time, and whether yesterday was a hard day. If the running coach is on the schedule for tomorrow (Thu run after Tue CrossFit), factor in leg-recovery cost.

Build a small in-memory ledger of "movement → recent set/rep/load history" and "weekly volume by pattern (squat / hinge / press / pull / gymnastics / monostructural)". This is the input to the design rules below.

## Apply Progressive Overload (when designing strength or repeated benchmarks)

When designing — not when transcribing a user-specified WOD — pick loads and rep schemes against the ledger using these rules in order:

1. **Heavier load at equal-or-higher reps** = clean overload. Default move when previous session hit all prescribed reps with RPE ≤ 8.
2. **Same load, more reps or more sets** = volume progression. Use when the previous load felt heavy (RPE 9+) or reps were broken.
3. **Same load × same reps × same sets** = consolidation. Use after a recent jump, on low-readiness days, or when the user has missed sessions.
4. **Lighter / fewer reps** = deload. Use only when readiness is poor, user is sick/sore, or the last 1–2 sessions showed regression.
5. **New movement** (no record in 30 days) = baseline. Pick a conservative load and explicitly mark it as a baseline so the next session has a reference.

For repeated benchmark WODs (Fran, Cindy, Murph, a previously-scheduled EMOM, etc.), reference the previous score/time and target a measurable improvement — faster time, more rounds, or RX'd where last attempt was scaled.

For unloaded/gymnastics movements, progress = more unbroken reps, harder progression (kipping → strict → weighted → deficit), or shorter rest, in that order.

### Movement balance & recovery

- Avoid stacking 3+ heavy lower-body barbell sessions in a 7-day window (squat / deadlift / clean / thruster). If the ledger already shows two this week, bias today toward upper-body, gymnastics, or monostructural.
- If tomorrow is a quality run day (Thursday), avoid heavy posterior-chain loading today.
- Note any redundancy: "third pulling session this week — drop pull-ups in favor of pressing or rowing".

## Output the design rationale

After scheduling, the confirmation block must include a short **rationale** section explaining the progression choice, e.g.:

```
Progression: Back Squat 5×5 @ 105kg (+5kg vs 2026-04-26, last session hit all reps RPE 7).
Balance: Second lower-body session this week; pairing with upper-body pulling rather than more squatting next time.
Readiness fit: Training readiness 72 with full recovery — green light for overload.
```

If the user specified the workout verbatim, skip the rationale (just schedule it).

## Workout Format Templates

### EMOM (Every Minute On the Minute)

Structure: RepeatGroup wrapping N interval steps (one per minute), each 60s time-based.

- Each movement minute = `ExecutableStepDTO` with `stepType: interval`, `endCondition: time`, `endConditionValue: 60`
- Rest minutes = `ExecutableStepDTO` with `stepType: rest`, `endCondition: time`, `endConditionValue: 60`
- Wrap all minutes in a `RepeatGroupDTO` with `numberOfIterations` = number of rounds
- Total time = minutes per round x rounds
- Watch auto-advances every 60s — no button presses

### AMRAP (As Many Rounds As Possible)

Structure: Single long interval step with a time cap.

- One `ExecutableStepDTO` with `stepType: interval`, `endCondition: time`, `endConditionValue: TOTAL_SECONDS`
- Description lists all movements and reps (watch displays this)
- No repeat group needed — it's one continuous block
- Athlete tracks rounds mentally; watch just counts down

### For Time

Structure: Steps with `lap.button` end condition — athlete presses lap when movement is done.

- Each movement = `ExecutableStepDTO` with `stepType: interval`, `endCondition: lap.button` (`conditionTypeId: 1`)
- Set `endConditionValue: null` for lap.button steps
- Optional: wrap in RepeatGroup if workout has multiple rounds
- Optional: add a time cap as a note in the description

### Tabata

Structure: RepeatGroup of work/rest pairs.

- Work step: `stepType: interval`, `endCondition: time`, `endConditionValue: 20`
- Rest step: `stepType: rest`, `endCondition: time`, `endConditionValue: 10`
- Wrap both in RepeatGroup with `numberOfIterations: 8` (standard Tabata)
- Total: 4 minutes per Tabata block

## Exercise Category & Name Mapping

Populate `category` and `exerciseName` on each step to avoid "—" display on watch. Use `null` for exerciseName if the exact Garmin name is unknown — category alone helps.

Full movement → Garmin mapping table, confirmed mappings, and correction history in vault: `~/dev/notes/remotevault/reclaw/skills/crossfit-coach.md` → "Exercise Metadata"

## Workout JSON Structure

The Garmin workout JSON schema is **shared with the running coach** — read the canonical
reference and follow its **Sport deltas → Strength / CrossFit** section (this replaces the copy
that used to live inline here and had drifted from the running copy):

```bash
cat /home/peterstorm/dev/claude-plugins/reclaw/workspace/skills/shared/garmin-workout-schema.md
```

It covers: the top-level shape (CrossFit uses `sportType` HIIT — `{ "sportTypeId": 9, "sportTypeKey": "hiit", "displayOrder": 7 }`), the ExecutableStepDTO / RepeatGroupDTO templates, the step-type and end-condition tables, the shared gotchas (stepOrder, childStepId, rest steps, lap.button, `endConditionCompare` empty-string), and the strength delta (`category`, `exerciseName`, `weightValue` in kg, always with `weightUnit`). Build the workout JSON inline following those templates, then schedule it with the command in the shared file's **Creating & scheduling** section (`garmin-schedule-workout.ts <date>`, default today `$(date +%F)`). On failure: auth error → report and stop; API error → report the error and show the JSON so the user can debug.

## Editing Existing Workouts

Fetch → modify → PUT back. See vault note for code template and gotchas: `~/dev/notes/remotevault/reclaw/skills/crossfit-coach.md` → "Editing Workouts"

## Output

After scheduling, confirm:

```
Scheduled on Garmin for [date]:

[Workout Name]
[Format] — [total time]

[Movement list with reps/weights]

Workout ID: [ID]
```

If you applied progressive-overload reasoning when designing (i.e. you weren't just transcribing a user-specified WOD), append the rationale block described in "Apply Progressive Overload" above the Workout ID line.

## Iteration

If the user reports issues (wrong sport type, missing exercise names, display problems), adjust and reschedule. The Garmin exercise name catalog is reverse-engineered — some names may not match. When an exercise name is rejected or shows "—", try `null` for that field and note the finding for future reference.
