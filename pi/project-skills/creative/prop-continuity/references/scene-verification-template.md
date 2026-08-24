# Scene Verification Template

Complete this report only after opening the extracted full-frame sheet, prop-crop sheet, and proof frames.

```markdown
# Scene [ID] semantic verification

## Planned beat

- Dramatic job:
- Start state:
- Primary action:
- End state:
- Forbidden actions:
- Transition window:
- Maximum action occupancy:

## Evidence

- Source clip:
- Decode/probe result:
- Full-frame contact sheet:
- Prop-crop contact sheet:
- Start proof frame/time:
- Transition proof frame/time:
- End proof frame/time:
- Consequence proof frame/time:
- Dense transition extraction, if required:

## Sample labels

| Time / frame | Visible prop state | Visible action | Scale ratio | Orientation | Receptacle/contact | Notes |
|---|---|---|---:|---|---|---|
| 0% | | | | | | |
| 12.5% | | | | | | |
| 25% | | | | | | |
| 37.5% | | | | | | |
| 50% | | | | | | |
| 62.5% | | | | | | |
| 75% | | | | | | |
| 87.5% | | | | | | |
| final | | | | | | |

## Acceptance matrix

| Invariant | Critical? | Verdict: PASS / REJECT / UNVERIFIABLE | Evidence time/frame | Visible reason |
|---|---:|---|---|---|
| Requested dramatic content | yes | | | |
| Primary action identity | yes | | | |
| Action occupancy | yes | | | |
| Legal state order | yes | | | |
| Prop count | yes | | | |
| Canonical prop design | yes | | | |
| Scale tolerance | yes | | | |
| Working-end orientation | yes | | | |
| Receptacle exists before contact | yes | | | |
| Compatible engagement | yes | | | |
| Contact physics and pivot | yes | | | |
| Character intent/reaction | yes | | | |
| World and axis continuity | yes | | | |
| Visible narrative consequence | yes | | | |
| Cosmetic quality | no | | | |

## Occupancy calculation

- Samples showing planned primary action:
- Samples showing setup/insertion:
- Samples showing forbidden or repeated action:
- Approximate setup occupancy:
- Within planned limit: yes / no

## Verdict

- Overall: ACCEPT / REJECT
- Failed critical invariants:
- Unverifiable critical invariants:
- Repair action:
- Next-scene handoff state:
```

## Rules

- Cite visible evidence, not prompt language.
- `UNVERIFIABLE` on a critical row makes the overall verdict `REJECT`.
- If a defect occurs between sparse samples, add dense samples and update the table.
- Do not downgrade a critical invariant to cosmetic to save a render.
