/**
 * Subagent Tool - Delegate tasks to specialized agents
 *
 * Spawns a separate `pi` process for each subagent invocation,
 * giving it an isolated context window.
 *
 * Supports three modes:
 *   - Single: { agent: "name", task: "..." }
 *   - Parallel: { tasks: [{ agent: "name", task: "..." }, ...] }
 *   - Chain: { chain: [{ agent: "name", task: "... {previous} ..." }, ...] }
 *
 * Uses JSON mode to capture structured output from subagents.
 */

import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { AgentToolResult } from "@earendil-works/pi-agent-core";
import type { Message } from "@earendil-works/pi-ai";
import { StringEnum } from "@earendil-works/pi-ai";
import {
	type ExtensionAPI,
	getMarkdownTheme,
	type ThemeColor,
	withFileMutationQueue,
} from "@earendil-works/pi-coding-agent";
import { Container, Markdown, Spacer, Text } from "@earendil-works/pi-tui";
import { Type } from "typebox";
import { type AgentConfig, type AgentScope, discoverAgents } from "./agents.js";
import { loadModelRoutingPolicy } from "../model-routing/config.js";
import { servedModelSourceFromRegistry } from "../model-routing/served.js";
import {
	buildRoutingSnapshot,
	parentBinding,
	resolveSubagentRoute,
	type ResolvedSubagentRoute,
	type RoutingAudit,
	type SubagentRoutingSnapshot,
} from "./model-routing.js";
import {
	advertiseSubagentLaunchPort,
	LOOM_EMISSION_BINDING_ENV,
	LOOM_EMISSION_DESCRIPTOR_MARKER,
	LOOM_SUBAGENT_LAUNCH_CHANNEL,
	type EffectiveModel,
	type EmissionRpcDirective,
	type SubagentLaunchEventBus,
	type SubagentLaunchReply,
	type SubagentLaunchResolveRequest,
	type SubagentLaunchSlot,
} from "./loom-launch-port.js";
import { runRpcAgent } from "./rpc-launcher.js";
import { GROUP_KILL_GRACE_MS, killProcessGroup, spawnDetachedOptions } from "./process-group.js";
import {
	MAX_POOL_TASKS,
	type Dispatcher,
	classifyPoolAttempt,
	createDispatcher,
	looksLoomGoverned,
	normalizePoolOption,
	poolConcurrencyFromEnv,
	type PoolEntry,
	type PoolOutcome,
	type PoolSnapshot,
} from "./pool.js";

/** How many tasks one parallel call may name. */
const MAX_PARALLEL_TASKS = 8;
/**
 * How many of them run at once, a separate knob from the task cap. 8 matches the
 * engines on desktop: GLM v16 serves 8 slots; ds4-native runs 4 Lanes and keeps the
 * rest alive in its queue (Loom's Wave gates and review panels issue up to 8).
 */
const MAX_CONCURRENCY = 8;
const COLLAPSED_ITEM_COUNT = 10;

function formatTokens(count: number): string {
	if (count < 1000) return count.toString();
	if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
	if (count < 1000000) return `${Math.round(count / 1000)}k`;
	return `${(count / 1000000).toFixed(1)}M`;
}

function formatUsageStats(
	usage: {
		input: number;
		output: number;
		cacheRead: number;
		cacheWrite: number;
		cost: number;
		contextTokens?: number;
		turns?: number;
	},
	model?: string,
): string {
	const parts: string[] = [];
	if (usage.turns) parts.push(`${usage.turns} turn${usage.turns > 1 ? "s" : ""}`);
	if (usage.input) parts.push(`↑${formatTokens(usage.input)}`);
	if (usage.output) parts.push(`↓${formatTokens(usage.output)}`);
	if (usage.cacheRead) parts.push(`R${formatTokens(usage.cacheRead)}`);
	if (usage.cacheWrite) parts.push(`W${formatTokens(usage.cacheWrite)}`);
	if (usage.cost) parts.push(`$${usage.cost.toFixed(4)}`);
	if (usage.contextTokens && usage.contextTokens > 0) {
		parts.push(`ctx:${formatTokens(usage.contextTokens)}`);
	}
	if (model) parts.push(model);
	return parts.join(" ");
}

const shortenPath = (p: string) => {
	const home = os.homedir();
	return p.startsWith(home) ? `~${p.slice(home.length)}` : p;
};

type ToolCallFormatter = (
	args: Record<string, unknown>,
	themeFg: (color: ThemeColor, text: string) => string,
) => string;

// Total over the open tool-name domain: known tools get a named formatter and
// every other tool falls through to a JSON preview.
const TOOL_CALL_FORMATTERS: Record<string, ToolCallFormatter> = {
	bash: (args, themeFg) => {
		const command = (args.command as string) || "...";
		const preview = command.length > 60 ? `${command.slice(0, 60)}...` : command;
		return themeFg("muted", "$ ") + themeFg("toolOutput", preview);
	},
	read: (args, themeFg) => {
		const rawPath = (args.file_path || args.path || "...") as string;
		const filePath = shortenPath(rawPath);
		const offset = args.offset as number | undefined;
		const limit = args.limit as number | undefined;
		let text = themeFg("accent", filePath);
		if (offset !== undefined || limit !== undefined) {
			const startLine = offset ?? 1;
			const endLine = limit !== undefined ? startLine + limit - 1 : "";
			text += themeFg("warning", `:${startLine}${endLine ? `-${endLine}` : ""}`);
		}
		return themeFg("muted", "read ") + text;
	},
	write: (args, themeFg) => {
		const rawPath = (args.file_path || args.path || "...") as string;
		const filePath = shortenPath(rawPath);
		const content = (args.content || "") as string;
		const lines = content.split("\n").length;
		let text = themeFg("muted", "write ") + themeFg("accent", filePath);
		if (lines > 1) text += themeFg("dim", ` (${lines} lines)`);
		return text;
	},
	edit: (args, themeFg) => {
		const rawPath = (args.file_path || args.path || "...") as string;
		return themeFg("muted", "edit ") + themeFg("accent", shortenPath(rawPath));
	},
	ls: (args, themeFg) => {
		const rawPath = (args.path || ".") as string;
		return themeFg("muted", "ls ") + themeFg("accent", shortenPath(rawPath));
	},
	find: (args, themeFg) => {
		const pattern = (args.pattern || "*") as string;
		const rawPath = (args.path || ".") as string;
		return themeFg("muted", "find ") + themeFg("accent", pattern) + themeFg("dim", ` in ${shortenPath(rawPath)}`);
	},
	grep: (args, themeFg) => {
		const pattern = (args.pattern || "") as string;
		const rawPath = (args.path || ".") as string;
		return (
			themeFg("muted", "grep ") +
			themeFg("accent", `/${pattern}/`) +
			themeFg("dim", ` in ${shortenPath(rawPath)}`)
		);
	},
};

function formatUnknownToolCall(
	toolName: string,
	args: Record<string, unknown>,
	themeFg: (color: ThemeColor, text: string) => string,
): string {
	const argsStr = JSON.stringify(args);
	const preview = argsStr.length > 50 ? `${argsStr.slice(0, 50)}...` : argsStr;
	return themeFg("accent", toolName) + themeFg("dim", ` ${preview}`);
}

export function formatToolCall(
	toolName: string,
	args: Record<string, unknown>,
	themeFg: (color: ThemeColor, text: string) => string,
): string {
	// Own keys only: a tool named "constructor" or "toString" must preview as JSON,
	// not resolve to an inherited Object.prototype function.
	return Object.hasOwn(TOOL_CALL_FORMATTERS, toolName)
		? TOOL_CALL_FORMATTERS[toolName](args, themeFg)
		: formatUnknownToolCall(toolName, args, themeFg);
}

interface UsageStats {
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	cost: number;
	contextTokens: number;
	turns: number;
}

export type EmissionStartupRefusedLaunchOutcome = Readonly<{
	kind: "emission-startup-refused";
	sessionId: string;
	toolCallId: string;
	slot: SubagentLaunchSlot;
	requestId: string;
	contextDigest: string;
	toolName: string;
	phase: "before-task-prompt";
	reason: string;
}>;

export interface SingleResult {
	agent: string;
	agentSource: "package" | "user" | "project" | "unknown";
	task: string;
	exitCode: number;
	messages: Message[];
	stderr: string;
	usage: UsageStats;
	model?: string;
	routing?: RoutingAudit;
	stopReason?: string;
	errorMessage?: string;
	protocolErrors?: string[];
	launchOutcome?: EmissionStartupRefusedLaunchOutcome;
	step?: number;
}

