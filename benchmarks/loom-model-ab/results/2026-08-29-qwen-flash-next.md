# Qwen3.8 Flash-Next FP8 planning result — 2026-08-29

## Identity

- Arm: `qwen-flash-next`
- Selector: `desktop-vllm/qwen3.8-flash-next-fp8:xhigh`
- Served model: `qwen3.8-flash-next-fp8`
- Profile: `qwen38-flash-next-fp8-vllm-v1`
- Context: 262,144
- Loom baseline: `3815f65bfab4351f49f0e21e7b7415cdab1fda86`
- Protocol: retired `v1`
- Protocol SHA-256: `17908b755b8a9a7a1fda554c62fcb2a6379a1bb8dd606333ec74154be2756dd3`

> **Historical-score caveat:** v1's visible brief required the shipped Pi
> `extension_ui_request` envelope while its hidden reference expected a
> synthetic direct-method grammar. This report preserves the original blind
> score, but it is not evidence of current Loom contract fidelity. New runs use
> protocol v2 and are not numerically comparable.

## Mechanical outcomes

| Run | Outcome | Planning complete | Notes |
|---|---|---:|---|
| `20260829T113325Z-qwen-flash-next-1` | Retained incomplete attempt | No | Reached decompose with zero tasks; exposed the cross-segment rules-gate false positive |
| `20260829T150036Z-qwen-flash-next-2` | Valid terminal boundary | Yes | Two tasks pending at execute/wave 1; five children attested; no implementation or GitHub issue |

Intermediate harness/setup and backend-contamination attempts were voided rather than scored. Before the valid rerun, Flash-Next was cold-restarted after a correctly prompted interactive child generated reasoning for an unrelated request. The valid run then completed without answer drift. Cortex was disabled throughout the run, the frozen artifact remained byte-identical, and every child attested to the exact selector.

The rules-gate root cause was fixed in `.dotfiles` commits `3d19250` and `bdbc20f`: Bash mutation classification is now shell-segment-local, and pure gate support files live outside Pi's root extension discovery path.

## Blind semantic result

Two fresh independent blind graders scored the valid run:

- **58/104**
- **51/104**

Reportable quality range: **51–58/104**. No mean or model-winner claim is reported from one valid run.

Canonical discovery across 25 hidden requirements:

| Artifact | YES | PARTIAL | NO |
|---|---:|---:|---:|
| Specification | 21 | 3 | 1 |
| Plan | 22 | 2 | 1 |
| Task graph | 21 | 3 | 1 |

## Semantic findings

Strongest finding: the reducer transition table correctly specifies duplicate requests, unknown/stale IDs, method and select-range mismatch, cancellation, done, child exit, parent shutdown, progress, and universal closed-state no-op behavior.

The decisive v1 grading finding was that the artifacts planned the shipped Pi
envelope—`extension_ui_request`, `agent_settled`, `title`, and `prefill`—rather
than v1's hidden direct-method grammar. That is now recognized as a benchmark
contract defect, not a current-Loom defect. Protocol v2 makes the shipped raw
wire explicit and retires the hidden `spawn`/`subagent`/`task` wire rule.

Secondary weaknesses:

1. The 57-question interview repeatedly asked matters already fixed by the frozen contract.
2. The plan over-sized a small two-file core at roughly 450 implementation lines plus 750 test lines.
3. Plan alignment found useful secondary implementation traps but declared no gaps and missed the central wire mismatch.
4. A 4 MiB core cap, timeout validation, and several Pi-envelope policies were invented beyond the frozen benchmark contract.

## Interpretation

Within retired v1 only, the valid Flash-Next result is mechanically stronger
than the earlier incomplete attempt and its **51–58/104** range is directionally
above Qwen3.8-27B (**45–47/104**) while overlapping GLM-v6 around **51/104**.
Because the decisive contract dimension was stale, those totals should not be
used to choose an implementation model. A fresh v2 batch is required.

Serving performance is independent and recorded in `benchmarks/vllm-tps/2026-08-29-qwen-flash-next-fp8.md`.
