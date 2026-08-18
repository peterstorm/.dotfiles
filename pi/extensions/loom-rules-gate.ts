/**
 * Loom Rules Gate
 * ===============
 * Enforces — via `tool_call` interception — that the MAIN ORCHESTRATOR has
 * actually read the Loom rules/skills referenced in CLAUDE.md (into its
 * current context) before it implements code with `write` / `edit` (or
 * bash-based file mutations).
 *
 * How "read" is verified (bypass-resistant):
 *   - A `read` tool call whose RESULT (a non-error toolResult message) is
 *     present in the model's current context for the required file.
 *     A read issued in the SAME assistant message as the write does NOT
 *     count — the model generated the code without having seen the file.
 *   - For skills: a `<skill name="X">` block in a user message (i.e. the
 *     human ran `/skill:X`), in addition to reading the SKILL.md path.
 *   - Evidence is taken from `buildContextEntries()`, i.e. what the model
 *     can currently see. After compaction, re-reads are required —
 *     intentionally, so the rules are back in context.
 *
 * Main orchestrator vs subagents:
 *   The `subagent` extension spawns subagents as SEPARATE pi processes:
 *   `pi --mode json -p --no-session`. That signature (mode "json" AND no
 *   session file) is detected and exempted. Everything else (tui, rpc,
 *   print, json with a session) is gated.
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
 */

import type { ExtensionAPI, SessionEntry } from "@earendil-works/pi-coding-agent";
import { isToolCallEventType } from "@earendil-works/pi-coding-agent";
import { existsSync, realpathSync, readdirSync } from "node:fs";
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
// Session evidence: what is actually in the model's current context
// ---------------------------------------------------------------------------

interface Requirement {
	/** Absolute canonical paths; ANY one read successfully satisfies the requirement. */
	paths: string[];
	/** If set and this name appears in a <skill> block in context, requirement is satisfied. */
	skillName?: string;
	why: string;
}

function collectEvidence(entries: SessionEntry[], cwd: string) {
	const readPathByCallId = new Map<string, string>();
	const failedCallIds = new Set<string>();
	const invokedSkillNames = new Set<string>();
	const skillBlockRe = /<skill name="([^"]+)" location="[^"]*">/g;

	for (const entry of entries) {
		if (entry.type !== "message") continue;
		const msg = entry.message;

		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "toolCall" && part.name === "read") {
					const p = part.arguments?.path ?? part.arguments?.file_path;
					if (typeof p === "string" && p.length > 0) {
						readPathByCallId.set(part.id, canonical(p, cwd));
					}
				}
			}
		} else if (msg.role === "toolResult") {
			if (msg.toolName === "read" && msg.isError) failedCallIds.add(msg.toolCallId);
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

	const successfullyRead = new Set<string>();
	for (const [callId, p] of readPathByCallId) {
		if (!failedCallIds.has(callId)) successfullyRead.add(p);
	}

	return { successfullyRead, invokedSkillNames };
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

	return reqs;
}

function missingRequirements(reqs: Requirement[], evidence: { successfullyRead: Set<string>; invokedSkillNames: Set<string> }): Requirement[] {
	return reqs.filter((r) => {
		if (r.paths.some((p) => evidence.successfullyRead.has(p))) return false;
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
			ctx.ui.notify("loom-rules-gate active: rules/skills must be in context before code writes", "info");
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
			`If a skill was already provided via /skill:<name> by the user, it is satisfied.`,
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
		if (missing.length === 0) return;

		return blockForMissing(missing, action);
	});
}
