# Interview answer key — the operator's script

Loom's specify and architecture phases interview the user. Those answers are an
input to the run, so unscripted answers make two arms two different
experiments. Answer **only** from this sheet.

## Rules for the operator

1. If a question is covered below, give the scripted answer verbatim.
2. If a question is not covered, reply exactly:
   *"Use your judgement and record the decision in the spec."*
   Never improvise a requirement, never hint at an edge case, and never say
   "what about X?" — question quality is one of the things being measured, and
   volunteering a requirement destroys that measurement.
3. At every approval gate (approach gate, plan approval, decompose 4c), approve
   without commentary — unless the artifact is empty or references a file that
   does not exist, which is a run-level failure to be recorded, not corrected.
4. Log every question asked and every answer given to
   `runs/<run-id>/interview.md`. The transcript is graded.
5. If a phase asks the same question twice, answer it twice and note the repeat.

## Scripted answers

| Topic | Answer |
|---|---|
| Codebase constraints | TypeScript, `engine/src/core`, existing Loom conventions. Vitest for tests. Bun as the runtime. |
| Testability bar | Every branch reachable from a unit test with no mocks, no fakes, and no I/O. |
| NFR primary axis | Correctness first, then clarity. Throughput and latency do not matter — this core runs a handful of times per phase. |
| Concurrency and state model | Single-threaded. The reducer is called from one place. Assume no concurrent invocation. |
| Data model and persistence | None. Nothing is persisted; state lives in memory for the life of one child process. |
| Sensitive boundaries | The child process is untrusted input. Treat every frame as hostile until parsed. |
| Tech preference signals | No new dependencies. Standard library and the existing frozen types file only. |
| Observability | None in the core. Effects are returned as values for the shell to act on. |
| Error handling philosophy | Fail closed. Typed error values, never exceptions, for anything a malformed child can cause. |
| Scale and volume | A few dozen frames per session at most. Do not optimise. |
| Backwards compatibility | None required. Nothing depends on this yet except the frozen types. |
| Deadline or effort budget | No deadline. Do it properly. |
| Whether to change the frozen types file | No. It is frozen. Implement against it as declared. |
| Whether to build the process/stdio shell | No. Out of scope for this task. |
| Definition of done | `bunx tsc --noEmit` clean, your own tests pass, no file outside `ui-relay.ts` and its test file modified. |