export interface SubagentDetails {
	mode: "single" | "parallel" | "chain";
	agentScope: AgentScope;
	projectAgentsDir: string | null;
	routingPolicyDigest?: string;
	results: SingleResult[];
	/** Present on a background pooled call: the dispatcher snapshot at return. */
	pool?: PoolSnapshot;
}

function resultFailed(result: SingleResult): boolean {
	return result.exitCode !== 0 || result.stopReason === "error" || result.stopReason === "aborted";
}

function appendDiagnostic(result: SingleResult, diagnostic: string): void {
	result.stderr += `${result.stderr ? "\n" : ""}${diagnostic}`;
	result.errorMessage ??= diagnostic;
}

function getFinalOutput(messages: Message[]): string {
	for (let i = messages.length - 1; i >= 0; i--) {
		const msg = messages[i];
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text") return part.text;
			}
		}
	}
	return "";
}

type DisplayItem = { type: "text"; text: string } | { type: "toolCall"; name: string; args: Record<string, unknown> };

function getDisplayItems(messages: Message[]): DisplayItem[] {
	const items: DisplayItem[] = [];
	for (const msg of messages) {
		if (msg.role === "assistant") {
			for (const part of msg.content) {
				if (part.type === "text") items.push({ type: "text", text: part.text });
				else if (part.type === "toolCall") items.push({ type: "toolCall", name: part.name, args: part.arguments });
			}
		}
	}
	return items;
}

function addExpandedResultSection(
	container: Container,
	r: SingleResult,
	header: string,
	themeFg: (color: ThemeColor, text: string) => string,
	mdTheme: ReturnType<typeof getMarkdownTheme>,
): void {
	const rIcon = r.exitCode === 0 ? themeFg("success", "✓") : themeFg("error", "✗");
	const displayItems = getDisplayItems(r.messages);
	const finalOutput = getFinalOutput(r.messages);

	container.addChild(new Spacer(1));
	container.addChild(new Text(`${themeFg("muted", header) + themeFg("accent", r.agent)} ${rIcon}`, 0, 0));
	container.addChild(new Text(themeFg("muted", "Task: ") + themeFg("dim", r.task), 0, 0));

	for (const item of displayItems) {
		if (item.type === "toolCall") {
			container.addChild(
				new Text(themeFg("muted", "→ ") + formatToolCall(item.name, item.args, themeFg), 0, 0),
			);
		}
	}

	if (finalOutput) {
		container.addChild(new Spacer(1));
		container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
	}

	const usage = formatUsageStats(r.usage, r.model);
	if (usage) container.addChild(new Text(themeFg("dim", usage), 0, 0));
}

export async function mapWithConcurrencyLimit<TIn, TOut>(
	items: TIn[],
	concurrency: number,
	fn: (item: TIn, index: number) => Promise<TOut>,
): Promise<TOut[]> {
	if (items.length === 0) return [];
	const limit = Math.max(1, Math.min(concurrency, items.length));
	const results: TOut[] = new Array(items.length);
	let nextIndex = 0;
	const workers = new Array(limit).fill(null).map(async () => {
		while (true) {
			const current = nextIndex++;
			if (current >= items.length) return;
			results[current] = await fn(items[current], current);
		}
	});
	await Promise.all(workers);
	return results;
}

async function writePromptToTempFile(agentName: string, prompt: string): Promise<{ dir: string; filePath: string }> {
	const tmpDir = await fs.promises.mkdtemp(path.join(os.tmpdir(), "pi-subagent-"));
	const safeName = agentName.replace(/[^\w.-]+/g, "_");
	const filePath = path.join(tmpDir, `prompt-${safeName}.md`);
	await withFileMutationQueue(filePath, async () => {
		await fs.promises.writeFile(filePath, prompt, { encoding: "utf-8", mode: 0o600 });
	});
	return { dir: tmpDir, filePath };
}

function getPiInvocation(args: string[]): { command: string; args: string[] } {
	const currentScript = process.argv[1];
	const isBunVirtualScript = currentScript?.startsWith("/$bunfs/root/");
	if (currentScript && !isBunVirtualScript && fs.existsSync(currentScript)) {
		return { command: process.execPath, args: [currentScript, ...args] };
	}

	const execName = path.basename(process.execPath).toLowerCase();
	const isGenericRuntime = /^(node|bun)(\.exe)?$/.test(execName);
	if (!isGenericRuntime) {
		return { command: process.execPath, args };
	}

	return { command: "pi", args };
}

type OnUpdateCallback = (partial: AgentToolResult<SubagentDetails>) => void;

type LaunchContext = Readonly<{
	events: SubagentLaunchEventBus;
	sessionId: string;
	toolCallId: string;
	slot: SubagentLaunchSlot;
	readinessTimeoutMs?: number;
}>;

type ParseResult<T> =
	| Readonly<{ ok: true; value: T }>
	| Readonly<{ ok: false; error: string }>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const isReadinessVerifier = (value: unknown): value is EmissionRpcDirective["verifyReadiness"] =>
	typeof value === "function";

const MAX_LAUNCH_OUTCOME_REASON_BYTES = 1024;

function boundedLaunchReason(reason: string): string {
	if (Buffer.byteLength(reason) <= MAX_LAUNCH_OUTCOME_REASON_BYTES) return reason;
	const characters: string[] = [];
	let bytes = 0;
	for (const character of reason) {
		const characterBytes = Buffer.byteLength(character);
		if (bytes + characterBytes > MAX_LAUNCH_OUTCOME_REASON_BYTES) break;
		characters.push(character);
		bytes += characterBytes;
	}
	return characters.join("");
}

const EMISSION_DESCRIPTOR_FIELDS = [
	"toolName",
	"kind",
	"version",
	"requestId",
	"contextDigest",
	"schemaDigest",
] as const;

type EmissionDescriptor = Readonly<Record<(typeof EMISSION_DESCRIPTOR_FIELDS)[number], string>>;

function parseEmissionDescriptor(task: string): ParseResult<EmissionDescriptor | null> {
	const descriptorLines = task
		.split("\n")
		.filter((line) => line.startsWith(LOOM_EMISSION_DESCRIPTOR_MARKER));
	if (descriptorLines.length === 0) return { ok: true, value: null };
	if (descriptorLines.length !== 1) return { ok: false, error: "Task contains multiple Loom emission descriptors" };

	const prefix = `${LOOM_EMISSION_DESCRIPTOR_MARKER} `;
	const line = descriptorLines[0];
	if (!line.startsWith(prefix)) {
		return { ok: false, error: "Loom emission descriptor must have one space after its marker" };
	}
	const fields = line.slice(prefix.length).split(" ");
	if (
		fields.length !== EMISSION_DESCRIPTOR_FIELDS.length ||
		fields.some((field) => field.length === 0 || /\s/.test(field))
	) {
		return {
			ok: false,
			error: "Loom emission descriptor must contain exactly six whitespace-free fields",
		};
	}
	const [toolName, kind, version, requestId, contextDigest, schemaDigest] = fields;
	return {
		ok: true,
		value: Object.freeze({ toolName, kind, version, requestId, contextDigest, schemaDigest }),
	};
}

function parseExactModelExpression(raw: string | undefined): EffectiveModel | undefined {
	if (!raw) return undefined;
	const withoutThinking = raw.replace(/:(?:off|minimal|low|medium|high|xhigh|max)$/, "");
	const separator = withoutThinking.indexOf("/");
	if (separator <= 0 || separator === withoutThinking.length - 1 || withoutThinking.includes("*")) return undefined;
	return Object.freeze({ provider: withoutThinking.slice(0, separator), id: withoutThinking.slice(separator + 1) });
}

function effectiveModelForLaunch(
	route: ResolvedSubagentRoute,
	agent: AgentConfig,
	snapshot: SubagentRoutingSnapshot,
): EffectiveModel | undefined {
	const routed = route.decision.effective?.model;
	if (routed) return Object.freeze({ provider: routed.provider, id: routed.id });
	return parseExactModelExpression(agent.model) ?? (snapshot.parent
		? Object.freeze({ provider: snapshot.parent.model.provider, id: snapshot.parent.model.id })
		: undefined);
}

