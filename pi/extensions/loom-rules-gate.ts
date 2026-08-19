/**
 * Loom Rules Gate
 * ===============
 * Enforces — via `tool_call` interception — that the MAIN ORCHESTRATOR has
 * actually read the Loom rules/skills referenced in CLAUDE.md (into its
 * current context) before it implements code with `write` / `edit` (or
 * bash-based file mutations).
 *
 * Four checks, in order, all bypass-resistant:
 *
 * 1. RULES/SKILLS IN CONTEXT — a `read` tool call whose RESULT (a non-error
 *    toolResult message) is present in the model's current context for the
 *    required file. A read issued in the SAME assistant message as the write
 *    does NOT count — the model generated the code without having seen the
 *    file. For skills, a `<skill name="X">` block in a user message (i.e. the
 *    human ran `/skill:X`) also satisfies the skill requirement.
 * 2. FULL READS ONLY — a read with a `limit:` argument covers only
 *    [offset, offset+limit) lines; coverage across all successful reads of a
 *    file must reach EOF. A `limit: 60` skim of a 400-line rule does not
 *    count. Files larger than the read tool's 2000-line truncation need
 *    explicit `offset` reads; the union of ranges is what matters.
 * 3. TARGET FILE KNOWN — the file being edited must either have been fully
 *    read in context, or been created by a successful `write` earlier in the
 *    session (search-before-write; your own newly written file is already
 *    known).
 * 4. ADHERENCE STATED — before the first gated write of a context window, an
 *    assistant text message must contain a `LOOM: applying <rule|skill> — <how>`
 *    line naming at least one of the required rules/skills. The gate proves
 *    the marker exists; CLAUDE.md makes the substance of it part of the work.
 *    Survives until compaction, exactly like the read evidence — after
 *    compaction it must be stated again.
 *
 * Evidence is taken from `buildContextEntries()`, i.e. what the model can
 * currently see. After compaction, re-reads and a fresh marker are required —
 * intentionally, so the rules are back in context.
 *
 * Main orchestrator vs subagents:
 *   The `subagent` extension spawns subagents as SEPARATE pi processes:
 *   `pi --mode json -p --no-session`. That signature (mode "json" AND no
 *   session file) is detected and exempted. Everything else (tui, rpc,
 *   print, json with a session) is gated. Subagents inherit the rules their
 *   task prompt carries; the orchestrator owns compliance.
 *
 * Escape hatches (env):
 *   LOOM_GATE=off          disable the gate entirely
 *   LOOM_GATE_MODES=tui    gate only the listed comma-separated modes
 *                          (overrides the default subagent exemption)
 *
 * Known limits (documented, not silent):
 *   - bash is gated only via path heuristics (redirects, tee, cp, mv,
 *     sed -i, patch, rsync, install targeting a code-extension file).
 *     Exotic mutations (python open("f.ts","w"), git apply) are not gated.
 *   - Extensionless files (server, Makefile, ...) and custom tools
 *     (pi.registerTool) that write files are not gated; write/edit/bash
 *     are the standard mutation paths.
 *   - Full-read coverage assumes the read tool's 2000-line cap. A read that
 *     hits the tool's 50KB byte cap before 2000 lines is treated as reaching
 *     only 2000 lines of coverage — a file whose lines average >25 bytes
 *     could be byte-truncated without the gate noticing. Rule/skill files
 *     are far below that; target files with very long lines are a known
 *     residual gap, not a silent hole.
 *   - The gate proves context and articulation, never genuine adherence.
 *     That is what the marker + human review are for.
 */

