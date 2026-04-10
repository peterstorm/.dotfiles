---
name: crossfit-coach
description: "Create and schedule CrossFit workouts on Garmin Connect. Use when user asks to 'create a CrossFit workout', 'make a WOD', 'build an EMOM', 'schedule a CrossFit session', 'AMRAP workout', 'Tabata', 'for time workout', or any request to create a non-running workout for Garmin."
allowed-tools: Read, Bash, Write, Glob
---

# CrossFit Workout Builder for Garmin Connect

Creates structured CrossFit workouts (EMOM, AMRAP, For Time, Tabata) and schedules them on Garmin Connect via the `garmin-schedule-workout.ts` script.

## Garmin Workout Constraints

- **Sport type:** HIIT — `{ "sportTypeId": 9, "sportTypeKey": "hiit", "displayOrder": 7 }`
- **Schedule script:** `bun /home/peterstorm/dev/claude-plugins/reclaw/scripts/garmin-schedule-workout.ts YYYY-MM-DD`
- **Input:** Workout JSON on stdin
- **Max steps per workout:** 50 (Garmin limit)

## Input Parsing

Parse `$ARGUMENTS` or conversational context for:

1. **Workout format** — EMOM, AMRAP, For Time, Tabata, or custom
2. **Movements** — exercises with reps/cals (e.g., "15 cal row", "8 deadlifts", "12 burpees")
3. **Duration/rounds** — total time or number of cycles
4. **Weights** — if mentioned (e.g., "60kg deadlifts")
5. **Target date** — when to schedule (default: today, `{{date}}`)

If the user gives a WOD description, parse it. If they ask for a workout, design one appropriate for CrossFit.

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

### CrossFit Movement → Garmin Mapping

| Movement | category | exerciseName |
|----------|----------|--------------|
| Air Squat | SQUAT | SQUAT |
| Back Squat | SQUAT | BARBELL_BACK_SQUAT |
| Front Squat | SQUAT | BARBELL_FRONT_SQUAT |
| Overhead Squat | SQUAT | OVERHEAD_SQUAT |
| Goblet Squat | SQUAT | GOBLET_SQUAT |
| Wall Ball | SQUAT | WALL_BALL |
| Thruster | SQUAT | THRUSTERS |
| Deadlift | DEADLIFT | BARBELL_DEADLIFT |
| Sumo Deadlift | DEADLIFT | SUMO_DEADLIFT |
| Clean | OLYMPIC_LIFT | CLEAN |
| Clean & Jerk | OLYMPIC_LIFT | CLEAN_AND_JERK |
| Power Clean | OLYMPIC_LIFT | POWER_CLEAN |
| Hang Power Clean | OLYMPIC_LIFT | BARBELL_HANG_POWER_CLEAN |
| Snatch | OLYMPIC_LIFT | SNATCH |
| Power Snatch | OLYMPIC_LIFT | POWER_SNATCH |
| DB Hang Snatch | OLYMPIC_LIFT | DUMBBELL_HANG_SNATCH |
| Push Press | SHOULDER_PRESS | PUSH_PRESS |
| Push Jerk | SHOULDER_PRESS | PUSH_JERK |
| Shoulder Press | SHOULDER_PRESS | OVERHEAD_PRESS |
| Pull-Up | PULL_UP | PULL_UP |
| Chest-to-Bar | PULL_UP | CHEST_TO_BAR_PULL_UP |
| Toes-to-Bar | CRUNCH | TOES_TO_BAR |
| Muscle-Up (ring) | PULL_UP | MUSCLE_UP |
| Burpee | TOTAL_BODY | BURPEE |
| Box Jump | PLYO | BOX_JUMP |
| Box Jump Over | PLYO | BOX_JUMP_OVERS |
| Double Under | CARDIO | DOUBLE_UNDER |
| Row (calories/meters) | ROW | INDOOR_ROW |
| Bike (calories) | CARDIO | null |
| Ski Erg | CARDIO | null |
| Push-Up | PUSH_UP | PUSH_UP |
| Handstand Push-Up | PUSH_UP | HANDSTAND_PUSH_UP |
| Sit-Up | SIT_UP | SIT_UP |
| Lunge | LUNGE | WALKING_LUNGE |
| Kettlebell Swing | HIP_SWING | KETTLEBELL_SWING |
| Turkish Get-Up | TOTAL_BODY | TURKISH_GET_UP |
| Farmers Carry | CARRY | FARMERS_WALK |
| Rope Climb | PULL_UP | null |
| REST | null | null |

Unverified names may show "—" on watch — use `null` for exerciseName and rely on `description`. For confirmed mappings, corrections history, and gotchas see vault: `~/dev/notes/remotevault/reclaw/skills/crossfit-coach.md`

## Workout JSON Structure

### Required Fields

