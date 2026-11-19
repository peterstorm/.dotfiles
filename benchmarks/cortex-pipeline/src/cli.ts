// Shell: wires files, cortex and arms to the pure core. See README.md.

import { mkdir, readdir } from 'node:fs/promises';
import { join } from 'node:path';
import { type Command, USAGE, parseCommand } from './cli-args.ts';
import { armSlug, parseArm } from './domain/arm.ts';
import { type CaseInput, type Ineligible, type Readers, caseInput, sizeOf } from './domain/case-input.ts';
import { type LabelledBatch, repeatedPairLabels } from './domain/consistency.ts';
import { type ArmFlags, flagsOf, renderFlagged } from './domain/flagged.ts';
import { type CaseGrade, gradeCase } from './domain/grade.ts';
import { JOBS, type Job, type RecordedCall, type SessionId, assertNever } from './domain/model.ts';
import { type Candidate, selectCases, spread } from './domain/protocol.ts';
import { type ArmReport, type JobHealth, renderReport } from './domain/report.ts';
import { summariseArm } from './domain/summary.ts';
import { type CortexModule, cortexJobs, loadCortex, vocabularyDrift } from './infra/cortex.ts';
import { cortexCommit } from './infra/git.ts';
import { scanRecordedCalls } from './infra/sessions.ts';
import {
  type StoredResponse,
  appendResponse,
  protocolId,
  readCorpus,
  readProtocol,
  readResponses,
  responsesPath,
  sha256,
  writeCorpus,
  writeProtocol,
} from './infra/store.ts';
import { armTransport } from './infra/transport.ts';
import { runArm } from './orchestrator/run-arm.ts';

const say = (line: string): void => {
  process.stdout.write(`${line}\n`);
};

class Fatal extends Error {}

const corpusPath = (data: string): string => join(data, 'corpus.jsonl');

const requireCortex = async (root: string): Promise<CortexModule> => {
  const loaded = await loadCortex(root);
  if (!loaded.ok) {
    throw new Fatal(
      `cortex at ${root} lacks ${loaded.error.names.join(', ')}; it predates the transport seam on every job ` +
        '(cortex "llm: drive every background job through the transport seam") — point --cortex at a checkout that has it',
    );
  }
  const drift = vocabularyDrift(loaded.value);
  if (drift.length > 0) throw new Fatal(`cortex's ${drift.join(' and ')} differ from src/domain/model.ts; update the mirror first`);
  return loaded.value;
};

type Classified = Readonly<{ call: RecordedCall; input: ReturnType<typeof caseInput> }>;

const classifyCorpus = (calls: readonly RecordedCall[], readers: Readers): readonly Classified[] =>
  calls.map((call) => ({ call, input: caseInput(call, readers) }));

const health = (classified: readonly Classified[]): Readonly<Record<Job, JobHealth>> => {
  const empty = (): { calls: number; referenceFailed: number; promptUnparseable: number; referenceUnusable: number; eligible: number; referenceModels: Map<string, number> } => ({
    calls: 0,
    referenceFailed: 0,
    promptUnparseable: 0,
    referenceUnusable: 0,
    eligible: 0,
    referenceModels: new Map(),
  });
  const out = { relate: empty(), prune: empty(), extract: empty() };
  for (const { call, input } of classified) {
    const h = out[call.job];
    h.calls += 1;
    if (call.reference.kind === 'answered') {
      h.referenceModels.set(call.reference.model, (h.referenceModels.get(call.reference.model) ?? 0) + 1);
    }
    if (input.ok) {
      h.eligible += 1;
      continue;
    }
    const why: Ineligible = input.error;
    switch (why.kind) {
      case 'reference-failed':
        h.referenceFailed += 1;
        break;
      case 'prompt-unparseable':
        h.promptUnparseable += 1;
        break;
      case 'reference-unusable':
        h.referenceUnusable += 1;
        break;
      default:
        assertNever(why);
    }
  }
  return out;
};

const corpus = async (cmd: Extract<Command, { kind: 'corpus' }>): Promise<void> => {
  say(`scanning ${cmd.projects} …`);
  const { calls, tally } = await scanRecordedCalls(cmd.projects);
  const sorted = [...calls].sort((a, b) => +a.at - +b.at || a.session.localeCompare(b.session));
  const digest = await writeCorpus(corpusPath(cmd.data), sorted);
  say(`${tally.files} session files: ${tally.calls} cortex calls, ${tally.noAnswer} without an answer, ${tally.badTimestamp} unreadable`);
  for (const job of JOBS) say(`  ${job}: ${sorted.filter((c) => c.job === job).length}`);
  say(`corpus → ${corpusPath(cmd.data)} (sha256 ${digest.slice(0, 12)})`);
};

