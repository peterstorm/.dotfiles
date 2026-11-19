# Cortex pipeline benchmark (B1)

Can a local model run cortex's background memory jobs as well as the cloud model
that runs them today? The benchmark replays real recorded cortex calls through a
candidate model (an **arm**), and scores each answer against the answer production
actually got (the **reference**).

| Job | What cortex asks | Production call |
|---|---|---|
| relate | classify the relation of each memory pair in a batch | `classifyEdges`, strict schema, 4096 tokens, 90 s |
| prune | choose memories to archive | `requestPruneCandidates`, candidates schema, 60 s |
| extract | turn a transcript into memories | `extractMemories`, JSON mode, 8192 tokens, 90 s |

Background and the decision it feeds:
`homelab/ai-workstation/planning/local-model-benchmark-coverage` in the vault (B1).

## How it works

1. **corpus**: scans the Claude Code session store for cortex's background calls.
   In each session, the first user message is the prompt and the last assistant
   message is the reference answer. `<synthetic>` replies (failed API calls) are
   recorded as reference failures.
2. **protocol**: draws a seeded, stratified sample (week × prompt-size tertile,
   deduplicated by prompt) and writes it to `protocols/<name>.json`. A protocol holds
   only session ids and prompt hashes, and its id is a hash of its cases.
3. **run**: asks one arm every case. Relate and prune prompts are parsed back into
   their inputs and rebuilt with **today's** cortex prompt builders (the templates
   changed while the corpus was recorded). Extract prompts are replayed verbatim.
   Each answer is appended to `responses/<protocol>/<arm>.jsonl`, so a stopped run
   resumes where it left off.
4. **report**: grades every arm with cortex's own parsers and guards, then writes
   `report.md` and `flagged.md` (disagreements for hand adjudication).

Cortex is loaded from a checkout (`--cortex`, or `CORTEX_ROOT` for tests) through an
anti-corruption layer (`src/infra/cortex.ts`). The prompt, schema, token budget and
parser are production's own, not copies. A vocabulary drift check fails the run if
cortex's edge relations or memory types change from the ones the benchmark knows.

### What is scored

- **Reliability** (all jobs): the usable-answer rate with a Wilson interval, failures
  by class (timeout, truncated, reasoning-only, unparseable, corrupt, …), latency
  and output tokens at p50/p95. An answer is *usable* only if cortex's parser accepts
  it. Relate answers that cross pair ids, or name a pair not in the batch, are
  corrupt, exactly as in production.
- **relate**: Cohen's κ over 8 classes (no edge + 7 relations) and over edge / no
  edge, with a cluster bootstrap CI over batches. Also: same relation, and same
  strength band.
- **prune**: decisions after cortex's code guards (pinned, stable and too-young
  memories are never archived). κ over archive/keep, plus precision, recall and F1
  of the archive set. *Guarded* counts the forbidden memories the arm named anyway,
  which measures instruction-following.
- **extract**: soft one-to-one matching on word overlap (Jaccard ≥ 0.2), giving soft
  recall, soft precision and same type. This is a direction signal only; read
  `flagged.md` for substance.

### The gate is relative

The same memory pair often appears in two batches, so the reference's agreement
**with itself** can be measured. On the first corpus, Haiku agreed with itself at
κ 0.60 [0.55–0.64] (82.4% exact, 1142 repeated pairs). A fixed κ ≥ 0.7 bar would be
above the reference's own ceiling, so the proposed gate asks an arm to reach the
lower bound of that self-agreement interval. The other proposed checks: usable
answers ≥ 99% on every job, and extraction p95 ≤ 30 s (cortex FR-009). Agreement is
not accuracy: `flagged.md` is where "wrong" is told apart from "different".

## Usage

```bash
bun install
bun src/cli.ts corpus                                   # scan sessions → corpus.jsonl
bun src/cli.ts protocol --name v1                       # 300 relate / 100 prune / 50 extract
bun src/cli.ts run --protocol protocols/v1.json --arm direct:desktop-vllm/<model>
bun src/cli.ts run --protocol protocols/v1.json --arm claude:haiku --limit 6   # pilot: 6 per job
bun src/cli.ts report --protocol protocols/v1.json
```

Arm specs:

- `direct:<provider>/<model>`: cortex's own OpenAI-compatible client, the
  transport production uses for a local model. `<provider>` is the
  `CORTEX_LLM_PROVIDER` that cortex resolves to an endpoint. Thinking is disabled,
  and the job's JSON schema is sent as `response_format`.
- `direct:<provider>/<model>+unguided`: the same, without the schema. Use it to see
  how much guided decoding is doing.
- `claude:<model>` and `pi:<provider>/<model>`: the subprocess transport
  (`claude -p` / `pi -p`). This **spends subscription or Copilot quota**.

Production's fallback (the direct call falling back to the CLI) is deliberately not
used. An arm is measured on its own.

CLI arms run in `<data>/cli-sessions`. Their sessions land in a project directory
whose name contains `bench-cortex-pipeline-cli-sessions`, and `corpus` skips that
directory, so the benchmark never grades its own output.

Data lives outside git in `~/.local/share/bench/cortex-pipeline/` (`--data`): the
corpus, responses and reports all contain personal memories. Only `protocols/` is
committed.

The default `--cortex` is the installed plugin. Until cortex's
`feat/background-job-transport` branch is merged, point `--cortex` at a checkout of
that branch: the benchmark needs `requestPruneCandidates` and the transport
parameter on `extractMemories`.

## Tests

```bash
CORTEX_ROOT=<cortex checkout with the transport seam> bun test
bunx tsc --noEmit
```

The core (`src/domain/`) is pure and tested directly, including property tests that
parse cortex-built prompts back into their inputs. `src/infra/transport.test.ts`
drives the direct arm against a fake OpenAI-compatible server, to check the exact
wire request a local model would receive.

## First findings (protocol v1-d58d7d36be4b, 2026-11-19)

Health of the reference, measured with cortex's own parsers:

| Job | Reference failed | Reference unusable |
|---|---|---|
| relate | 2 calls | 657 / 14,650 pairs (4.5%) |
| prune | 37 / 192 | 3 / 155 |
| extract | 53 / 439 | 62 / 386 (16.1%), mostly invalid entity types |

A Haiku 5.5 pilot through the CLI (6 cases per job) was usable on every case:

- **relate**: κ 0.16 over 60 pairs. The CI is too wide to read.
- **prune**: κ 0.78, F1 0.79.
- **extract**: soft recall 59%, soft precision 34%, p95 36 s. That p95 fails the
  30 s bar, though the time includes CLI overhead.

No local arm has been run yet.