import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { existsSync, realpathSync, readdirSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { extname, isAbsolute, join, resolve } from "node:path";

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

const LOOM_RULES_DIR = "/home/peterstorm/dev/claude-plugins/loom/rules";

/** Rules required before ANY code write/edit (CLAUDE.md: "architecture.md always"). */
const ALWAYS_REQUIRED_RULES = ["architecture.md"];

/** Language pattern rule required per target-file extension (CLAUDE.md: "files matching the languages in scope"). */
const EXTENSION_TO_RULE: Record<string, string> = {
	".ts": "typescript-patterns.md",
	".tsx": "typescript-patterns.md",
	".js": "typescript-patterns.md",
	".jsx": "typescript-patterns.md",
	".mjs": "typescript-patterns.md",
	".cjs": "typescript-patterns.md",
	".mts": "typescript-patterns.md",
	".cts": "typescript-patterns.md",
	".java": "java-patterns.md",
	".rs": "rust-patterns.md",
};

/** Extensions considered "implementing code". Non-code files (md, json, ...) are not gated. */
const CODE_EXTENSIONS = new Set([
	...Object.keys(EXTENSION_TO_RULE),
	".kt",
	".scala",
	".py",
	".go",
	".rb",
	".php",
	".c",
	".h",
	".cpp",
	".cc",
	".cxx",
	".hpp",
	".cs",
	".swift",
	".sh",
	".zsh",
	".bash",
	".vue",
	".svelte",
]);

/** Skills (SKILL.md) the orchestrator must have in context before implementing code. */
const REQUIRED_SKILLS = ["deepen", "distill"];

/** Gate bash mutations of code files (heuristic). */
const GATE_BASH = true;

/** The read tool truncates output at this many lines. */
const READ_TOOL_MAX_LINES = 2000;

/** Adherence marker: `LOOM: applying <rule|skill> — <how>` naming a required rule. */
const ADHERENCE_RE = /\bLOOM:\s*applying\b/i;
const RULE_NAME_RE = /\b(architecture|typescript-patterns|java-patterns|rust-patterns|property-testing|deepen|distill)\b/i;

// ---------------------------------------------------------------------------
// Path canonicalization
// ---------------------------------------------------------------------------

// realpath is a filesystem property, not a session property — a module-level
// cache is safe. A filesystem change mid-session (e.g. nix upgrade) can only
// cause one self-healing mismatch (an extra required re-read).
const canonicalCache = new Map<string, string>();

function canonical(p: string, cwd: string): string {
	let q = p;
	if (q.startsWith("~/")) q = join(homedir(), q.slice(2));
	else if (!isAbsolute(q)) q = join(cwd, q);
	const cached = canonicalCache.get(q);
	if (cached !== undefined) return cached;
	let resolved: string;
	try {
		resolved = realpathSync(q);
	} catch {
		resolved = resolve(q);
	}
	canonicalCache.set(q, resolved);
	return resolved;
}

// ---------------------------------------------------------------------------
// Skill SKILL.md discovery
// ---------------------------------------------------------------------------

function discoverSkillFiles(skillName: string, cwd: string): string[] {
	const home = homedir();
	const candidates: string[] = [
		join(home, ".pi", "agent", "skills", skillName, "SKILL.md"),
		join(cwd, ".pi", "skills", skillName, "SKILL.md"),
		join(cwd, ".agents", "skills", skillName, "SKILL.md"),
	];
	const cacheRoot = join(home, ".pi", "agent", "cache", "loom-resources");
	try {
		for (const entry of readdirSync(cacheRoot)) {
			candidates.push(join(cacheRoot, entry, "skills", skillName, "SKILL.md"));
		}
	} catch {
		/* no cache dir — fine */
	}
	const found = new Set<string>();
	for (const c of candidates) {
		if (existsSync(c)) found.add(canonical(c, cwd));
	}
	return [...found];
}

// ---------------------------------------------------------------------------
// Full-read coverage
// ---------------------------------------------------------------------------

/** Line counts are read-only facts; cache them like canonical paths. */
const lineCountCache = new Map<string, number>();

function lineCountFor(p: string): number {
	const cached = lineCountCache.get(p);
	if (cached !== undefined) return cached;
	let lines: number;
	try {
		lines = readFileSync(p, "utf8").split("\n").length;
	} catch {
		// Unreadable file: coverage can never complete, which blocks — correct.
		lines = Number.POSITIVE_INFINITY;
	}
	lineCountCache.set(p, lines);
	return lines;
}

/**
 * True when the merged half-open line intervals [start, end) cover the whole
 * file, i.e. every line 1..lineCount falls inside at least one interval.
 */
function coveredInFull(ranges: Array<[number, number]>, lineCount: number): boolean {
	if (lineCount === Number.POSITIVE_INFINITY) return false;
	if (lineCount <= 0) return true;
	const sorted = [...ranges].sort((a, b) => a[0] - b[0]);
	let cursor = 1;
	for (const [start, end] of sorted) {
		if (start > cursor + 1) return false; // uncovered gap
		cursor = Math.max(cursor, end);
		if (cursor > lineCount) return true;
	}
	return cursor > lineCount;
}

// ---------------------------------------------------------------------------
// Session evidence: what is actually in the model's current context
// ---------------------------------------------------------------------------

interface Requirement {
	/** Absolute canonical paths; ANY one fully-read path satisfies the requirement. */
	paths: string[];
	/** If set and this name appears in a <skill> block in context, requirement is satisfied. */
	skillName?: string;
	/** Target-file requirement: a prior successful write to the path also satisfies it. */
	writable?: boolean;
	why: string;
}

interface Evidence {
	/** Canonical paths whose full contents are covered by successful reads in context. */
	fullyReadPaths: Set<string>;
	/** Canonical paths created by successful writes in context. */
	successfullyWritten: Set<string>;
	invokedSkillNames: Set<string>;
	adherenceStated: boolean;
}

interface ReadCall {
	path: string;
	start: number; // 1-indexed first line
	limit: number; // lines covered (capped at the read tool's truncation)
}

function collectEvidence(entries: SessionEntry[], cwd: string): Evidence {
	const readCalls = new Map<string, ReadCall>();
	const writeCalls = new Map<string, string>();
	const succeededResults = new Set<string>();
	const invokedSkillNames = new Set<string>();
	let adherenceStated = false;
	const skillBlockRe = /<skill name="([^"]+)" location="[^"]*">/g;

	for (const entry of entries) {
		if (entry.type !== "message") continue;
		const msg = entry.message;

		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "toolCall" && part.name === "read") {
					const p = part.arguments?.path ?? part.arguments?.file_path;
					if (typeof p === "string" && p.length > 0) {
						const rawOffset = Number(part.arguments?.offset);
						const rawLimit = Number(part.arguments?.limit);
						// Effective coverage per read is capped by the tool's truncation.
						readCalls.set(part.id, {
							path: canonical(p, cwd),
							start: Math.max(1, Number.isFinite(rawOffset) && rawOffset > 0 ? rawOffset : 1),
							limit: Math.min(READ_TOOL_MAX_LINES, Math.max(1, Number.isFinite(rawLimit) && rawLimit > 0 ? rawLimit : READ_TOOL_MAX_LINES)),
						});
					}
				} else if (part.type === "toolCall" && part.name === "write") {
					const p = part.arguments?.path ?? part.arguments?.file_path;
					if (typeof p === "string" && p.length > 0) {
						writeCalls.set(part.id, canonical(p, cwd));
					}
				} else if (part.type === "text" && typeof part.text === "string") {
					const m = ADHERENCE_RE.exec(part.text);
					if (m && RULE_NAME_RE.test(part.text.slice(m.index, m.index + 300))) {
						adherenceStated = true;
					}
				}
			}
		} else if (msg.role === "toolResult") {
			if (!msg.isError) succeededResults.add(msg.toolCallId);
		} else if (msg.role === "user") {
			const text =
				typeof msg.content === "string"
					? msg.content
					: msg.content
							.map((c) => (c.type === "text" ? c.text : ""))
							.join("\n");
			let m: RegExpExecArray | null;
			skillBlockRe.lastIndex = 0;
			while ((m = skillBlockRe.exec(text)) !== null) invokedSkillNames.add(m[1]);
		}
	}

	// Merge successful reads into per-path line coverage.
	const rangesByPath = new Map<string, Array<[number, number]>>();
	for (const [callId, r] of readCalls) {
		if (!succeededResults.has(callId)) continue; // read must have COMPLETED
		const ranges = rangesByPath.get(r.path) ?? [];
		ranges.push([r.start, r.start + r.limit]);
		rangesByPath.set(r.path, ranges);
	}

	const fullyReadPaths = new Set<string>();
	for (const [p, ranges] of rangesByPath) {
		if (coveredInFull(ranges, lineCountFor(p))) fullyReadPaths.add(p);
	}

	const successfullyWritten = new Set<string>();
	for (const [callId, p] of writeCalls) {
		if (succeededResults.has(callId)) successfullyWritten.add(p);
	}

	return { fullyReadPaths, successfullyWritten, invokedSkillNames, adherenceStated };
}