function resolveLaunchReply(
	launch: LaunchContext,
	agent: string,
	task: string,
	cwd: string,
	effectiveModel: EffectiveModel,
): ParseResult<SubagentLaunchReply> {
	let reply: SubagentLaunchReply = Object.freeze({ kind: "not-admitted" });
	let responses = 0;
	let accepting = true;
	const request: SubagentLaunchResolveRequest = Object.freeze({
		kind: "resolve",
		sessionId: launch.sessionId,
		toolCallId: launch.toolCallId,
		slot: launch.slot,
		agent,
		task,
		cwd,
		effectiveModel,
		respond: (next) => {
			if (!accepting || ++responses !== 1) throw new Error("Loom launch port replied late or more than once");
			if (!isRecord(next)) throw new Error("Loom launch port returned a non-object reply");
			if (next.kind === "refused" && typeof next.reason === "string" && next.reason.length > 0) {
				reply = Object.freeze({ kind: "refused", reason: next.reason });
			} else if (next.kind === "emission-rpc") {
				reply = Object.freeze({ kind: "emission-rpc", directive: next.directive });
			} else {
				throw new Error("Loom launch port returned an invalid reply kind or reason");
			}
		},
	});
	try {
		launch.events.emit(LOOM_SUBAGENT_LAUNCH_CHANNEL, request);
	} catch (cause) {
		return { ok: false, error: `Loom launch port failed before spawn: ${boundedLaunchReason(cause instanceof Error ? cause.message : String(cause))}` };
	} finally {
		accepting = false;
	}
	return { ok: true, value: reply };
}

type ParsedEmissionDirective = Readonly<{
	directive: EmissionRpcDirective;
	binding: EmissionDescriptor;
}>;

/** A pooled task's frozen identity, captured once per tool call. */
type PoolTaskPayload = Readonly<{
	agent: string;
	task: string;
	cwd: string | undefined;
	index: number;
	slot: SubagentLaunchSlot;
}>;

function placeholderResult(agent: string, task: string): SingleResult {
	return {
		agent,
		agentSource: "unknown",
		task,
		exitCode: -1, // -1 = still running
		messages: [],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
	};
}

function abortedPoolResult(
	entry: PoolEntry<PoolTaskPayload, SingleResult>,
	outcome: Extract<PoolOutcome<SingleResult>, { kind: "aborted" }>,
): SingleResult {
	const result = placeholderResult(entry.payload.agent, entry.payload.task);
	result.exitCode = 1;
	result.stopReason = "aborted";
	// "before it started" is only true when nothing was ever launched; a mid-run abort must not
	// claim it. A launcher crash carries its own reason so it stays distinguishable from a cancel.
	result.errorMessage = entry.attempts === 0
		? "Pooled subagent was cancelled before it started"
		: outcome.reason ?? "Pooled subagent was cancelled";
	result.stderr = result.errorMessage;
	return result;
}

function singleToolResult(
	result: SingleResult,
	details: SubagentDetails,
): AgentToolResult<SubagentDetails> {
	if (resultFailed(result)) {
		const errorMessage = result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
		return {
			content: [{ type: "text", text: `Agent ${result.stopReason || "failed"}: ${errorMessage}` }],
			details,
			isError: true,
		};
	}
	return { content: [{ type: "text", text: getFinalOutput(result.messages) || "(no output)" }], details };
}

function parallelToolResult(
	results: SingleResult[],
	details: SubagentDetails,
): AgentToolResult<SubagentDetails> {
	const failed = results.filter(resultFailed);
	const aborted = results.filter((result) => result.stopReason === "aborted").length;
	const successCount = results.length - failed.length;
	const sections = results.map((result) => {
		const output = getFinalOutput(result.messages);
		const status = resultFailed(result) ? "failed" : "completed";
		return `## [${result.agent}] ${status}\n\n${output || "(no output)"}`;
	});
	const summaryLine = aborted > 0
		? `Aborted: ${results.length - aborted}/${results.length} completed before abort`
		: `Parallel: ${successCount}/${results.length} succeeded`;
	return {
		content: [{ type: "text", text: `${summaryLine}\n\n${sections.join("\n\n---\n\n")}` }],
		details,
		isError: failed.length > 0,
	};
}

const POOL_NOTICE_MAX_OUTPUT = 4_000;

function describePoolSettle(
	entry: PoolEntry<PoolTaskPayload, SingleResult>,
	outcome: PoolOutcome<SingleResult>,
): string {
	const label = `[${entry.payload.agent}] task ${entry.payload.index + 1}`;
	if (outcome.kind === "aborted") {
		return outcome.reason !== undefined ? `${label}: aborted (${outcome.reason})` : `${label}: aborted`;
	}
	const result = outcome.result;
	const output = getFinalOutput(result.messages).slice(0, POOL_NOTICE_MAX_OUTPUT);
	if (outcome.kind === "completed") return `${label}: completed\n${output || "(no output)"}`;
	const reason = (result.errorMessage || result.stderr || output || "(no output)").slice(0, POOL_NOTICE_MAX_OUTPUT);
	return `${label}: failed (attempt ${entry.attempts}/${entry.maxAttempts})\n${reason}`;
}

function parseBindingEnv(raw: string): ParseResult<EmissionDescriptor> {
	let value: unknown;
	try {
		value = JSON.parse(raw);
	} catch {
		return { ok: false, error: "Loom emission binding is not valid JSON" };
	}
	if (!isRecord(value)) return { ok: false, error: "Loom emission binding must be a JSON object" };

	const fields: string[] = [];
	for (const field of EMISSION_DESCRIPTOR_FIELDS) {
		const candidate = value[field];
		if (typeof candidate !== "string" || candidate.length === 0 || /\s/.test(candidate)) {
			return { ok: false, error: `Loom emission binding ${field} must be a whitespace-free string` };
		}
		fields.push(candidate);
	}
	const [toolName, kind, version, requestId, contextDigest, schemaDigest] = fields;
	return {
		ok: true,
		value: Object.freeze({ toolName, kind, version, requestId, contextDigest, schemaDigest }),
	};
}

function parseDirective(value: unknown): ParseResult<ParsedEmissionDirective> {
	if (!isRecord(value) || value.kind !== "emission-rpc") {
		return { ok: false, error: "Loom launch directive must have kind emission-rpc" };
	}
	const { bindingEnv, expectedProvider, expectedModel, expectedToolName, verifyReadiness } = value;
	const fields = { bindingEnv, expectedProvider, expectedModel, expectedToolName };
	for (const [field, candidate] of Object.entries(fields)) {
		if (typeof candidate !== "string" || candidate.trim() === "") {
			return { ok: false, error: `Loom launch directive ${field} must be a non-empty string` };
		}
	}
	if (
		typeof bindingEnv !== "string" || typeof expectedProvider !== "string" ||
		typeof expectedModel !== "string" || typeof expectedToolName !== "string"
	) {
		return { ok: false, error: "Loom launch directive contains invalid string fields" };
	}
	if (!isReadinessVerifier(verifyReadiness)) {
		return { ok: false, error: "Loom launch directive verifyReadiness must be a function" };
	}
	if (!/^[A-Za-z][A-Za-z0-9_-]{0,127}$/.test(expectedToolName)) {
		return { ok: false, error: "Loom launch directive expectedToolName is not a valid Pi tool name" };
	}
	const parsedBinding = parseBindingEnv(bindingEnv);
	if (!parsedBinding.ok) return parsedBinding;
	if (parsedBinding.value.toolName !== expectedToolName) {
		return { ok: false, error: "Loom emission binding toolName does not match expectedToolName" };
	}
	return {
		ok: true,
		value: Object.freeze({
			directive: Object.freeze({
				kind: "emission-rpc",
				bindingEnv,
				expectedProvider,
				expectedModel,
				expectedToolName,
				verifyReadiness,
			}),
			binding: parsedBinding.value,
		}),
	};
}

function descriptorMismatch(descriptor: EmissionDescriptor, binding: EmissionDescriptor): string | undefined {
	for (const field of EMISSION_DESCRIPTOR_FIELDS) {
		if (descriptor[field] !== binding[field]) {
			return `${field} ${descriptor[field]} does not match provisioned binding ${binding[field]}`;
		}
	}
	return undefined;
}

