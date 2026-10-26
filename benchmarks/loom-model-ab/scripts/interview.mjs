// Deterministic interview answering for the Loom planning benchmark.
//
// The answer key is organised by topic, Loom asks specific questions, and an
// operator matching one to the other by eye drifts both ways: a covered
// question gets the judgement line (ds41-2 Q23/Q24/Q27, ds41-3 Q33), or a
// scripted answer lands on a question it does not fit (ds41-3 Q4's "No."
// to a confirm-the-list question). This module makes the selection
// mechanical where the evidence is mechanical, and loud where it is not.
//
// Pure core (exported) + CLI shell (bottom). Every core function takes text
// and returns data; only `main` touches the filesystem.

import { appendFileSync, existsSync, readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

/** @template T @typedef {{ ok: true, value: T } | { ok: false, error: string }} Result */
const ok = (value) => Object.freeze({ ok: true, value });
const err = (error) => Object.freeze({ ok: false, error });

/**
 * @typedef {{ topic: string, answer: string }} ScriptedAnswer
 * @typedef {{ judgement: string, answers: readonly ScriptedAnswer[] }} AnswerKey
 * @typedef {{ n: number, question: string, answer: string }} Exchange
 * @typedef {{ n: number, severity: "error" | "warn", kind: string, message: string }} Finding
 */

/** Parse the frozen answer key: the judgement line and the scripted table. */
export function parseAnswerKey(markdown) {
  const judgement = /\*"(Use your judgement[^"]*)"\*/.exec(markdown)?.[1];
  if (judgement === undefined) return err("answer key has no judgement line");
  const section = markdown.split(/^## Scripted answers\s*$/m)[1];
  if (section === undefined) return err("answer key has no '## Scripted answers' section");
  const answers = [];
  for (const line of section.split("\n")) {
    const cells = /^\|(.+)\|(.+)\|\s*$/.exec(line);
    if (cells === null) continue;
    const topic = cells[1].trim();
    const answer = cells[2].trim();
    if (topic === "Topic" || /^-+$/.test(topic)) continue;
    answers.push(Object.freeze({ topic, answer }));
  }
  if (answers.length === 0) return err("answer key has no scripted answers");
  const topics = answers.map((a) => a.topic);
  if (new Set(topics).size !== topics.length) return err("answer key repeats a topic");
  const texts = answers.map((a) => a.answer);
  if (new Set(texts).size !== texts.length) return err("two topics share one answer, so an answer cannot name its topic");
  return ok(Object.freeze({ judgement, answers: Object.freeze(answers) }));
}

/** Parse the operator topic map and prove it covers exactly the key's topics. */
export function parseTopicMap(json, key) {
  let raw;
  try {
    raw = JSON.parse(json);
  } catch (e) {
    return err(`topic map is not JSON: ${e.message}`);
  }
  const topics = raw?.topics;
  if (typeof topics !== "object" || topics === null) return err("topic map has no 'topics' object");
  const keyTopics = new Set(key.answers.map((a) => a.topic));
  const mapTopics = new Set(Object.keys(topics));
  const missing = [...keyTopics].filter((t) => !mapTopics.has(t));
  const extra = [...mapTopics].filter((t) => !keyTopics.has(t));
  if (missing.length > 0 || extra.length > 0) {
    return err(`topic map and answer key disagree; missing: [${missing.join(", ")}], unknown: [${extra.join(", ")}]`);
  }
  const phraseList = (value) =>
    Array.isArray(value) && value.every((p) => typeof p === "string" && p.trim() !== "")
      ? Object.freeze(value.map((p) => p.toLowerCase()))
      : null;
  const map = new Map();
  for (const [topic, entry] of Object.entries(topics)) {
    const names = phraseList(entry?.names);
    const hints = phraseList(entry?.hints ?? []);
    if (names === null || names.length === 0) return err(`topic '${topic}' needs a non-empty 'names' list`);
    if (hints === null) return err(`topic '${topic}' has a malformed 'hints' list`);
    map.set(topic, Object.freeze({ names, hints }));
  }
  return ok(map);
}