// ---------------------------------------------------------------------------
// Requirement construction for a target file
// ---------------------------------------------------------------------------

function requirementsFor(targetPath: string, cwd: string): Requirement[] {
	const ext = extname(targetPath).toLowerCase();
	if (!CODE_EXTENSIONS.has(ext)) return []; // non-code files are not gated

	const reqs: Requirement[] = [];

	for (const rule of ALWAYS_REQUIRED_RULES) {
		const p = join(LOOM_RULES_DIR, rule);
		if (existsSync(p)) reqs.push({ paths: [canonical(p, cwd)], why: `rule ${rule} — required for all code (CLAUDE.md)` });
	}
	const langRule = EXTENSION_TO_RULE[ext];
	if (langRule) {
		const p = join(LOOM_RULES_DIR, langRule);
		if (existsSync(p)) reqs.push({ paths: [canonical(p, cwd)], why: `rule ${langRule} — language patterns for ${ext} files` });
	}

	for (const skill of REQUIRED_SKILLS) {
		const paths = discoverSkillFiles(skill, cwd);
		if (paths.length > 0) {
			reqs.push({ paths, skillName: skill, why: `skill "${skill}" — CLAUDE.md: reference Loom skills when implementing code` });
		}
	}

	// Target file must be known: fully read, or written by this session earlier.
	const canonTarget = canonical(targetPath, cwd);
	if (existsSync(canonTarget)) {
		reqs.push({
			paths: [canonTarget],
			writable: true,
			why: `target file in context — the file being edited must have been read in full (or written earlier this session) before it is changed (search before writing)`,
		});
	}

	return reqs;
}

