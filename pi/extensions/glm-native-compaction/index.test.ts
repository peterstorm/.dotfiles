import { afterEach, describe, expect, it } from "bun:test";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Api, Model } from "@earendil-works/pi-ai";
import {
	DEFAULT_COMPACTION_SETTINGS,
	type CompactionResult,
	type ExtensionAPI,
	type ExtensionContext,
	type ModelRegistry,
	type SessionBeforeCompactEvent,
	type SessionBeforeCompactResult,
} from "@earendil-works/pi-coding-agent";
import { catalogIds, catalogModel, isRecord } from "./catalog.testkit";
import { NO_THINKING } from "./compaction";
import glmNativeCompactionExtension, {
	compactionHook,
	compactOnGlmNative,
	compactWithoutThinkingVia,
	enabledIn,
	payloadWithoutThinking,
	resultOf,
	warningOf,
	type CompactionOutcome,
	type CompactionPorts,
} from "./index";

const user = (text: string): AgentMessage => ({ role: "user", content: [{ type: "text", text }], timestamp: 1 });
const assistant = (text: string): AgentMessage =>
	({
		role: "assistant",
		content: [{ type: "text", text }],
		api: "openai-completions",
		provider: "desktop-vllm",
		model: "glm-5.3-uncensored-native",
		usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } },
		stopReason: "stop",
		timestamp: 2,
	}) as AgentMessage;

function eventOf(options: Readonly<{ split?: boolean; signal?: AbortSignal }> = {}): SessionBeforeCompactEvent {
	return {
		type: "session_before_compact",
		preparation: {
			firstKeptEntryId: "kept-1",
			messagesToSummarize: [user("port the attention side"), assistant("done: bit-identical")],
			turnPrefixMessages: options.split ? [user("now the decoder"), assistant("halfway")] : [],
			isSplitTurn: options.split ?? false,
			tokensBefore: 52_288,
			fileOps: { read: new Set(), written: new Set(), edited: new Set() },
			settings: DEFAULT_COMPACTION_SETTINGS,
		},
		branchEntries: [],
		reason: "threshold",
		willRetry: false,
		signal: options.signal ?? new AbortController().signal,
	};
}

const GLM = catalogModel("glm-5.3-uncensored-native", "http://127.0.0.1:1/v1");
const COMPACTED: CompactionResult = { summary: "## Goal\nport", firstKeptEntryId: "kept-1", tokensBefore: 52_288 };

type Calls = { served: number; compacted: number };

function ports(overrides: Partial<CompactionPorts> & { served?: string | Error } = {}): Readonly<{ ports: CompactionPorts; calls: Calls }> {
	const calls: Calls = { served: 0, compacted: 0 };
	const { served = "glm-5.3-uncensored-native", ...rest } = overrides;
	return {
		calls,
		ports: {
			enabled: () => true,
			servedId: async () => {
				calls.served++;
				return served instanceof Error ? { ok: false, error: served.message } : { ok: true, value: served };
			},
			compactWithoutThinking: async () => {
				calls.compacted++;
				return { ok: true, value: COMPACTED };
			},
			...rest,
		},
	};
}