const protocol = async (cmd: Extract<Command, { kind: 'protocol' }>): Promise<void> => {
  const cortex = await requireCortex(cmd.cortex);
  const { calls, sha256: corpusSha } = await readCorpus(corpusPath(cmd.data));
  const classified = classifyCorpus(calls, cortexJobs(cortex));
  const candidates: Candidate[] = classified.flatMap(({ call, input }) =>
    input.ok && call.reference.kind === 'answered'
      ? [{ call, promptSha256: sha256(call.prompt), referenceModel: call.reference.model, size: sizeOf(input.value) }]
      : [],
  );
  const cases = selectCases(candidates, cmd.quotas, cmd.seed);
  const commit = await cortexCommit(cmd.cortex);
  await writeProtocol(cmd.out, {
    name: cmd.name,
    id: protocolId(cmd.name, cases),
    seed: cmd.seed,
    quotas: cmd.quotas,
    corpus: { calls: calls.length, sha256: corpusSha },
    cortexCommit: commit,
    cases,
  });
  const h = health(classified);
  for (const job of JOBS) {
    const j = h[job];
    say(`${job}: ${j.calls} calls, ${j.eligible} eligible (reference failed ${j.referenceFailed}, unusable ${j.referenceUnusable}, prompt unparseable ${j.promptUnparseable}) → ${cases.filter((c) => c.job === job).length} cases`);
  }
  say(`protocol ${protocolId(cmd.name, cases)} → ${cmd.out}`);
};

/** The protocol's cases with their inputs, checked against the corpus they were drawn from. */
const loadCases = async (protocolFile: string, data: string, readers: Readers) => {
  const p = await readProtocol(protocolFile);
  const { calls } = await readCorpus(corpusPath(data));
  const bySession = new Map(calls.map((c) => [c.session, c]));
  const cases = p.cases.map((c) => {
    const call = bySession.get(c.session);
    if (call === undefined) throw new Fatal(`case ${c.session} is not in the corpus; rebuild the corpus from the same session store`);
    if (sha256(call.prompt) !== c.promptSha256) throw new Fatal(`case ${c.session}: the corpus prompt differs from the protocol's`);
    const input = caseInput(call, readers);
    if (!input.ok) throw new Fatal(`case ${c.session} is no longer eligible: ${input.error.kind}`);
    return { session: c.session, call, input: input.value };
  });
  return { protocol: p, calls, cases };
};

const run = async (cmd: Extract<Command, { kind: 'run' }>): Promise<void> => {
  const arm = parseArm(cmd.arm);
  if (!arm.ok) throw new Fatal(`bad --arm '${cmd.arm}': expected ${arm.error.expected}`);
  const cortex = await requireCortex(cmd.cortex);
  const jobs = cortexJobs(cortex);
  const transport = armTransport(arm.value, cortex);
  if (!transport.ok) throw new Fatal(`no OpenAI-compatible endpoint for provider '${transport.error.provider}' in ~/.pi/agent/models.json`);
  const commit = await cortexCommit(cmd.cortex);
  const { protocol: p, cases } = await loadCases(cmd.protocol, cmd.data, jobs);
  if (arm.value.kind !== 'direct') {
    // `claude -p` / `pi -p` record a session in their working directory's project;
    // keep the benchmark's own calls out of the session store the corpus is read from.
    const cwd = join(cmd.data, 'cli-sessions');
    await mkdir(cwd, { recursive: true });
    process.chdir(cwd);
  }
  const file = responsesPath(cmd.data, p.id, armSlug(arm.value));
  const done = new Set((await readResponses(file)).map((r) => r.session));
  const pending = cmd.jobs.flatMap((job) => {
    const open = cases.filter((c) => c.input.job === job && !done.has(c.session));
    return cmd.limit === null ? open : spread(open, cmd.limit);
  });
  say(`${arm.value.id} on ${p.id}: ${pending.length} cases to ask (${done.size} already answered), cortex ${commit}`);
  const tally = await runArm(
    pending.map((c) => ({ session: c.session, input: c.input })),
    {
      jobs,
      transport: transport.value,
      save: (session, job, exchange) => appendResponse(file, { session, job, ranAt: new Date(), cortexCommit: commit, exchange }),
      progress: say,
    },
    cmd.concurrency,
  );
  say(`asked ${tally.asked}: ${tally.answered} answered, ${tally.failed} failed → ${file}`);
};