async function runSingleAgentUnsafe(
	defaultCwd: string,
	agents: readonly AgentConfig[],
	agentName: string,
	task: string,
	cwd: string | undefined,
	step: number | undefined,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
	routingSnapshot: SubagentRoutingSnapshot,
	launch: LaunchContext,
): Promise<SingleResult> {
	const agent = agents.find((a) => a.name === agentName);

	if (!agent) {
		const available = agents.map((a) => `"${a.name}"`).join(", ") || "none";
		return {
			agent: agentName,
			agentSource: "unknown",
			task,
			exitCode: 1,
			messages: [],
			stderr: `Unknown agent: "${agentName}". Available agents: ${available}.`,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
			step,
		};
	}

	const route = resolveSubagentRoute(routingSnapshot, agent);
	if (!route.ok) {
		return {
			agent: agentName,
			agentSource: agent.source,
			task,
			exitCode: 1,
			messages: [],
			stderr: `Model routing failed: ${route.error}`,
			usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
			model: agent.model,
			step,
		};
	}

	let tmpPromptDir: string | null = null;
	let tmpPromptPath: string | null = null;

	const currentResult: SingleResult = {
		agent: agentName,
		agentSource: agent.source,
		task,
		exitCode: 0,
		messages: [],
		stderr: "",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, contextTokens: 0, turns: 0 },
		model: route.value.audit.effective,
		routing: route.value.audit,
		step,
	};

	const emitUpdate = () => {
		if (onUpdate) {
			onUpdate({
				content: [{ type: "text", text: getFinalOutput(currentResult.messages) || "(running...)" }],
				details: makeDetails([currentResult]),
			});
		}
	};

	const recordMessage = (msg: Message): void => {
		currentResult.messages.push(msg);
		if (msg.role === "assistant") {
			currentResult.usage.turns++;
			const usage = msg.usage;
			if (usage) {
				currentResult.usage.input += usage.input || 0;
				currentResult.usage.output += usage.output || 0;
				currentResult.usage.cacheRead += usage.cacheRead || 0;
				currentResult.usage.cacheWrite += usage.cacheWrite || 0;
				currentResult.usage.cost += usage.cost?.total || 0;
				currentResult.usage.contextTokens = usage.totalTokens || 0;
			}
			if (!currentResult.model && msg.model) currentResult.model = msg.model;
			if (msg.stopReason) currentResult.stopReason = msg.stopReason;
			if (msg.errorMessage) currentResult.errorMessage = msg.errorMessage;
		}
		emitUpdate();
	};

	const failBeforeSpawn = (message: string): SingleResult => {
		currentResult.exitCode = 1;
		appendDiagnostic(currentResult, message);
		return currentResult;
	};

	const descriptor = parseEmissionDescriptor(task);
	if (!descriptor.ok) return failBeforeSpawn(descriptor.error);
	const childCwd = path.resolve(defaultCwd, cwd ?? ".");
	const effectiveModel = effectiveModelForLaunch(route.value, agent, routingSnapshot);
	const resolvedReply = effectiveModel
		? resolveLaunchReply(launch, agentName, task, childCwd, effectiveModel)
		: { ok: true as const, value: Object.freeze({ kind: "not-admitted" as const }) };
	if (!resolvedReply.ok) return failBeforeSpawn(resolvedReply.error);
	let reply: SubagentLaunchReply = resolvedReply.value;
	if (descriptor.value && !effectiveModel) {
		return failBeforeSpawn("Loom emission task has no exact routed model");
	}
	if (reply.kind === "refused") {
		return failBeforeSpawn(`Loom subagent launch was refused: ${reply.reason}`);
	}
	if (descriptor.value && reply.kind === "not-admitted") {
		return failBeforeSpawn("Loom emission task was not admitted for emission RPC");
	}
	let emissionLaunchIdentity: EmissionDescriptor | null = null;
	if (reply.kind === "emission-rpc" && effectiveModel) {
		const exactDescriptor = descriptor.value;
		if (!exactDescriptor) {
			return failBeforeSpawn("Loom emission RPC directive was supplied for a task without an emission descriptor");
		}
		const parsedDirective = parseDirective(reply.directive);
		if (!parsedDirective.ok) return failBeforeSpawn(parsedDirective.error);
		const directive = parsedDirective.value.directive;
		if (
			directive.expectedProvider !== effectiveModel.provider ||
			directive.expectedModel !== effectiveModel.id
		) {
			return failBeforeSpawn(
				`Loom emission route ${directive.expectedProvider}/${directive.expectedModel} does not match ` +
				`${effectiveModel.provider}/${effectiveModel.id}`,
			);
		}
		const mismatch = descriptorMismatch(exactDescriptor, parsedDirective.value.binding);
		if (mismatch) return failBeforeSpawn(`Loom emission descriptor mismatch: ${mismatch}`);
		emissionLaunchIdentity = parsedDirective.value.binding;
		reply = Object.freeze({ kind: "emission-rpc", directive });
	}

	// A delegated agent must execute its task directly. Inheriting this extension's
	// subagent tool allows accidental self-delegation loops that spawn nested pi
	// processes until the user aborts. Chaining remains available to the parent.
	const args: string[] = [
		"--mode", reply.kind === "emission-rpc" ? "rpc" : "json",
		...(reply.kind === "emission-rpc" ? [] : ["-p"]),
		"--no-session", "--exclude-tools", "subagent",
		...route.value.args,
	];
	const allowedTools = [
		...(agent.tools ?? []),
		...(reply.kind === "emission-rpc" ? [reply.directive.expectedToolName] : []),
	];
	if (allowedTools.length > 0) args.push("--tools", [...new Set(allowedTools)].join(","));
	const childEnv: NodeJS.ProcessEnv = { ...process.env };
	delete childEnv[LOOM_EMISSION_BINDING_ENV];
	if (reply.kind === "emission-rpc") childEnv[LOOM_EMISSION_BINDING_ENV] = reply.directive.bindingEnv;

	const markAborted = (message: string): void => {
		currentResult.exitCode = 1;
		currentResult.stopReason = "aborted";
		// The abort is the primary cause of a killed child; appendDiagnostic's
		// signal detail remains in stderr for diagnosis.
		currentResult.errorMessage = message;
	};
	const recordEmissionStartupRefusal = (reason: string): void => {
		if (!emissionLaunchIdentity) return;
		currentResult.launchOutcome = Object.freeze({
			kind: "emission-startup-refused",
			sessionId: launch.sessionId,
			toolCallId: launch.toolCallId,
			slot: launch.slot,
			requestId: emissionLaunchIdentity.requestId,
			contextDigest: emissionLaunchIdentity.contextDigest,
			toolName: emissionLaunchIdentity.toolName,
			phase: "before-task-prompt",
			reason: boundedLaunchReason(reason),
		});
	};

	if (signal?.aborted) {
		const reason = "Subagent was aborted before it started";
		recordEmissionStartupRefusal(reason);
		markAborted(reason);
		return currentResult;
	}

	try {
		if (agent.systemPrompt.trim()) {
			const tmp = await writePromptToTempFile(agent.name, agent.systemPrompt);
			tmpPromptDir = tmp.dir;
			tmpPromptPath = tmp.filePath;
			args.push("--append-system-prompt", tmpPromptPath);
		}

		if (reply.kind === "emission-rpc") {
			const invocation = getPiInvocation(args);
			const outcome = await runRpcAgent({
				command: invocation.command,
				args: invocation.args,
				cwd: childCwd,
				env: childEnv,
				task,
				directive: reply.directive,
				signal,
				readinessTimeoutMs: launch.readinessTimeoutMs,
				onMessage: recordMessage,
			});
			currentResult.stderr = outcome.stderr;
			if (outcome.ok) return currentResult;
			currentResult.exitCode = 1;
			if (outcome.protocolErrors) currentResult.protocolErrors = [...outcome.protocolErrors];
			appendDiagnostic(currentResult, outcome.reason);
			if (outcome.phase === "before-task-prompt") recordEmissionStartupRefusal(outcome.reason);
			if (outcome.kind === "aborted") markAborted(outcome.reason);
			return currentResult;
		}

		args.push(`Task: ${task}`);
		let wasAborted = false;
		const exitCode = await new Promise<number>((resolve) => {
			const invocation = getPiInvocation(args);
			const proc = spawn(invocation.command, invocation.args, {
				cwd: childCwd,
				env: childEnv,
				shell: false,
				stdio: ["ignore", "pipe", "pipe"],
				...spawnDetachedOptions(),
			});
			let buffer = "";
			let settled = false;

			const settle = (code: number) => {
				if (settled) return;
				settled = true;
				resolve(code);
			};
			const recordProtocolError = (line: string) => {
				currentResult.protocolErrors ??= [];
				if (currentResult.protocolErrors.length < 3) currentResult.protocolErrors.push(line.slice(0, 500));
			};
			const processLine = (line: string) => {
				if (!line.trim()) return;
				let event: Record<string, unknown>;
				try {
					const parsed: unknown = JSON.parse(line);
					if (!isRecord(parsed)) {
						recordProtocolError(line);
						return;
					}
					event = parsed;
				} catch {
					recordProtocolError(line);
					return;
				}
				if (event.type === "message_end" && event.message) recordMessage(event.message as Message);
				if (event.type === "tool_result_end" && event.message) recordMessage(event.message as Message);
			};

			proc.stdout.on("data", (data) => {
				buffer += data.toString();
				const lines = buffer.split("\n");
				buffer = lines.pop() || "";
				for (const line of lines) processLine(line);
			});
			proc.stderr.on("data", (data) => {
				currentResult.stderr += data.toString();
			});
			proc.on("close", (code, childSignal) => {
				if (buffer.trim()) processLine(buffer);
				if (childSignal) {
					appendDiagnostic(currentResult, `Subagent process terminated by signal ${childSignal}`);
					settle(1);
					return;
				}
				settle(code ?? 1);
			});
			proc.on("error", (error) => {
				if (settled) return;
				appendDiagnostic(currentResult, `Failed to spawn subagent process: ${error.message}`);
				settle(1);
			});
			if (signal) {
				const killProc = () => {
					if (settled) return;
					wasAborted = true;
					killProcessGroup(proc, "SIGTERM");
					// The escalation is NOT gated on the direct child's liveness: a child that obeys
					// SIGTERM settles immediately while a descendant that ignores it is still in the
					// group. When every member is already gone the group kill is a no-op (ESRCH →
					// direct-kill fallback on a reaped pid), so firing unconditionally is what makes
					// "neither survives" hold however early the child itself exits.
					const force = setTimeout(() => killProcessGroup(proc, "SIGKILL"), GROUP_KILL_GRACE_MS);
					force.unref?.();
				};
				if (signal.aborted) killProc();
				else signal.addEventListener("abort", killProc, { once: true });
			}
		});

		currentResult.exitCode = exitCode;
		if (wasAborted && exitCode !== 0) {
			markAborted("Subagent was aborted");
			return currentResult;
		}
		const [firstProtocolError] = currentResult.protocolErrors ?? [];
		if (firstProtocolError !== undefined) {
			currentResult.exitCode = 1;
			appendDiagnostic(currentResult, `Subagent emitted malformed JSON protocol output: ${firstProtocolError}`);
		}
		return currentResult;
	} finally {
		if (tmpPromptPath)
			try {
				fs.unlinkSync(tmpPromptPath);
			} catch (error) {
				appendDiagnostic(currentResult, `Failed to remove temporary prompt ${tmpPromptPath}: ${(error as Error).message}`);
			}
		if (tmpPromptDir)
			try {
				fs.rmdirSync(tmpPromptDir);
			} catch (error) {
				appendDiagnostic(currentResult, `Failed to remove temporary prompt directory ${tmpPromptDir}: ${(error as Error).message}`);
			}
	}
}

