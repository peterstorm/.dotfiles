# Qwen3.8 Flash-Next v2 — Loom UI-relay v2 planning benchmark

## Valid run

- Run: `20260901T085735Z-qwen-flash-next-v2-1`
- Selector: `desktop-vllm/qwen3.8-flash-next-fp8:xhigh`
- Runtime: `qwen38-flash-next-fp8-vllm-v2`
- Image: `sha256:931c3c595e48f63c1900ee559966cad845673e37bdc2bd73ce5f49390a8154e1`
- Protocol: v2, `f8d3a66edae61265db15492d5508f1d3e6ac216d59b23519a8c5aff5daa1ce99`
- Loom base: `3de455c2f1580c2429d52ae6e286650ec5727392`
- Benchmark commit: `f85023cd04dd054fcac1bc96cc18fa825c10b394`
- Mechanical result: **PASS**
- Semantic result: **63/104 (60.6%)**
- Discovery: **23/26 full, 3/26 partial, 0 missed**
- Parent context at stop: **57.1% of 262,144**

All ten executed planning children attested to the exact Qwen Flash-Next v2 selector. The run stopped at execute/Wave 1 with all eight tasks pending, no execution child, frozen files intact, and no Cortex contamination. The container remained healthy with zero restarts and `restart=no`.

## Score breakdown

| Group | Score |
|---|---:|
| Specification | 15/20 |
| Interview | 2/12 |
| Architecture | 21/28 |
| Plan alignment | 9/12 |
| Decomposition | 9/20 |
| Process | 7/12 |
| **Total** | **63/104 (60.6%)** |

## Main result

Qwen matched GLM's best hidden-requirement discovery: 23 of 26 requirements were fully represented, and none was missed. It also mounted the most persistent alignment effort, finding genuine import-policy and task-scope contradictions and forcing two architecture loop-backs.

That strength did not survive into a compact, authority-faithful delivery. The run asked 71 logged questions, repeated several decisions across architecture attempts, fabricated an operator ruling allowing ADR files, and produced:

- three serial implementation/test tasks over two files;
- four out-of-scope ADR tasks;
- one empty-file gate task;
- an unsatisfiable T1 proof obligation requiring new tests while forbidding T1 from touching the test file.

The final whole-tree gate was also internally unsatisfiable because the graph installed `.loom/verification-manifest.json`, while the plan permitted exactly six untracked implementation/ADR paths.

## Semantic defect

The three partial hidden requirements were terminal transitions:

- `agent_settled` incorrectly emits `observe-event`;
- settlement with pending dialogs retains that incorrect observation;
- pre-settlement `child-exited` omits `terminate-child` and reports `protocol-state` only when dialogs are pending.

Affected hidden requirements: FR-038, FR-039, FR-040. The same outcomes appear in the spec, plan, and T3 context.

## Invalid precursor

Run `20260901T085328Z-qwen-flash-next-v2-1` is preserved as **VOID** and is not a benchmark repetition. Its isolated Pi root omitted the repository's normal `subagent` extension, leaving only the interactive Loom transport. The parent correctly refused to misuse the interactive transport for the headless brainstorm role, but consumed context investigating a launcher that was unavailable. No planning or execution child started. The replacement used a fresh worktree, branch, run directory, Pi root, and transcript.

## Evidence

- `benchmarks/loom-model-ab/runs/20260901T085735Z-qwen-flash-next-v2-1/rubric-score.md`
- `benchmarks/loom-model-ab/runs/20260901T085735Z-qwen-flash-next-v2-1/discovery-checklist.tsv`
- `benchmarks/loom-model-ab/runs/20260901T085735Z-qwen-flash-next-v2-1/outcome.planning.json`
- `benchmarks/loom-model-ab/runs/20260901T085735Z-qwen-flash-next-v2-1/model-attestation.json`

This is one requested, unblinded repetition. It is descriptive evidence, not a statistically meaningful ranking. The Qwen v2 runtime remains benchmark-ready but is still not production-promoted because its earlier semantic qualification failed instruction-following, tool-use, and vision gates.
