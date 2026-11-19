# switch-primary runbook — the desktop's primary-model switcher (2026-11-19)

`switch-primary.sh` decides and sequences which of the four primaries serves :8000. It holds no
engine logic: a pure decision (`primary_decide`), the shared idle gate, and each engine's own
launcher with its gates, acceptance and rollback. Run from any machine — off desktop it re-runs
itself there over ssh.

```bash
~/.dotfiles/scripts/inference/switch-primary.sh [toggle|glm|uncensored|warmind|deepseek|status]
```

## The primaries

`glm` and `uncensored` are the Hyperflare engine's two variants (one switcher, `VARIANT` decides;
see [ds41-1017-native runbook](ds41-1017-native-runbook-2026-11-19.md) for the ds4-native side and
the v16 runbook for Hyperflare). `warmind` and `deepseek` are the ds4-native launcher's two
WEIGHTS. Served ids:

| primary | served id |
|---|---|
| glm | `glm-5.3-flash-hyperflare-tp2-v16` |
| uncensored | `glm-5.3-flash-hyperflare-tp2-uncensored` |
| warmind | `warmind-1017-native` |
| deepseek | `deepseek-v4.1-flash-native` |

## The decision (`primary_decide`, pure, unit-tested)

- `toggle` **stays on the engine that serves and flips stock ↔ uncensored** (`counterpart_of`;
  operator choice, 2026-11-19). The pairs are an involution, so two toggles return where they began:
  - glm ↔ **uncensored** (Hyperflare; the GLM switcher swaps the variant)
  - deepseek ↔ **warmind** (ds4-native; stop, wait for the GPUs, relaunch with the other WEIGHTS)
  - crossing engines is always a named request (`… glm`, `… warmind`, …)
  - nothing active → bring back whichever primary stopped **last** (from the containers'
    `FinishedAt`, a ds41 stop counting as the weights it last served); with no history, error.
- Named requests: `noop:<p>` when already active, else `start:<p>`.
- Error states (fail closed): more than one primary running; an unrecognised container holding a
  GPU; unknown request. Container inspection failures abort rather than guess.

## The sequence

1. **Read active** from the containers themselves (labels, not memory).
2. Hyperflare targets: the GLM switcher does everything itself (its own idle gate, quiesce,
   acceptance, rollback). `VARIANT` is always passed explicitly so an inherited value cannot pick
   the wrong profile.
3. ds41 targets: require the **idle endpoint** first (only when something is running), stop the
   active primary, then wait for both GPUs ≤1024 MiB (`GPU_FREE_TIMEOUT_SECONDS`, 90 s default,
   numeric `nvidia-smi` readings only — a failed reading keeps polling rather than comparing
   empty as 0), then launch.
4. **Rollback:** if the GPU wait or the start fails, the previous primary is restored with its own
   launcher; if that fails too, nothing serves and the error says so.
5. **Report:** `PRIMARY: <p> (<served id> on :8000)` + the matching `pi --model desktop-vllm/<id>`
   line — pi's `/switch` parses exactly this. Both engines answer any model id, so a session
   pinned to the previous id keeps working with that entry's limits until its next turn.

## Operations

- `status` — what serves now and what a toggle would do; harmless anywhere.
- A cutover needs :8000 idle; long-running agent turns are the thing to wait out (the idle gate
  blocks, it does not kill).
- After a switch, the new primary's container is `restart=unless-stopped` (each launcher promotes
  only after acceptance) — it comes back with Docker at boot until stopped by name.
- The unit test (`tests/switch-primary-unit.sh`) stubs the effects and pins `primary_decide`'s
  full input→output table; change the toggle matrix there first, then the script.
- The toggle pairs (`counterpart_of`) are an operator choice recorded in the script; changing them
  is a runbook+script+test same-commit change.

## History

- 2026-11-14: four primaries established (native engine replaces the Maya EXL3 profile as the
  ds41 side; Hyperflare v16 replaces the vLLM exl3 line on the GLM side).
- 2026-11-15: `uncensored` variant added to the Hyperflare switcher (dealignai build converted to
  v16 storage).
- 2026-11-16: warmind→uncensored toggle edge fixed (operator choice).
- 2026-11-19: toggle no longer crosses engines: it flips each model between its stock release and
  its uncensored build (glm ↔ uncensored, deepseek ↔ warmind). `GLM_TOGGLE_TARGET` and
  `primary_decide`'s fourth argument removed (operator choice).