describe("compactOnGlmNative", () => {
	it("compacts without thinking when the server serves GLM-5.3 full", async () => {
		for (const served of ["glm-5.3-native", "glm-5.3-uncensored-native", "glm-5.3-cyber-native"]) {
			const { ports: p, calls } = ports({ served });
			expect(await compactOnGlmNative(eventOf(), GLM, p)).toEqual({ kind: "compacted", compaction: COMPACTED });
			expect(calls).toEqual({ served: 1, compacted: 1 });
		}
	});

	it("follows what the server serves, not the session's model id", async () => {
		const pinnedToWarmind = { ...GLM, id: "warmind-1017-native" };
		const glm = ports({ served: "glm-5.3-native" });
		expect((await compactOnGlmNative(eventOf(), pinnedToWarmind, glm.ports)).kind).toBe("compacted");
		const warmind = ports({ served: "warmind-1017-native" });
		expect(await compactOnGlmNative(eventOf(), GLM, warmind.ports)).toEqual({ kind: "pi-default" });
		expect(warmind.calls.compacted).toBe(0);
	});

	it("leaves Hyperflare's GLM-5.3-Flash to Pi", async () => {
		const { ports: p, calls } = ports({ served: "glm-5.3-flash-hyperflare-tp2-v16" });
		expect(await compactOnGlmNative(eventOf(), GLM, p)).toEqual({ kind: "pi-default" });
		expect(calls.compacted).toBe(0);
	});

	it("never probes for a session on another provider, or with no model, or when disabled", async () => {
		const cloud = { ...GLM, provider: "anthropic" };
		for (const [model, enabled] of [
			[cloud, true],
			[undefined, true],
			[GLM, false],
		] as const) {
			const { ports: p, calls } = ports({ enabled: () => enabled });
			expect(await compactOnGlmNative(eventOf(), model, p)).toEqual({ kind: "pi-default" });
			expect(calls).toEqual({ served: 0, compacted: 0 });
		}
	});

	it("keeps why the server could not be asked, and leaves the compaction to Pi", async () => {
		const { ports: p, calls } = ports({ served: new Error("cannot reach desktop-vllm") });
		expect(await compactOnGlmNative(eventOf(), GLM, p)).toEqual({ kind: "unprobed", error: "cannot reach desktop-vllm" });
		expect(calls.compacted).toBe(0);
	});

	it("falls back to Pi when its own compaction fails, and cancels when the user aborted", async () => {
		const failing = { compactWithoutThinking: async () => ({ ok: false as const, error: "Summarization attempted to call a tool" }) };
		expect(await compactOnGlmNative(eventOf(), GLM, ports(failing).ports)).toEqual({
			kind: "fell-back",
			error: "Summarization attempted to call a tool",
		});
		const aborted = new AbortController();
		aborted.abort();
		expect(await compactOnGlmNative(eventOf({ signal: aborted.signal }), GLM, ports(failing).ports)).toEqual({ kind: "aborted" });
	});

	it("treats an abort as an abort even when the compaction came back", async () => {
		// Pi's compact() returns an empty summary, rather than throwing, when the request is aborted.
		const aborted = new AbortController();
		aborted.abort();
		expect(await compactOnGlmNative(eventOf({ signal: aborted.signal }), GLM, ports().ports)).toEqual({ kind: "aborted" });
	});
});

describe("resultOf and warningOf", () => {
	it.each<[CompactionOutcome, SessionBeforeCompactResult | undefined, string | undefined]>([
		[{ kind: "compacted", compaction: COMPACTED }, { compaction: COMPACTED }, undefined],
		[{ kind: "aborted" }, { cancel: true }, undefined],
		[{ kind: "pi-default" }, undefined, undefined],
		[{ kind: "unprobed", error: "HTTP 502" }, undefined, "cannot tell what desktop-vllm serves (HTTP 502)"],
		[{ kind: "fell-back", error: "no key" }, undefined, "without thinking failed (no key)"],
	])("answers Pi for %p, warning only when Pi will compact the slow way", (outcome, expected, warned) => {
		expect(resultOf(outcome)).toEqual(expected);
		const warning = warningOf(outcome);
		if (warned === undefined) expect(warning).toBeUndefined();
		else {
			expect(warning).toContain(warned);
			expect(warning).toContain("Pi compacts the usual way, with thinking");
		}
	});
});

describe("enabledIn", () => {
	it("is off only for PI_GLM_COMPACTION=off", () => {
		expect(enabledIn({ PI_GLM_COMPACTION: "off" })).toBe(false);
		for (const value of [undefined, "on", "", "OFF", "0"]) expect(enabledIn({ PI_GLM_COMPACTION: value })).toBe(true);
	});
});