```json
{
  "workoutName": "[Format] [Duration] — [Brief description]",
  "description": "[Full human-readable workout description with all movements, reps, weights]",
  "sportType": { "sportTypeId": 9, "sportTypeKey": "hiit", "displayOrder": 7 },
  "workoutSegments": [{
    "segmentOrder": 1,
    "sportType": { "sportTypeId": 9, "sportTypeKey": "hiit", "displayOrder": 7 },
    "workoutSteps": [...]
  }]
}
```

### ExecutableStepDTO Template

```json
{
  "type": "ExecutableStepDTO",
  "stepId": null,
  "stepOrder": N,
  "stepType": { "stepTypeId": ID, "stepTypeKey": "KEY", "displayOrder": ID },
  "childStepId": null,
  "description": "Human-readable — reps, movement, weight",
  "endCondition": { "conditionTypeId": ID, "conditionTypeKey": "KEY", "displayOrder": ID, "displayable": true },
  "endConditionValue": VALUE_OR_NULL,
  "preferredEndConditionUnit": null,
  "endConditionCompare": null,
  "targetType": { "workoutTargetTypeId": 1, "workoutTargetTypeKey": "no.target", "displayOrder": 1 },
  "targetValueOne": null,
  "targetValueTwo": null,
  "targetValueUnit": null,
  "zoneNumber": null,
  "secondaryTargetType": null,
  "secondaryTargetValueOne": null,
  "secondaryTargetValueTwo": null,
  "secondaryTargetValueUnit": null,
  "secondaryZoneNumber": null,
  "endConditionZone": null,
  "strokeType": { "strokeTypeId": 0, "strokeTypeKey": null, "displayOrder": 0 },
  "equipmentType": { "equipmentTypeId": 0, "equipmentTypeKey": null, "displayOrder": 0 },
  "category": "EXERCISE_CATEGORY_OR_NULL",
  "exerciseName": "EXERCISE_NAME_OR_NULL",
  "workoutProvider": null,
  "providerExerciseSourceId": null,
  "weightValue": WEIGHT_KG_OR_0,
  "weightUnit": { "unitId": 8, "unitKey": "kilogram", "factor": 1000 }
}
```

### RepeatGroupDTO Template

```json
{
  "type": "RepeatGroupDTO",
  "stepId": null,
  "stepOrder": N,
  "stepType": { "stepTypeId": 6, "stepTypeKey": "repeat", "displayOrder": 6 },
  "childStepId": CHILD_GROUP_ID,
  "numberOfIterations": COUNT,
  "endCondition": { "conditionTypeId": 7, "conditionTypeKey": "iterations", "displayOrder": 7, "displayable": false },
  "endConditionValue": COUNT,
  "preferredEndConditionUnit": null,
  "endConditionCompare": null,
  "skipLastRestStep": null,
  "smartRepeat": false,
  "workoutSteps": [...]
}
```

### Step Type Reference

| Step | stepTypeId | stepTypeKey |
|------|-----------|-------------|
| warmup | 1 | `warmup` |
| cooldown | 2 | `cooldown` |
| interval | 3 | `interval` |
| recovery | 4 | `recovery` |
| rest | 5 | `rest` |
| repeat | 6 | `repeat` |

### End Condition Reference

| Condition | conditionTypeId | conditionTypeKey | Use |
|-----------|----------------|------------------|-----|
| Lap button | 1 | `lap.button` | For Time steps — athlete presses when done |
| Time | 2 | `time` | EMOM/AMRAP/Tabata — value in seconds |
| Iterations | 7 | `iterations` | Repeat groups — number of rounds |

### Rules

- **stepOrder** must be sequential across ALL steps including children of repeat groups, starting at 1
- **childStepId** for repeat children: all children of the same repeat group share the same childStepId (incrementing integer, starting at 1 for first repeat group)
- **Rest steps:** set `targetType` to `null` (not no.target)
- **Lap.button steps:** set `endConditionValue` to `null`
- **Weight:** set `weightValue` in kg if specified, otherwise `0`. Always include `weightUnit: { "unitId": 8, "unitKey": "kilogram", "factor": 1000 }`
- **endConditionCompare:** Garmin returns `""` (empty string) — safe to send as `null` on creation

## Creating & Scheduling

Write the workout JSON to a temp file and pipe to the schedule script:

```bash
cat > /tmp/workout.json << 'WORKOUT_EOF'
{ ... the workout JSON ... }
WORKOUT_EOF
cat /tmp/workout.json | bun /home/peterstorm/dev/claude-plugins/reclaw/scripts/garmin-schedule-workout.ts YYYY-MM-DD
```

Replace `YYYY-MM-DD` with the target date (default: `{{date}}`). Check output for success/failure.

If it fails:
- Auth error → report and stop
- API error → report the error, show the JSON so the user can debug

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

## Iteration

If the user reports issues (wrong sport type, missing exercise names, display problems), adjust and reschedule. The Garmin exercise name catalog is reverse-engineered — some names may not match. When an exercise name is rejected or shows "—", try `null` for that field and note the finding for future reference.