/**
 * Total launch boundary: every mode (and the pool) assumes this resolves to a SingleResult, never rejects.
 * An unexpected throw becomes a failed result with the same shape, so one crashed task can never strand a
 * pooled call's waiter or reject a whole parallel batch.
 */
export async function runSingleAgent(
	defaultCwd: string,
	agents: readonly AgentConfig[],
	agentName: string,
	task: string,
	cwd: string | undefined,
	step: number | undefined,
	signal: AbortSignal | undefined,
	onUpdate: OnUpdateCallback | undefined,
	makeDetails: (results: SingleResult[]) => SubagentDetails,
	routingSnapshot: SubagentRoutingSnapshot,
	launch: LaunchContext,
): Promise<SingleResult> {
	try {
		return await runSingleAgentUnsafe(
			defaultCwd,
			agents,
			agentName,
			task,
			cwd,
			step,
			signal,
			onUpdate,
			makeDetails,
			routingSnapshot,
			launch,
		);
	} catch (cause) {
		const message = `Subagent launch failed: ${cause instanceof Error ? cause.message : String(cause)}`;
		const result = placeholderResult(agentName, task);
		result.agentSource = agents.find((candidate) => candidate.name === agentName)?.source ?? "unknown";
		result.exitCode = 1;
		result.step = step;
		result.errorMessage = message;
		// The stack stays out of the one-line errorMessage but lands in stderr: a genuine in-harness
		// crash must be reproducible, not just quotable.
		result.stderr = cause instanceof Error && cause.stack ? `${message}\n${cause.stack.slice(0, 2_000)}` : message;
		return result;
	}
}

/** One pooled call's execution — the `executePooled` path DESIGN-pool.md §9 inventories. The
 * dependency record is explicit, so the branch's dependency surface is visible at its seam instead
 * of implied by closure capture, and the integration harness exercises a named interface. */
type PooledExecuteDeps = Readonly<{
	cwd: string;
	agents: readonly AgentConfig[];
	routingSnapshot: SubagentRoutingSnapshot;
	makeDetails: (results: SingleResult[]) => SubagentDetails;
	onUpdate: OnUpdateCallback | undefined;
	signal: AbortSignal | undefined;
	sessionId: string;
	toolCallId: string;
	events: SubagentLaunchEventBus;
	pool: Dispatcher<PoolTaskPayload, SingleResult>;
	poolMode: "single" | "parallel";
	requestedTasks: readonly Readonly<{ agent: string; task: string; cwd: string | undefined }>[];
	background: boolean;
	maxAttempts: number;
	/** Registers a background call so its settlements surface as coalesced messages. */
	registerBackgroundCall: (callId: string) => void;
}>;

async function executePooled(deps: PooledExecuteDeps): Promise<AgentToolResult<SubagentDetails>> {
	const { cwd, agents, routingSnapshot, makeDetails, onUpdate, signal, sessionId, toolCallId, events, pool, poolMode, requestedTasks, background, maxAttempts, registerBackgroundCall } = deps;

	const poolTasks: PoolTaskPayload[] = requestedTasks.map((requested, index) =>
		Object.freeze({
			agent: requested.agent,
			task: requested.task,
			cwd: requested.cwd,
			index,
			slot: poolMode === "parallel"
				? Object.freeze({ kind: "parallel" as const, index })
				: Object.freeze({ kind: "single" as const, index: 0 }),
		}),
	);

	const allResults: SingleResult[] = poolTasks.map((task) => placeholderResult(task.agent, task.task));
	const emitPoolUpdate = () => {
		if (onUpdate === undefined || background) return;
		const done = allResults.filter((result) => result.exitCode !== -1).length;
		onUpdate({
			content: [{ type: "text", text: `Pool: ${done}/${allResults.length} done, ${allResults.length - done} running...` }],
			details: makeDetails([...allResults]),
		});
	};

	const launchPooledTask = async (
		entry: PoolEntry<PoolTaskPayload, SingleResult>,
		entrySignal: AbortSignal,
	): Promise<PoolOutcome<SingleResult>> => {
		const payload = entry.payload;
		const result = await runSingleAgent(
			cwd,
			agents,
			payload.agent,
			payload.task,
			payload.cwd,
			undefined,
			entrySignal,
			background
				? undefined
				: (partial) => {
					const streamed = partial.details?.results[0];
					if (streamed !== undefined) {
						allResults[payload.index] = streamed;
						emitPoolUpdate();
					}
				},
			makeDetails,
			routingSnapshot,
			{ events, sessionId, toolCallId, slot: payload.slot },
		);
		// One home for the retry policy (pool.ts); the shell only supplies its failure predicate.
		const outcome = classifyPoolAttempt(entry, result, entrySignal.aborted, resultFailed);
		if (outcome.kind === "failed" && outcome.retryable) {
			appendDiagnostic(
				result,
				`Pool attempt ${entry.attempts}/${entry.maxAttempts} failed; retrying on the next free slot`,
			);
		}
		return outcome;
	};

	if (background) registerBackgroundCall(toolCallId);
	const dispatched = await pool.enqueue({
		callId: toolCallId,
		items: poolTasks.map((task, index) => {
			const descriptor = parseEmissionDescriptor(task.task);
			return {
				id: `${toolCallId}#${index}`,
				payload: task,
				// Emission tasks are single-use: their staged expectation dies with the attempt.
				retryable: descriptor.ok && descriptor.value === null,
			};
		}),
		maxAttempts,
		launch: launchPooledTask,
		background,
		...(background || signal === undefined ? {} : { signal }),
	});

	if (background) {
		const snapshot = pool.snapshot();
		return {
			content: [{
				type: "text",
				text:
					`Pool: ${dispatched.entries.length} task(s) accepted, ${snapshot.running}/${snapshot.cap} running, ${snapshot.queued} queued. ` +
					"Completions arrive as messages; /pool shows status, /pool cancel <taskId|all> cancels.",
			}],
			details: { ...makeDetails([]), pool: snapshot },
		};
	}

	// results[i] is the task enqueued at index i (I13) — orderedPooledResults owns that invariant.
	const results = orderedPooledResults(dispatched.entries);
	if (poolMode === "single") {
		const [result] = results;
		const [sole] = requestedTasks;
		if (result === undefined || sole === undefined) {
			return singleToolResult(
				placeholderResult(sole?.agent ?? "unknown", sole?.task ?? ""),
				makeDetails([]),
			);
		}
		return singleToolResult(result, makeDetails(results));
	}
	return parallelToolResult(results, makeDetails(results));
}

/** I13's named home: results[i] is the task enqueued at index i. Ledger order is scheduling order —
 * a retry requeues at the tail — so the mapping orders by the payload's input index, unconditionally. */