describe("payloadWithoutThinking", () => {
	it("passes a chat payload on asking for no thinking, and throws on anything else", () => {
		expect(payloadWithoutThinking({ messages: [], reasoning_effort: "max" })).toEqual({ messages: [], reasoning_effort: NO_THINKING });
		expect(() => payloadWithoutThinking({ input: [] })).toThrow("not a chat completion");
	});
});

type MayaRequest = Readonly<{ body: Record<string, unknown>; authorization: string | null; route: string | null }>;

/**
 * A Maya stand-in: answers /models with the id it serves, records each chat request, and streams
 * one canned summary (or answers every chat request with `status`).
 */
function fakeMaya(summary: string, options: Readonly<{ served?: string; status?: number }> = {}) {
	const requests: MayaRequest[] = [];
	const probes: string[] = [];
	const chunk = (delta: Record<string, unknown>, finish: string | null) =>
		`data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
	const server = Bun.serve({
		port: 0,
		async fetch(request) {
			if (request.method === "GET" && new URL(request.url).pathname === "/v1/models") {
				probes.push(request.headers.get("authorization") ?? "");
				return Response.json({ object: "list", data: [{ id: options.served ?? "glm-5.3-uncensored-native", object: "model" }] });
			}
			const body: unknown = await request.json();
			if (!isRecord(body)) return new Response("bad request", { status: 400 });
			requests.push({ body, authorization: request.headers.get("authorization"), route: request.headers.get("x-route") });
			if (options.status !== undefined) return new Response("busy", { status: options.status });
			const usage = `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [], usage: { prompt_tokens: 900, completion_tokens: 40, total_tokens: 940 } })}\n\n`;
			const stream = chunk({ role: "assistant", content: summary }, null) + chunk({}, "stop") + usage + "data: [DONE]\n\n";
			return new Response(stream, { headers: { "content-type": "text/event-stream" } });
		},
	});
	return { server, requests, probes, baseUrl: `http://127.0.0.1:${server.port}/v1` };
}

const registryWithKey = (key: string): ModelRegistry =>
	({ getApiKeyAndHeaders: async () => ({ ok: true, apiKey: key }) }) as unknown as ModelRegistry;

const servers: { stop: (force?: boolean) => void }[] = [];
afterEach(() => {
	for (const server of servers.splice(0)) server.stop(true);
});

