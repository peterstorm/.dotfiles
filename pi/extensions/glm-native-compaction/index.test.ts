import { afterEach, describe, expect, it } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import type { Api, Model } from "@earendil-works/pi-ai";
import {
	DEFAULT_COMPACTION_SETTINGS,
	type CompactionResult,
	type ExtensionAPI,
	type ModelRegistry,
	type SessionBeforeCompactEvent,
} from "@earendil-works/pi-coding-agent";
import { NO_THINKING } from "./compaction";
import glmNativeCompactionExtension, {
	compactOnGlmNative,
	compactWithoutThinkingVia,
	resultOf,
	type CompactionOutcome,
	type CompactionPorts,
} from "./index";

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

/** The catalog entry Pi really uses for the uncensored primary (its compat decides the payload's shape). */
function catalogModel(id: string, baseUrl: string): Model<Api> {
	const raw: unknown = JSON.parse(readFileSync(join(import.meta.dir, "../../models.json"), "utf8"));
	const provider = isRecord(raw) && isRecord(raw.providers) ? raw.providers["desktop-vllm"] : undefined;
	const models: unknown = isRecord(provider) ? provider.models : undefined;
	const entry = Array.isArray(models) ? models.find((model: unknown) => isRecord(model) && model.id === id) : undefined;
	if (!isRecord(entry) || !isRecord(provider)) throw new Error(`pi/models.json has no desktop-vllm/${id}`);
	return { ...entry, provider: "desktop-vllm", api: provider.api, baseUrl } as unknown as Model<Api>;
}

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

	it("leaves the compaction to Pi when the server cannot be asked", async () => {
		const { ports: p, calls } = ports({ served: new Error("cannot reach desktop-vllm") });
		expect(await compactOnGlmNative(eventOf(), GLM, p)).toEqual({ kind: "pi-default" });
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
});

describe("resultOf", () => {
	it.each<[CompactionOutcome, unknown]>([
		[{ kind: "compacted", compaction: COMPACTED }, { compaction: COMPACTED }],
		[{ kind: "aborted" }, { cancel: true }],
		[{ kind: "pi-default" }, undefined],
		[{ kind: "fell-back", error: "x" }, undefined],
	])("maps %p to Pi's hook result", (outcome, expected) => {
		expect(resultOf(outcome)).toEqual(expected);
	});
});

/** A Maya stand-in: records each chat request and streams one canned summary. */
function fakeMaya(summary: string) {
	const requests: Readonly<{ body: Record<string, unknown>; authorization: string | null; route: string | null }>[] = [];
	const chunk = (delta: Record<string, unknown>, finish: string | null) =>
		`data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [{ index: 0, delta, finish_reason: finish }] })}\n\n`;
	const server = Bun.serve({
		port: 0,
		async fetch(request) {
			const body: unknown = await request.json();
			if (!isRecord(body)) return new Response("bad request", { status: 400 });
			requests.push({ body, authorization: request.headers.get("authorization"), route: request.headers.get("x-route") });
			const usage = `data: ${JSON.stringify({ id: "c", object: "chat.completion.chunk", created: 1, model: "m", choices: [], usage: { prompt_tokens: 900, completion_tokens: 40, total_tokens: 940 } })}\n\n`;
			const stream = chunk({ role: "assistant", content: summary }, null) + chunk({}, "stop") + usage + "data: [DONE]\n\n";
			return new Response(stream, { headers: { "content-type": "text/event-stream" } });
		},
	});
	return { server, requests, baseUrl: `http://127.0.0.1:${server.port}/v1` };
}

const registryWithKey = (key: string): ModelRegistry =>
	({ getApiKeyAndHeaders: async () => ({ ok: true, apiKey: key }) }) as unknown as ModelRegistry;

describe("compactWithoutThinkingVia (Pi's real compact() and pi-ai against a fake Maya)", () => {
	const servers: { stop: (force?: boolean) => void }[] = [];
	afterEach(() => {
		for (const server of servers.splice(0)) server.stop(true);
	});

	it("sends every summary request with no thinking, and returns Pi's compaction", async () => {
		const maya = fakeMaya("## Goal\nPort GLM-5.3's attention side.");
		servers.push(maya.server);
		const model = catalogModel("glm-5.3-uncensored-native", maya.baseUrl);
		const compacted = await compactWithoutThinkingVia(registryWithKey("secret"))(eventOf({ split: true }), model);

		expect(compacted.ok).toBe(true);
		if (!compacted.ok) return;
		expect(compacted.value.summary).toContain("Port GLM-5.3's attention side.");
		expect(compacted.value.firstKeptEntryId).toBe("kept-1");
		// A split turn: Pi asks twice (the history, then the turn's prefix), both without thinking.
		expect(maya.requests).toHaveLength(2);
		for (const { body, authorization } of maya.requests) {
			// Maya's own spelling (serve/frontend.py EFFORT), pinned as a literal: "low" would still think.
			expect(body.reasoning_effort).toBe("none");
			expect(NO_THINKING).toBe("none");
			// Pi's off form for the deepseek thinking format: the request never says thinking is on.
			expect(body.thinking).toEqual({ type: "disabled" });
			expect(body.model).toBe("glm-5.3-uncensored-native");
			expect(body.tools).toBeUndefined();
			expect(authorization).toBe("Bearer secret");
		}
	});

	it("reports a request Maya refuses as a failure, not a rejection", async () => {
		const server = Bun.serve({ port: 0, fetch: () => new Response("busy", { status: 503 }) });
		servers.push(server);
		const model = catalogModel("glm-5.3-uncensored-native", `http://127.0.0.1:${server.port}/v1`);
		const compacted = await compactWithoutThinkingVia(registryWithKey("secret"))(eventOf(), model);
		expect(compacted.ok).toBe(false);
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

describe("glmNativeCompactionExtension", () => {
	it("registers one session_before_compact hook", () => {
		const events: string[] = [];
		glmNativeCompactionExtension({ on: (event: string) => void events.push(event) } as unknown as ExtensionAPI);
		expect(events).toEqual(["session_before_compact"]);
	});
});