function missingRequirements(reqs: Requirement[], evidence: Evidence): Requirement[] {
	return reqs.filter((r) => {
		if (r.writable && r.paths.some((p) => evidence.successfullyWritten.has(p))) return false;
		if (r.paths.some((p) => evidence.fullyReadPaths.has(p))) return false;
		if (r.skillName && evidence.invokedSkillNames.has(r.skillName)) return false;
		return true;
	});
}

// ---------------------------------------------------------------------------
// Bash mutation heuristics
// ---------------------------------------------------------------------------

const CODE_EXT_ALTERNATION = [...CODE_EXTENSIONS].map((e) => e.slice(1)).join("|");

function bashTargetsCodeFile(command: string): boolean {
	// Redirect whose target is a code file:  > out.ts   >> src/x.ts   2> err.go
	if (new RegExp(`>>?\\s*["']?[^\\s|;&>"'\\u0060]{1,200}?\\.(?:${CODE_EXT_ALTERNATION})\\b`, "i").test(command)) return true;

	// Mutator commands mentioning any code file
	const mentionsCodeFile = new RegExp(`\\b[\\w.$/~@-]+\\.(?:${CODE_EXT_ALTERNATION})\\b`, "i").test(command);
	if (!mentionsCodeFile) return false;
	return (
		/\btee\b/.test(command) ||
		/\bcp\b/.test(command) ||
		/\bmv\b/.test(command) ||
		/\bsed\b[^|;&\n]{0,80}\s-i\b/.test(command) ||
		/\bpatch\b/.test(command) ||
		/\brsync\b/.test(command) ||
		/\binstall\b/.test(command)
	);
}