describe("compactWithoutThinkingVia (Pi's real compact() and pi-ai against a fake Maya)", () => {
	it("sends every summary request with no thinking, and returns Pi's compaction", async () => {
		const maya = fakeMaya("## Goal\nPort GLM-5.3's attention side.");
		servers.push(maya.server);
		const model = catalogModel("glm-5.3-uncensored-native", maya.baseUrl);
		const compacted = await compactWithoutThinkingVia(registryWithKey("secret"))(eventOf({ split: true }), model);

		expect(compacted.ok).toBe(true);
		if (!compacted.ok) return;
		expect(compacted.value.summary).toContain("Port GLM-5.3's attention side.");
		expect(compacted.value.firstKeptEntryId).toBe("kept-1");
		// Maya's own spelling (serve/frontend.py EFFORT), pinned as a literal: "low" would still think.
		expect(NO_THINKING).toBe("none");
		// A split turn: Pi asks twice (the history, then the turn's prefix), both without thinking.
		expect(maya.requests).toHaveLength(2);
		for (const { body, authorization } of maya.requests) {
			expect(body.reasoning_effort).toBe("none");
			// Pi's off form for the deepseek thinking format: the request never says thinking is on.
			expect(body.thinking).toEqual({ type: "disabled" });
			expect(body.model).toBe("glm-5.3-uncensored-native");
			expect(body.tools).toBeUndefined();
			expect(authorization).toBe("Bearer secret");
		}
	});

	it("reports a request Maya refuses as a failure that says why, not a rejection", async () => {
		const maya = fakeMaya("unused", { status: 503 });
		servers.push(maya.server);
		const model = catalogModel("glm-5.3-uncensored-native", maya.baseUrl);
		const compacted = await compactWithoutThinkingVia(registryWithKey("secret"))(eventOf(), model);
		expect(compacted.ok).toBe(false);
		if (!compacted.ok) expect(compacted.error).toContain("503");
	});

	it("fails rather than send a summary request it cannot take thinking out of", async () => {
		const maya = fakeMaya("unused");
		servers.push(maya.server);
		// The Responses API's payload has no messages list, so withoutThinking cannot parse it.
		const responses = { ...catalogModel("glm-5.3-uncensored-native", maya.baseUrl), api: "openai-responses" } as Model<Api>;
		const compacted = await compactWithoutThinkingVia(registryWithKey("secret"))(eventOf(), responses);
		expect(compacted.ok).toBe(false);
		if (!compacted.ok) expect(compacted.error).toContain("not a chat completion");
		expect(maya.requests).toHaveLength(0);
	});

	it("ends as an abort, not a fall-back, when the user aborts a summary request in flight", async () => {
		let arrived: () => void = () => {};
		const received = new Promise<void>((resolve) => {
			arrived = resolve;
		});
		const server = Bun.serve({
			port: 0,
			fetch: () => {
				arrived();
				return new Promise<Response>(() => {});
			},
		});
		servers.push(server);
		const model = catalogModel("glm-5.3-uncensored-native", `http://127.0.0.1:${server.port}/v1`);
		const controller = new AbortController();
		const outcome = compactOnGlmNative(eventOf({ signal: controller.signal }), model, {
			enabled: () => true,
			servedId: async () => ({ ok: true, value: "glm-5.3-native" }),
			compactWithoutThinking: compactWithoutThinkingVia(registryWithKey("secret")),
		});
		await received;
		controller.abort();
		expect(await outcome).toEqual({ kind: "aborted" });
		expect(resultOf(await outcome)).toEqual({ cancel: true });
	});

	it("sends to the baseUrl auth resolves when it overrides the catalog's", async () => {
		const maya = fakeMaya("## Goal\nmoved");
		servers.push(maya.server);
		const registry = {
			getApiKeyAndHeaders: async () => ({ ok: true, apiKey: "k", baseUrl: maya.baseUrl, headers: { "x-route": "desktop", "x-drop": null } }),
		} as unknown as ModelRegistry;
		const compacted = await compactWithoutThinkingVia(registry)(eventOf(), GLM);
		expect(compacted.ok).toBe(true);
		expect(maya.requests).toHaveLength(1);
		expect(maya.requests[0]?.route).toBe("desktop");
	});

	it("reports missing auth without asking the server", async () => {
		const registry = { getApiKeyAndHeaders: async () => ({ ok: false, error: "no key" }) } as unknown as ModelRegistry;
		expect(await compactWithoutThinkingVia(registry)(eventOf(), GLM)).toEqual({ ok: false, error: "no key" });
	});
});

/** Pi's registry as the hook uses it: the real catalog, pointed at baseUrl, with one key. */
const registryAt = (baseUrl: string): ModelRegistry =>
	({
		getAll: () => [{ ...GLM, baseUrl }],
		find: (provider: string, id: string) => (provider === "desktop-vllm" && catalogIds().includes(id) ? catalogModel(id, baseUrl) : undefined),
		getApiKeyForProvider: async () => "secret",
		getApiKeyAndHeaders: async () => ({ ok: true, apiKey: "secret" }),
	}) as unknown as ModelRegistry;