function orderedPooledResults(
	entries: readonly PoolEntry<PoolTaskPayload, SingleResult>[],
): SingleResult[] {
	return [...entries]
		.sort((left, right) => left.payload.index - right.payload.index)
		.map((entry) => {
			const outcome = entry.outcome;
			if (outcome === null) return placeholderResult(entry.payload.agent, entry.payload.task);
			if (outcome.kind === "aborted") return abortedPoolResult(entry, outcome);
			return outcome.result;
		});
}

const TaskItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task to delegate to the agent" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
});

const ChainItem = Type.Object({
	agent: Type.String({ description: "Name of the agent to invoke" }),
	task: Type.String({ description: "Task with optional {previous} placeholder for prior output" }),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process" })),
});

const AgentScopeSchema = StringEnum(["user", "project", "both"] as const, {
	description: 'Which agent directories to use. Default: "user". Use "both" to include project-local agents.',
	default: "user",
});

const SubagentParams = Type.Object({
	agent: Type.Optional(Type.String({ description: "Name of the agent to invoke (for single mode)" })),
	task: Type.Optional(Type.String({ description: "Task to delegate (for single mode)" })),
	tasks: Type.Optional(Type.Array(TaskItem, { description: "Array of {agent, task} for parallel execution" })),
	chain: Type.Optional(Type.Array(ChainItem, { description: "Array of {agent, task} for sequential execution" })),
	agentScope: Type.Optional(AgentScopeSchema),
	confirmProjectAgents: Type.Optional(
		Type.Boolean({ description: "Prompt before running project-local agents. Default: true.", default: true }),
	),
	cwd: Type.Optional(Type.String({ description: "Working directory for the agent process (single mode)" })),
	pool: Type.Optional(
		Type.Union([
			Type.Boolean({
				description:
					"Run this call through the process-wide pool: slots are shared with other pooled calls and a freed slot starts the next queued task immediately, instead of waiting for this call's whole batch to settle.",
			}),
			Type.Object({
				background: Type.Optional(
					Type.Boolean({
						description:
							"Return immediately and report completions as messages. Non-Loom tasks only; a Loom-governed batch is refused because Loom settles it from this tool result.",
					}),
				),
				maxAttempts: Type.Optional(
					Type.Integer({
						minimum: 1,
						maximum: 3,
						description:
							"Process-level attempts per task (non-zero exit, crash). Semantic failures are never retried, and Loom emission tasks are single-use. Default 1.",
					}),
				),
			}),
		]),
	),
});