const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
// A phrase matches as whole words; a trailing hyphen excludes requirement ids
// such as "NFR-001", which name a requirement, not the NFR topic.
const mentions = (text, phrase) =>
  new RegExp(`(?<![a-z0-9])${escapeRegex(phrase)}(?![a-z0-9-])`, "i").test(text);

/** The topics, in answer-key order, for which a text mentions one of `pick(entry)`. */
const topicsMentioned = (text, key, map, pick) =>
  key.answers.map((a) => a.topic).filter((topic) => pick(map.get(topic)).some((phrase) => mentions(text, phrase)));
const names = (entry) => entry.names;
const namesAndHints = (entry) => [...entry.names, ...entry.hints];

/** A question's parenthetical tags, e.g. "(Error-handling philosophy / observability)". */
const tagsOf = (question) => [...question.matchAll(/\(([^()]*)\)/g)].map((m) => m[1]);

/**
 * What the key says about one question: the topics it is filed under (a
 * parenthetical tag names them, which binds the answer) and the topics it
 * merely mentions anywhere (which the operator must rule on).
 */
export function suggest(question, key, map) {
  const named = new Set(tagsOf(question).flatMap((tag) => topicsMentioned(tag, key, map, names)));
  const tagged = key.answers.map((a) => a.topic).filter((topic) => named.has(topic));
  const hinted = topicsMentioned(question, key, map, namesAndHints).filter((t) => !named.has(t));
  return Object.freeze({ tagged: Object.freeze(tagged), hinted: Object.freeze(hinted) });
}

// Approval gates are answered by rule 3 ("approve without commentary"), not
// from the key, so the checker skips them: an exchange under a gate heading,
// or an approval answer to a question about approving or proceeding.
const GATE_HEADING = /\b(gate|checkpoint|approval)\b/i;
const GATE_QUESTION = /\b(approach|approve|approval|proceed|gate|checkpoint)\b/i;
const APPROVAL = /^(approved?|confirm(ed)?|yes)\b/i;
const isGate = (heading, question, answer) =>
  GATE_HEADING.test(heading) || (GATE_QUESTION.test(question) && APPROVAL.test(answer));

/**
 * Parse `interview.md` into question/answer exchanges. Reads the format `log`
 * writes (`**Qn.**` / `**An.**`, optionally `**Qn (note).**`) and the older
 * `**Question:**`/`**Q:**` (optionally `**Q (note):**`) and `**Answer:**`/`**A:**` pairs, numbered in
 * order. Approval gates are dropped.
 */
export function parseInterview(markdown) {
  const exchanges = [];
  const open = [];
  const numbers = new Set();
  let heading = "";
  for (const [index, line] of markdown.split("\n").entries()) {
    const at = `line ${index + 1}`;
    const title = /^#{1,6}\s+(.*)$/.exec(line);
    if (title !== null) {
      heading = title[1];
      continue;
    }
    const numbered = /^\*\*Q(\d+)(?: \([^)]*\))?\.\*\*\s*(.*)$/.exec(line);
    const plain = /^\*\*(?:Question|Q)(?: \([^)]*\))?:\*\*\s*(.*)$/.exec(line);
    if (numbered !== null || plain !== null) {
      const n = numbered !== null ? Number(numbered[1]) : numbers.size + 1;
      if (numbers.has(n)) return err(`${at}: Q${n} appears twice`);
      numbers.add(n);
      open.push({ n, question: (numbered?.[2] ?? plain[1]).trim(), heading });
      continue;
    }
    const answered = /^\*\*A(\d+)\.\*\*\s*(.*)$/.exec(line) ?? /^\*\*(?:Answer|A):\*\*\s*(.*)$/.exec(line);
    if (answered === null) continue;
    const target = answered.length === 3
      ? open.findIndex((q) => q.n === Number(answered[1]))
      : open.length - 1;
    if (target < 0) return err(`${at}: answer has no open question`);
    const [question] = open.splice(target, 1);
    const answer = answered[answered.length - 1].trim();
    if (answer === "") return err(`${at}: Q${question.n} has an empty answer`);
    if (!isGate(question.heading, question.question, answer)) exchanges.push(Object.freeze({ n: question.n, question: question.question, answer }));
  }
  if (open.length > 0) return err(`Q${open[0].n} has no answer`);
  if (exchanges.length === 0) return err("interview log has no question/answer exchanges");
  return ok(Object.freeze(exchanges.sort((x, y) => x.n - y.n)));
}