const latestBySession = (responses: readonly StoredResponse[]): ReadonlyMap<SessionId, StoredResponse> =>
  new Map(responses.map((r) => [r.session, r]));

const report = async (cmd: Extract<Command, { kind: 'report' }>): Promise<void> => {
  const cortex = await requireCortex(cmd.cortex);
  const readers = cortexJobs(cortex);
  const { protocol: p, calls, cases } = await loadCases(cmd.protocol, cmd.data, readers);
  const classified = classifyCorpus(calls, readers);

  const relateBatches: LabelledBatch[] = classified.flatMap(({ call, input }) =>
    input.ok && input.value.job === 'relate'
      ? [{ session: call.session, at: call.at, pairs: input.value.pairs, labels: input.value.reference }]
      : [],
  );

  const dir = join(cmd.data, 'responses', p.id);
  const files = await readdir(dir).catch(() => [] as string[]);
  const slugs = files.filter((f) => f.endsWith('.jsonl')).map((f) => f.slice(0, -'.jsonl'.length));
  const wanted = cmd.arms === null ? null : new Set(cmd.arms);
  const arms: ArmReport[] = [];
  const flags: ArmFlags[] = [];
  for (const slug of slugs.sort()) {
    const id = decodeURIComponent(slug);
    if (wanted !== null && !wanted.has(id)) continue;
    const responses = latestBySession(await readResponses(join(dir, `${slug}.jsonl`)));
    const graded = cases.flatMap((c) => {
      const r = responses.get(c.session);
      return r === undefined ? [] : [{ input: c.input, grade: gradeCase(c.session, c.input, r, readers) }];
    });
    const grades: CaseGrade[] = graded.map((g) => g.grade);
    const caseFlags = graded.map((g) => flagsOf(g.input, g.grade));
    flags.push({ arm: id, relate: caseFlags.flatMap((f) => f.relate), extract: caseFlags.flatMap((f) => f.extract) });
    const answered = [...responses.values()];
    arms.push({
      arm: id,
      summary: summariseArm(grades),
      cortexCommits: [...new Set(answered.map((r) => r.cortexCommit))],
      servedModels: [
        ...new Set(answered.flatMap((r) => (r.outcome.kind === 'answered' && r.outcome.meta.servedModel !== null ? [r.outcome.meta.servedModel] : []))),
      ],
    });
  }

  const count = (job: Job) => cases.filter((c: { input: CaseInput }) => c.input.job === job).length;
  const generatedAt = new Date();
  const markdown = renderReport({
    protocolId: p.id,
    cases: { relate: count('relate'), prune: count('prune'), extract: count('extract') },
    health: health(classified),
    referenceSelfAgreement: repeatedPairLabels(relateBatches),
    arms,
    generatedAt,
  });
  const out = join(cmd.data, 'reports', p.id, generatedAt.toISOString().replace(/[:.]/g, '-').slice(0, 19));
  await Bun.write(join(out, 'report.md'), markdown);
  await Bun.write(join(out, 'flagged.md'), renderFlagged(p.id, flags));
  say(markdown);
  say(`report → ${join(out, 'report.md')}; disagreements to adjudicate → ${join(out, 'flagged.md')}`);
};

const main = async (): Promise<number> => {
  const parsed = parseCommand(Bun.argv.slice(2), join(import.meta.dir, '..', 'protocols'));
  if (!parsed.ok) {
    process.stderr.write(`${parsed.error.message}\n\n${USAGE}\n`);
    return 2;
  }
  const cmd = parsed.value;
  try {
    switch (cmd.kind) {
      case 'corpus':
        await corpus(cmd);
        break;
      case 'protocol':
        await protocol(cmd);
        break;
      case 'run':
        await run(cmd);
        break;
      case 'report':
        await report(cmd);
        break;
      default:
        assertNever(cmd);
    }
    return 0;
  } catch (e) {
    if (e instanceof Fatal) {
      process.stderr.write(`${e.message}\n`);
      return 1;
    }
    throw e;
  }
};

process.exit(await main());