/** The hook run as Pi runs it: a session on desktop-vllm, with or without a UI. */
async function runHook(maya: ReturnType<typeof fakeMaya>, options: Readonly<{ hasUI: boolean; env?: Record<string, string> }>) {
	const notified: string[] = [];
	const stderr: string[] = [];
	const ctx = {
		model: catalogModel("glm-5.3-uncensored-native", maya.baseUrl),
		modelRegistry: registryAt(maya.baseUrl),
		hasUI: options.hasUI,
		ui: { notify: (message: string, level: string) => void notified.push(`${level}: ${message}`) },
	} as unknown as ExtensionContext;
	const result = await compactionHook(options.env ?? {}, (line) => void stderr.push(line))(eventOf(), ctx);
	return { result, notified, stderr };
}

describe("compactionHook (the hook as Pi runs it, against a fake Maya)", () => {
	it("compacts without thinking and hands Pi the compaction, telling nobody", async () => {
		const maya = fakeMaya("## Goal\nPort the decoder.");
		servers.push(maya.server);
		const { result, notified, stderr } = await runHook(maya, { hasUI: true });
		expect(result ? result.compaction?.summary : undefined).toContain("Port the decoder.");
		expect(maya.probes).toEqual(["Bearer secret"]);
		expect(maya.requests.map(({ body }) => body.reasoning_effort)).toEqual(["none"]);
		expect([...notified, ...stderr]).toEqual([]);
	});

	it("leaves Pi alone without asking the server when PI_GLM_COMPACTION=off", async () => {
		const maya = fakeMaya("unused");
		servers.push(maya.server);
		const { result, notified, stderr } = await runHook(maya, { hasUI: true, env: { PI_GLM_COMPACTION: "off" } });
		expect(result).toBeUndefined();
		expect(maya.probes).toEqual([]);
		expect(maya.requests).toEqual([]);
		expect([...notified, ...stderr]).toEqual([]);
	});

	it("leaves another primary to Pi silently", async () => {
		const maya = fakeMaya("unused", { served: "warmind-1017-native" });
		servers.push(maya.server);
		const { result, notified, stderr } = await runHook(maya, { hasUI: false });
		expect(result).toBeUndefined();
		expect(maya.requests).toEqual([]);
		expect([...notified, ...stderr]).toEqual([]);
	});

	it.each([true, false])("warns (hasUI %p) when it cannot tell what the server serves", async (hasUI) => {
		const maya = fakeMaya("unused", { served: "not-in-the-catalog" });
		servers.push(maya.server);
		const { result, notified, stderr } = await runHook(maya, { hasUI });
		expect(result).toBeUndefined();
		expect(maya.requests).toEqual([]);
		const [line, ...rest] = hasUI ? notified : stderr;
		expect(rest).toEqual([]);
		expect(line).toContain("cannot tell what desktop-vllm serves");
		expect(line).toContain("not-in-the-catalog");
		expect(hasUI ? stderr : notified).toEqual([]);
		if (hasUI) expect(line?.startsWith("warning: ")).toBe(true);
		else expect(line?.startsWith("glm-native-compaction: ")).toBe(true);
	});

	it.each([true, false])("warns (hasUI %p) when its compaction fails, and lets Pi compact", async (hasUI) => {
		const maya = fakeMaya("unused", { status: 503 });
		servers.push(maya.server);
		const { result, notified, stderr } = await runHook(maya, { hasUI });
		expect(result).toBeUndefined();
		const [line, ...rest] = hasUI ? notified : stderr;
		expect(rest).toEqual([]);
		expect(line).toContain("without thinking failed");
		expect(line).toContain("503");
		expect(hasUI ? stderr : notified).toEqual([]);
	});
});

describe("glmNativeCompactionExtension", () => {
	it("registers one session_before_compact hook", () => {
		const events: string[] = [];
		glmNativeCompactionExtension({ on: (event: string, handler: unknown) => void events.push(`${event}:${typeof handler}`) } as unknown as ExtensionAPI);
		expect(events).toEqual(["session_before_compact:function"]);
	});
});