// A bare "No." / "Yes." reply only fits a yes/no question ("No deadline." is a
// statement, not a reply). Labels such as "Shell boundary:" are stripped
// before reading the question's first word.
const BARE_POLARITY = /^(No|Yes)\.(?:\s|$)/;
const YES_NO_OPENER = /^(should|does|do|is|are|can|will|would|may|must|whether|has|have)\b/i;
const withoutLabels = (question) => question.replace(/^(?:[^:?]{1,40}:\s+)+/, "");

/** An answer with markdown code ticks and spacing normalised away. */
const loose = (text) => text.replace(/`/g, "").replace(/\s+/g, " ").trim();

/** Every finding the log supports, in question order. */
export function checkInterview(exchanges, key, map) {
  const topicOf = new Map(key.answers.map((a) => [a.answer, a.topic]));
  const looseTopicOf = new Map(key.answers.map((a) => [loose(a.answer), a.topic]));
  const findings = [];
  const add = (n, severity, kind, message) => findings.push(Object.freeze({ n, severity, kind, message }));
  for (const { n, question, answer } of exchanges) {
    const { tagged, hinted } = suggest(question, key, map);
    if (answer === key.judgement) {
      if (tagged.length > 0) {
        add(n, "error", "tagged-topic-ignored",
          `the question tags ${tagged.map((t) => `'${t}'`).join(" and ")} but got the judgement line`);
      } else if (hinted.length > 0) {
        add(n, "warn", "possible-coverage",
          `judgement line, but the question mentions ${hinted.map((t) => `'${t}'`).join(", ")}; confirm no topic covers it`);
      }
      continue;
    }
    const topic = topicOf.get(answer) ?? looseTopicOf.get(loose(answer));
    if (topic === undefined) {
      add(n, "error", "improvised", "answer is neither a scripted answer nor the judgement line");
      continue;
    }
    if (!topicOf.has(answer)) {
      add(n, "warn", "not-verbatim", `'${topic}' answer with different formatting (backticks or spacing)`);
    }
    if (tagged.length > 0 && !tagged.includes(topic)) {
      add(n, "warn", "tag-mismatch",
        `answered from '${topic}', but the question tags ${tagged.map((t) => `'${t}'`).join(" and ")}`);
    }
    if (BARE_POLARITY.test(answer) && !YES_NO_OPENER.test(withoutLabels(question))) {
      add(n, "warn", "polarity", `'${BARE_POLARITY.exec(answer)[1]}.' opens the answer to a question that is not yes/no`);
    }
  }
  return Object.freeze(findings);
}

/** The exact answer text for a choice: a 1-based topic index or `judgement`. */
export function answerFor(choice, key) {
  if (choice === "judgement") return ok(key.judgement);
  if (!/^[1-9][0-9]*$/.test(choice)) return err(`choice must be a topic number or 'judgement': ${choice}`);
  const scripted = key.answers[Number(choice) - 1];
  return scripted === undefined ? err(`no topic ${choice}; there are ${key.answers.length}`) : ok(scripted.answer);
}

/** The next question number for a log, continuing its highest Qn. */
export function nextQuestionNumber(markdown) {
  const numbers = [...markdown.matchAll(/^\*\*Q(\d+)\.\*\*/gm)].map((m) => Number(m[1]));
  return numbers.length === 0 ? 1 : Math.max(...numbers) + 1;
}

// ─── CLI shell ─────────────────────────────────────────────────────────────

const USAGE = `usage:
  interview.mjs <answer-key.md> <topics.json> topics
  interview.mjs <answer-key.md> <topics.json> suggest <question>
  interview.mjs <answer-key.md> <topics.json> answer <topic-number|judgement>
  interview.mjs <answer-key.md> <topics.json> log <interview.md> <question> <topic-number|judgement>
  interview.mjs <answer-key.md> <topics.json> check <interview.md>`;

const fail = (message, code = 1) => {
  process.stderr.write(`${message}\n`);
  process.exit(code);
};
const must = (result) => (result.ok ? result.value : fail(result.error));

function main(argv) {
  const [keyPath, mapPath, command, ...rest] = argv;
  if (keyPath === undefined || mapPath === undefined || command === undefined) fail(USAGE, 2);
  const key = must(parseAnswerKey(readFileSync(keyPath, "utf8")));
  const map = must(parseTopicMap(readFileSync(mapPath, "utf8"), key));
  const listing = () => key.answers.map((a, i) => `${String(i + 1).padStart(2)}  ${a.topic}\n    ${a.answer}`).join("\n");

  switch (command) {
    case "topics":
      process.stdout.write(`${listing()}\n judgement\n    ${key.judgement}\n`);
      return;
    case "suggest": {
      const [question] = rest;
      if (question === undefined) fail(USAGE, 2);
      const { tagged, hinted } = suggest(question, key, map);
      const number = (topic) => key.answers.findIndex((a) => a.topic === topic) + 1;
      if (tagged.length > 0) {
        process.stdout.write(`TAGGED: the question names these topics; answer from one of them:\n`);
        for (const t of tagged) process.stdout.write(`  ${number(t)}  ${t}\n`);
      }
      if (hinted.length > 0) {
        process.stdout.write(`HINTED: the question mentions these; use one only if it genuinely covers the question:\n`);
        for (const t of hinted) process.stdout.write(`  ${number(t)}  ${t}\n`);
      }
      if (tagged.length === 0 && hinted.length === 0) {
        process.stdout.write(`NO MATCH: read the full list before choosing 'judgement'.\n`);
      }
      process.stdout.write(`\n${listing()}\n`);
      return;
    }
    case "answer": {
      const [choice] = rest;
      if (choice === undefined) fail(USAGE, 2);
      process.stdout.write(`${must(answerFor(choice, key))}\n`);
      return;
    }
    case "log": {
      const [logPath, question, choice] = rest;
      if (logPath === undefined || question === undefined || choice === undefined) fail(USAGE, 2);
      if (/[\r\n]/.test(question)) fail("question must be one line");
      const answer = must(answerFor(choice, key));
      const { tagged } = suggest(question, key, map);
      if (answer === key.judgement && tagged.length > 0) {
        fail(`refusing: the question tags ${tagged.join(" and ")}; answer from a tagged topic`);
      }
      const existing = existsSync(logPath) ? readFileSync(logPath, "utf8") : "";
      const n = nextQuestionNumber(existing);
      // Each exchange starts after a blank line, whatever the log ended with.
      const trailingNewlines = /\n*$/.exec(existing)[0].length;
      const separator = existing === "" ? "" : "\n".repeat(Math.max(0, 2 - trailingNewlines));
      appendFileSync(logPath, `${separator}**Q${n}.** ${question.trim()}\n\n**A${n}.** ${answer}\n\n`);
      process.stdout.write(`${answer}\n`);
      return;
    }
    case "check": {
      const [logPath] = rest;
      if (logPath === undefined) fail(USAGE, 2);
      const exchanges = must(parseInterview(readFileSync(logPath, "utf8")));
      const findings = checkInterview(exchanges, key, map);
      for (const f of findings) process.stdout.write(`${f.severity.toUpperCase()} Q${f.n} ${f.kind}: ${f.message}\n`);
      const errors = findings.filter((f) => f.severity === "error").length;
      const warnings = findings.length - errors;
      process.stdout.write(`${exchanges.length} exchanges, ${errors} error(s), ${warnings} warning(s)\n`);
      if (errors > 0) process.exit(1);
      return;
    }
    default:
      fail(USAGE, 2);
  }
}

if (process.argv[1] !== undefined && fileURLToPath(import.meta.url) === process.argv[1]) main(process.argv.slice(2));