/** Find the first code-file path token mentioned in a shell command. */
function firstCodeFileToken(command: string): string | null {
	const tokens = command.split(/[\s|&;()<>=]+/);
	for (const raw of tokens) {
		const t = raw.replace(/^["']+|["']+$/g, "").replace(/^[`]+|[`]+$/g, "");
		if (!t) continue;
		if (CODE_EXTENSIONS.has(extname(t).toLowerCase())) return t;
	}
	return null;
}

// ---------------------------------------------------------------------------
// Gate control: who is gated?
// ---------------------------------------------------------------------------

function isGated(ctx: { mode: string; sessionManager: { getSessionFile(): string | undefined } }): boolean {
	if (process.env.LOOM_GATE === "off" || process.env.LOOM_GATE === "0") return false;

	const modeOverride = process.env.LOOM_GATE_MODES?.trim();
	if (modeOverride) {
		const modes = modeOverride.split(",").map((s) => s.trim()).filter(Boolean);
		return modes.includes(ctx.mode);
	}

	// Subagent signature: the subagent extension spawns `pi --mode json -p --no-session`.
	if (ctx.mode === "json" && !ctx.sessionManager.getSessionFile()) return false;
	return true;
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function (pi: ExtensionAPI) {
	pi.on("session_start", (_event, ctx) => {
		if (!ctx.hasUI) return;
		if (process.env.LOOM_GATE === "off" || process.env.LOOM_GATE === "0") {
			ctx.ui.notify("loom-rules-gate: DISABLED (LOOM_GATE=off)", "warning");
			return;
		}
		const rulesOk = ALWAYS_REQUIRED_RULES.every((r) => existsSync(join(LOOM_RULES_DIR, r)));
		if (rulesOk) {
			ctx.ui.notify("loom-rules-gate active: rules/skills must be fully read and stated before code writes", "info");
		} else {
			ctx.ui.notify(`loom-rules-gate WARNING: missing rules in ${LOOM_RULES_DIR}`, "warning");
		}
	});

	const blockForMissing = (missing: Requirement[], action: string): { block: true; reason: string } => ({
		block: true,
		reason:
			`BLOCKED by loom-rules-gate: you are about to ${action}, but the required Loom rules/skills are not in your current context.\n` +
			`Read each of these files with the \`read\` tool, THEN retry the same operation:\n` +
			missing.map((r, i) => `  ${i + 1}. ${r.paths[0]}   (${r.why})`).join("\n") +
			`\nNotes: reads must have completed before this operation (a read in the same message does not count). ` +
			`Partial reads (with a \`limit:\` argument) do NOT count — the file must be covered in full; ` +
			`use \`offset\` reads for files longer than ${READ_TOOL_MAX_LINES} lines. ` +
			`If a skill was already provided via /skill:<name> by the user, it is satisfied. ` +
			`If the target file exists and you have not read it fully, read it first.`,
	});

	const blockForMarker = (action: string): { block: true; reason: string } => ({
		block: true,
		reason:
			`BLOCKED by loom-rules-gate: no adherence marker in context for ${action}.\n` +
			`Before the first gated edit of a session (or after context compaction), state in a short ` +
			`text-only message which rule/skill applies to this change and the specific principle it honors, e.g.:\n` +
			`  LOOM: applying architecture.md — FC/IS: extraction stays pure, Either at the boundary\n` +
			`(must name at least one of: architecture, typescript-patterns, java-patterns, rust-patterns, ` +
			`property-testing, deepen, distill — then retry the edit in the NEXT message so this line is ` +
			`already in context). Stating it once per context window is enough.\n`,
	});

	pi.on("tool_call", async (event, ctx) => {
		if (!isGated(ctx)) return;

		let targetPath: string | null = null;
		let action = "implement code";

		if (isToolCallEventType("write", event) || isToolCallEventType("edit", event)) {
			const p = event.input?.path;
			if (typeof p !== "string" || p.length === 0) return;
			targetPath = p;
			action = event.toolName === "write" ? `write ${p}` : `edit ${p}`;
		} else if (GATE_BASH && isToolCallEventType("bash", event)) {
			const cmd = event.input?.command;
			if (typeof cmd !== "string") return;
			if (!bashTargetsCodeFile(cmd)) return;
			// For bash we gate on the same requirements as a write to the first
			// code file mentioned (falls back to always-rules + skills).
			const mentioned = firstCodeFileToken(cmd);
			targetPath = mentioned ?? "/x/unknown.py";
			action = `mutate code files via bash: ${cmd.length > 120 ? cmd.slice(0, 120) + "…" : cmd}`;
		} else {
			return;
		}

		const reqs = requirementsFor(targetPath, ctx.cwd);

		if (reqs.length === 0) return;

		const evidence = collectEvidence(ctx.sessionManager.buildContextEntries(), ctx.cwd);
		const missing = missingRequirements(reqs, evidence);
		if (missing.length > 0) return blockForMissing(missing, action);
		if (!evidence.adherenceStated) return blockForMarker(action);
	});
}