export default function (pi: ExtensionAPI) {
	advertiseSubagentLaunchPort(pi.events);

	// One dispatcher per extension instance: every pooled call shares the same slots, so a task that
	// settles in one call immediately starts the next queued task from any call (retries included).
	const backgroundPoolCalls = new Set<string>();
	const pendingPoolNotices = new Map<string, string[]>();
	let poolNoticeTimer: NodeJS.Timeout | undefined;

	const flushPoolNotices = (callId: string, drained: boolean): void => {
		const lines = pendingPoolNotices.get(callId) ?? [];
		pendingPoolNotices.delete(callId);
		if (drained) backgroundPoolCalls.delete(callId);
		if (lines.length === 0 && !drained) return;
		const header = drained ? "Subagent pool drained" : "Subagent pool progress";
		const body = lines.length > 0 ? `\n\n${lines.join("\n\n")}` : "";
		pi.sendMessage(
			{ customType: "subagent-pool", content: `${header}${body}`, display: true },
			{ deliverAs: "steer", triggerTurn: true },
		);
	};

	const schedulePoolNoticeFlush = (): void => {
		if (poolNoticeTimer !== undefined) return;
		poolNoticeTimer = setTimeout(() => {
			poolNoticeTimer = undefined;
			for (const callId of [...pendingPoolNotices.keys()]) flushPoolNotices(callId, false);
		}, 1_500);
		poolNoticeTimer.unref?.();
	};

	const pool = createDispatcher<PoolTaskPayload, SingleResult>({
		cap: poolConcurrencyFromEnv(process.env.PI_SUBAGENT_POOL_CONCURRENCY),
		onSettle: (entry, outcome) => {
			if (!backgroundPoolCalls.has(entry.callId)) return;
			const lines = pendingPoolNotices.get(entry.callId) ?? [];
			lines.push(describePoolSettle(entry, outcome));
			pendingPoolNotices.set(entry.callId, lines);
			schedulePoolNoticeFlush();
		},
		onCallDrained: (callId) => {
			if (!backgroundPoolCalls.has(callId)) return;
			const lines = pendingPoolNotices.get(callId) ?? [];
			lines.push("(all tasks drained)");
			pendingPoolNotices.set(callId, lines);
			flushPoolNotices(callId, true);
		},
	});

	pi.registerCommand("pool", {
		description: "Show subagent pool status, or cancel one with '/pool cancel <taskId|all>'",
		handler: async (args, ctx) => {
			const parts = args.trim().split(/\s+/).filter((part) => part.length > 0);
			if (parts[0] === "cancel") {
				const target = parts.slice(1).join(" ");
				if (target === "" || target === "all") {
					pool.cancelAll();
					if (ctx.hasUI) ctx.ui.notify("Cancelled all pooled subagent work", "info");
					return;
				}
				const cancelled = pool.cancel(target);
				if (ctx.hasUI) {
					ctx.ui.notify(
						cancelled.ok ? `Cancelled pooled task ${target}` : `No pooled task '${target}'`,
						cancelled.ok ? "info" : "warning",
					);
				}
				return;
			}
			const snapshot = pool.snapshot();
			const lines = [
				`Pool: ${snapshot.running}/${snapshot.cap} running, ${snapshot.queued} queued, ${snapshot.settled} settled`,
				...pool.entries().map((entry) =>
					`${entry.id} [${entry.payload.agent}] ${entry.phase} (attempt ${entry.attempts}/${entry.maxAttempts})`,
				),
			];
			if (ctx.hasUI) ctx.ui.notify(lines.join("\n"), "info");
		},
	});

	pi.on("session_shutdown", async () => {
		// SIGTERM every running child's process group, then hold the event loop open past the SIGKILL
		// grace so the escalation timers fire before pi exits (I8: no pool-owned child survives
		// shutdown). Early exit when the entries settle is not an option: the direct child settles on
		// SIGTERM while a SIGTERM-ignoring descendant is still in the group, so only the deadline
		// proves the escalation was delivered.
		pool.cancelAll();
		if (pool.snapshot().running === 0) return;
		const deadline = Date.now() + GROUP_KILL_GRACE_MS + 1_000;
		while (Date.now() < deadline) {
			await new Promise<void>((resolve) => setTimeout(resolve, 50));
		}
	});
	pi.registerTool({
		name: "subagent",
		label: "Subagent",
		description: [
			"Delegate tasks to specialized subagents with isolated context.",
			"Modes: single (agent + task), parallel (tasks array), chain (sequential with {previous} placeholder).",
			'Default agent scope is "user" (from ~/.pi/agent/agents).',
			'To enable project-local agents in .pi/agents, set agentScope: "both" (or "project").',
		].join(" "),
		parameters: SubagentParams,

		async execute(toolCallId, params, signal, onUpdate, ctx) {
			const sessionId = ctx.sessionManager.getSessionId();
			const agentScope: AgentScope = params.agentScope ?? "user";
			const discovery = discoverAgents(ctx.cwd, agentScope);
			const agents = discovery.agents;
			const confirmProjectAgents = params.confirmProjectAgents ?? true;

			const hasChain = (params.chain?.length ?? 0) > 0;
			const hasTasks = (params.tasks?.length ?? 0) > 0;
			const hasSingle = Boolean(params.agent && params.task);
			const modeCount = Number(hasChain) + Number(hasTasks) + Number(hasSingle);
			let routingPolicyDigest: string | undefined;

			const makeDetails =
				(mode: "single" | "parallel" | "chain") =>
				(results: SingleResult[]): SubagentDetails => ({
					mode,
					agentScope,
					projectAgentsDir: discovery.projectAgentsDir,
					routingPolicyDigest,
					results,
				});

			if (modeCount !== 1) {
				const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
				return {
					content: [
						{
							type: "text",
							text: `Invalid parameters. Provide exactly one mode.\nAvailable agents: ${available}`,
						},
					],
					details: makeDetails("single")([]),
				};
			}

			const loadedRouting = loadModelRoutingPolicy();
			if (!loadedRouting.ok) {
				throw new Error(
					`Cannot route subagent models from ${loadedRouting.error.path}:\n${loadedRouting.error.message}`,
				);
			}
			routingPolicyDigest = loadedRouting.value.digest;
			// Probe served targets once per call, so every task in a parallel batch or
			// chain lands on the same model even if the primary switches mid-call.
			const routingSnapshot = await buildRoutingSnapshot(
				loadedRouting.value,
				parentBinding(ctx.model, ctx.thinkingLevel),
				servedModelSourceFromRegistry(ctx.modelRegistry),
			);

			if ((agentScope === "project" || agentScope === "both") && confirmProjectAgents && ctx.hasUI) {
				const requestedAgentNames = new Set<string>();
				if (params.chain) for (const step of params.chain) requestedAgentNames.add(step.agent);
				if (params.tasks) for (const t of params.tasks) requestedAgentNames.add(t.agent);
				if (params.agent) requestedAgentNames.add(params.agent);

				const projectAgentsRequested = Array.from(requestedAgentNames)
					.map((name) => agents.find((a) => a.name === name))
					.filter((a): a is AgentConfig => a?.source === "project");

				if (projectAgentsRequested.length > 0) {
					const names = projectAgentsRequested.map((a) => a.name).join(", ");
					const dir = discovery.projectAgentsDir ?? "(unknown)";
					const ok = await ctx.ui.confirm(
						"Run project-local agents?",
						`Agents: ${names}\nSource: ${dir}\n\nProject agents are repo-controlled. Only continue for trusted repositories.`,
					);
					if (!ok)
						return {
							content: [{ type: "text", text: "Canceled: project-local agents not approved." }],
							details: makeDetails(hasChain ? "chain" : hasTasks ? "parallel" : "single")([]),
						};
				}
			}

			const poolOption = normalizePoolOption(params.pool);
			if (!poolOption.ok) {
				return {
					content: [{ type: "text", text: `Invalid pool option: ${poolOption.error.reason}` }],
					details: makeDetails(hasChain ? "chain" : hasTasks ? "parallel" : "single")([]),
					isError: true,
				};
			}

			if (poolOption.value !== null) {
				if (hasChain) {
					return {
						content: [{ type: "text", text: "pool applies to single and parallel calls; a chain is already sequential." }],
						details: makeDetails("chain")([]),
						isError: true,
					};
				}
				const poolMode: "single" | "parallel" = hasTasks ? "parallel" : "single";
				const requestedTasks: ReadonlyArray<{ agent: string; task: string; cwd: string | undefined }> = params.tasks
					?? (params.agent !== undefined && params.task !== undefined
						? [{ agent: params.agent, task: params.task, cwd: params.cwd }]
						: []);
				if (requestedTasks.length > MAX_POOL_TASKS) {
					return {
						content: [{ type: "text", text: `Too many pooled tasks (${requestedTasks.length}). Max is ${MAX_POOL_TASKS}.` }],
						details: makeDetails(poolMode)([]),
						isError: true,
					};
				}
				const background = poolOption.value.background;
				if (background && looksLoomGoverned(requestedTasks.map((requested) => requested.task))) {
					return {
						content: [{
							type: "text",
							text:
								"pool.background is not available for Loom-governed tasks: Loom settles a dispatch from this tool result, so a background snapshot would settle it before its child runs. Use a blocking pooled call for Loom work.",
						}],
						details: makeDetails(poolMode)([]),
						isError: true,
					};
				}

				return executePooled({
					cwd: ctx.cwd,
					agents,
					routingSnapshot,
					makeDetails: (results) => makeDetails(poolMode)(results),
					onUpdate,
					signal,
					sessionId,
					toolCallId,
					events: pi.events,
					pool,
					poolMode,
					requestedTasks,
					background,
					maxAttempts: poolOption.value.maxAttempts,
					registerBackgroundCall: (callId) => backgroundPoolCalls.add(callId),
				});
			}


			if (params.chain && params.chain.length > 0) {
				const results: SingleResult[] = [];
				let previousOutput = "";

				for (let i = 0; i < params.chain.length; i++) {
					const step = params.chain[i];
					const taskWithContext = step.task.replace(/\{previous\}/g, previousOutput);

					// Create update callback that includes all previous results
					const chainUpdate: OnUpdateCallback | undefined = onUpdate
						? (partial) => {
								// Combine completed results with current streaming result
								const currentResult = partial.details?.results[0];
								if (currentResult) {
									const allResults = [...results, currentResult];
									onUpdate({
										content: partial.content,
										details: makeDetails("chain")(allResults),
									});
								}
							}
						: undefined;

					const result = await runSingleAgent(
						ctx.cwd,
						agents,
						step.agent,
						taskWithContext,
						step.cwd,
						i + 1,
						signal,
						chainUpdate,
						makeDetails("chain"),
						routingSnapshot,
						{
							events: pi.events,
							sessionId,
							toolCallId,
							slot: { kind: "chain", index: i },
						},
					);
					results.push(result);

					const isError = resultFailed(result);
					if (isError) {
						const errorMsg =
							result.errorMessage || result.stderr || getFinalOutput(result.messages) || "(no output)";
						return {
							content: [{ type: "text", text: `Chain stopped at step ${i + 1} (${step.agent}): ${errorMsg}` }],
							details: makeDetails("chain")(results),
							isError: true,
						};
					}
					previousOutput = getFinalOutput(result.messages);
				}
				return {
					content: [{ type: "text", text: getFinalOutput(results[results.length - 1].messages) || "(no output)" }],
					details: makeDetails("chain")(results),
				};
			}

			if (params.tasks && params.tasks.length > 0) {
				if (params.tasks.length > MAX_PARALLEL_TASKS)
					return {
						content: [
							{
								type: "text",
								text: `Too many parallel tasks (${params.tasks.length}). Max is ${MAX_PARALLEL_TASKS}.`,
							},
						],
						details: makeDetails("parallel")([]),
						isError: true,
					};

				// Track all results for streaming updates (-1 = still running).
				const allResults: SingleResult[] = [];
				for (let i = 0; i < params.tasks.length; i++) {
					allResults.push(placeholderResult(params.tasks[i].agent, params.tasks[i].task));
				}

				const emitParallelUpdate = () => {
					if (onUpdate) {
						const running = allResults.filter((r) => r.exitCode === -1).length;
						const done = allResults.filter((r) => r.exitCode !== -1).length;
						onUpdate({
							content: [
								{ type: "text", text: `Parallel: ${done}/${allResults.length} done, ${running} running...` },
							],
							details: makeDetails("parallel")([...allResults]),
						});
					}
				};

				const results = await mapWithConcurrencyLimit(params.tasks, MAX_CONCURRENCY, async (t, index) => {
					const result = await runSingleAgent(
						ctx.cwd,
						agents,
						t.agent,
						t.task,
						t.cwd,
						undefined,
						signal,
						// Per-task update callback
						(partial) => {
							if (partial.details?.results[0]) {
								allResults[index] = partial.details.results[0];
								emitParallelUpdate();
							}
						},
						makeDetails("parallel"),
						routingSnapshot,
						{
							events: pi.events,
							sessionId,
							toolCallId,
							slot: { kind: "parallel", index },
						},
					);
					allResults[index] = result;
					emitParallelUpdate();
					return result;
				});

				return parallelToolResult(results, makeDetails("parallel")(results));
			}

			if (params.agent && params.task) {
				const result = await runSingleAgent(
					ctx.cwd,
					agents,
					params.agent,
					params.task,
					params.cwd,
					undefined,
					signal,
					onUpdate,
					makeDetails("single"),
					routingSnapshot,
					{
						events: pi.events,
						sessionId,
						toolCallId,
						slot: { kind: "single", index: 0 },
					},
				);
				return singleToolResult(result, makeDetails("single")([result]));
			}

			const available = agents.map((a) => `${a.name} (${a.source})`).join(", ") || "none";
			return {
				content: [{ type: "text", text: `Invalid parameters. Available agents: ${available}` }],
				details: makeDetails("single")([]),
			};
		},

		renderCall(args, theme, _context) {
			const scope: AgentScope = args.agentScope ?? "user";
			if (args.chain && args.chain.length > 0) {
				let text =
					theme.fg("toolTitle", theme.bold("subagent ")) +
					theme.fg("accent", `chain (${args.chain.length} steps)`) +
					theme.fg("muted", ` [${scope}]`);
				for (let i = 0; i < Math.min(args.chain.length, 3); i++) {
					const step = args.chain[i];
					// Clean up {previous} placeholder for display
					const cleanTask = step.task.replace(/\{previous\}/g, "").trim();
					const preview = cleanTask.length > 40 ? `${cleanTask.slice(0, 40)}...` : cleanTask;
					text +=
						"\n  " +
						theme.fg("muted", `${i + 1}.`) +
						" " +
						theme.fg("accent", step.agent) +
						theme.fg("dim", ` ${preview}`);
				}
				if (args.chain.length > 3) text += `\n  ${theme.fg("muted", `... +${args.chain.length - 3} more`)}`;
				return new Text(text, 0, 0);
			}
			if (args.tasks && args.tasks.length > 0) {
				let text =
					theme.fg("toolTitle", theme.bold("subagent ")) +
					theme.fg("accent", `parallel (${args.tasks.length} tasks)`) +
					theme.fg("muted", ` [${scope}]`);
				for (const t of args.tasks.slice(0, 3)) {
					const preview = t.task.length > 40 ? `${t.task.slice(0, 40)}...` : t.task;
					text += `\n  ${theme.fg("accent", t.agent)}${theme.fg("dim", ` ${preview}`)}`;
				}
				if (args.tasks.length > 3) text += `\n  ${theme.fg("muted", `... +${args.tasks.length - 3} more`)}`;
				return new Text(text, 0, 0);
			}
			const agentName = args.agent || "...";
			const preview = args.task ? (args.task.length > 60 ? `${args.task.slice(0, 60)}...` : args.task) : "...";
			let text =
				theme.fg("toolTitle", theme.bold("subagent ")) +
				theme.fg("accent", agentName) +
				theme.fg("muted", ` [${scope}]`);
			text += `\n  ${theme.fg("dim", preview)}`;
			return new Text(text, 0, 0);
		},

		renderResult(result, { expanded }, theme, _context) {
			const details = result.details as SubagentDetails | undefined;
			if (!details || details.results.length === 0) {
				const text = result.content[0];
				return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
			}

			const mdTheme = getMarkdownTheme();

			const renderDisplayItems = (items: DisplayItem[], limit?: number) => {
				const toShow = limit ? items.slice(-limit) : items;
				const skipped = limit && items.length > limit ? items.length - limit : 0;
				let text = "";
				if (skipped > 0) text += theme.fg("muted", `... ${skipped} earlier items\n`);
				for (const item of toShow) {
					if (item.type === "text") {
						const preview = expanded ? item.text : item.text.split("\n").slice(0, 3).join("\n");
						text += `${theme.fg("toolOutput", preview)}\n`;
					} else {
						text += `${theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme))}\n`;
					}
				}
				return text.trimEnd();
			};

			if (details.mode === "single" && details.results.length === 1) {
				const r = details.results[0];
				const isError = r.exitCode !== 0 || r.stopReason === "error" || r.stopReason === "aborted";
				const icon = isError ? theme.fg("error", "✗") : theme.fg("success", "✓");
				const displayItems = getDisplayItems(r.messages);
				const finalOutput = getFinalOutput(r.messages);

				if (expanded) {
					const container = new Container();
					let header = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
					if (isError && r.stopReason) header += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
					container.addChild(new Text(header, 0, 0));
					if (isError && r.errorMessage)
						container.addChild(new Text(theme.fg("error", `Error: ${r.errorMessage}`), 0, 0));
					container.addChild(new Spacer(1));
					container.addChild(new Text(theme.fg("muted", "─── Task ───"), 0, 0));
					container.addChild(new Text(theme.fg("dim", r.task), 0, 0));
					container.addChild(new Spacer(1));
					container.addChild(new Text(theme.fg("muted", "─── Output ───"), 0, 0));
					if (displayItems.length === 0 && !finalOutput) {
						container.addChild(new Text(theme.fg("muted", "(no output)"), 0, 0));
					} else {
						for (const item of displayItems) {
							if (item.type === "toolCall")
								container.addChild(
									new Text(
										theme.fg("muted", "→ ") + formatToolCall(item.name, item.args, theme.fg.bind(theme)),
										0,
										0,
									),
								);
						}
						if (finalOutput) {
							container.addChild(new Spacer(1));
							container.addChild(new Markdown(finalOutput.trim(), 0, 0, mdTheme));
						}
					}
					const usageStr = formatUsageStats(r.usage, r.model);
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", usageStr), 0, 0));
					}
					return container;
				}

				let text = `${icon} ${theme.fg("toolTitle", theme.bold(r.agent))}${theme.fg("muted", ` (${r.agentSource})`)}`;
				if (isError && r.stopReason) text += ` ${theme.fg("error", `[${r.stopReason}]`)}`;
				if (isError && r.errorMessage) text += `\n${theme.fg("error", `Error: ${r.errorMessage}`)}`;
				else if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
				else {
					text += `\n${renderDisplayItems(displayItems, COLLAPSED_ITEM_COUNT)}`;
					if (displayItems.length > COLLAPSED_ITEM_COUNT) text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				}
				const usageStr = formatUsageStats(r.usage, r.model);
				if (usageStr) text += `\n${theme.fg("dim", usageStr)}`;
				return new Text(text, 0, 0);
			}

			const aggregateUsage = (results: SingleResult[]) => {
				const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, turns: 0 };
				for (const r of results) {
					total.input += r.usage.input;
					total.output += r.usage.output;
					total.cacheRead += r.usage.cacheRead;
					total.cacheWrite += r.usage.cacheWrite;
					total.cost += r.usage.cost;
					total.turns += r.usage.turns;
				}
				return total;
			};

			if (details.mode === "chain") {
				const successCount = details.results.filter((r) => r.exitCode === 0).length;
				const icon = successCount === details.results.length ? theme.fg("success", "✓") : theme.fg("error", "✗");

				if (expanded) {
					const container = new Container();
					container.addChild(
						new Text(
							icon +
								" " +
								theme.fg("toolTitle", theme.bold("chain ")) +
								theme.fg("accent", `${successCount}/${details.results.length} steps`),
							0,
							0,
						),
					);

					for (const r of details.results) {
						addExpandedResultSection(container, r, `─── Step ${r.step}: `, theme.fg.bind(theme), mdTheme);
					}

					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0));
					}
					return container;
				}

				// Collapsed view
				let text =
					icon +
					" " +
					theme.fg("toolTitle", theme.bold("chain ")) +
					theme.fg("accent", `${successCount}/${details.results.length} steps`);
				for (const r of details.results) {
					const rIcon = r.exitCode === 0 ? theme.fg("success", "✓") : theme.fg("error", "✗");
					const displayItems = getDisplayItems(r.messages);
					text += `\n\n${theme.fg("muted", `─── Step ${r.step}: `)}${theme.fg("accent", r.agent)} ${rIcon}`;
					if (displayItems.length === 0) text += `\n${theme.fg("muted", "(no output)")}`;
					else text += `\n${renderDisplayItems(displayItems, 5)}`;
				}
				const usageStr = formatUsageStats(aggregateUsage(details.results));
				if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
				text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				return new Text(text, 0, 0);
			}

			if (details.mode === "parallel") {
				const running = details.results.filter((r) => r.exitCode === -1).length;
				const successCount = details.results.filter((r) => r.exitCode === 0).length;
				const failCount = details.results.filter((r) => r.exitCode > 0).length;
				const isRunning = running > 0;
				let icon = theme.fg("success", "✓");
				if (isRunning) icon = theme.fg("warning", "⏳");
				else if (failCount > 0) icon = theme.fg("warning", "◐");
				const status = isRunning
					? `${successCount + failCount}/${details.results.length} done, ${running} running`
					: `${successCount}/${details.results.length} tasks`;

				if (expanded && !isRunning) {
					const container = new Container();
					container.addChild(
						new Text(
							`${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`,
							0,
							0,
						),
					);

					for (const r of details.results) {
						addExpandedResultSection(container, r, "─── ", theme.fg.bind(theme), mdTheme);
					}

					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) {
						container.addChild(new Spacer(1));
						container.addChild(new Text(theme.fg("dim", `Total: ${usageStr}`), 0, 0));
					}
					return container;
				}

				// Collapsed view (or still running)
				let text = `${icon} ${theme.fg("toolTitle", theme.bold("parallel "))}${theme.fg("accent", status)}`;
				for (const r of details.results) {
					let rIcon = theme.fg("error", "✗");
					if (r.exitCode === -1) rIcon = theme.fg("warning", "⏳");
					else if (r.exitCode === 0) rIcon = theme.fg("success", "✓");
					const displayItems = getDisplayItems(r.messages);
					text += `\n\n${theme.fg("muted", "─── ")}${theme.fg("accent", r.agent)} ${rIcon}`;
					if (displayItems.length === 0)
						text += `\n${theme.fg("muted", r.exitCode === -1 ? "(running...)" : "(no output)")}`;
					else text += `\n${renderDisplayItems(displayItems, 5)}`;
				}
				if (!isRunning) {
					const usageStr = formatUsageStats(aggregateUsage(details.results));
					if (usageStr) text += `\n\n${theme.fg("dim", `Total: ${usageStr}`)}`;
				}
				if (!expanded) text += `\n${theme.fg("muted", "(Ctrl+O to expand)")}`;
				return new Text(text, 0, 0);
			}

			const text = result.content[0];
			return new Text(text?.type === "text" ? text.text : "(no output)", 0, 0);
		},
	});
}
