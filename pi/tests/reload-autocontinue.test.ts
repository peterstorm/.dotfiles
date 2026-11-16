// End-to-end contract for the reload auto-continue: an LLM-callable reload_runtime tool must
// resume the agent turn after the reload it triggered, without a human prompt — the reload-side
// twin of the compaction "[auto-compacted]" nudge (tests/compaction-resume.test.ts and
// tests/pi-compaction-autocontinue-contract.sh). A manual /reload must stay idle.
// Drives the real extension through createAgentSession against a fake OpenAI-compatible server,
// mirroring tests/reload-command-dispatch.test.ts and the CLI-level contract test.
import { afterEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:http";
import type { Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	createAgentSession,
	DefaultResourceLoader,
	SessionManager,
	SettingsManager,
} from "@earendil-works/pi-coding-agent";
import reloadRuntime, {
	RELOAD_CONTINUE_CUSTOM_TYPE,
	RELOAD_CONTINUE_MESSAGE,
} from "../extensions/reload-runtime";

const scratch: string[] = [];
const servers: Server[] = [];
afterEach(() => {
	for (const server of servers.splice(0)) server.close();
	for (const directory of scratch.splice(0)) rmSync(directory, { recursive: true, force: true });
});

// Fake chat-completions server: every request gets a short stop response, so the continuation
// turn ends after one assistant message. SSE shape mirrors tests/pi-compaction-autocontinue-contract.sh.
const startFakeModelServer = async (): Promise<number> => {
	const server = createServer((req, res) => {
		if (req.method !== "POST" || !req.url?.includes("/chat/completions")) {
			res.writeHead(404).end();
			return;
		}
		req.resume();
		req.on("end", () => {
			res.writeHead(200, { "content-type": "text/event-stream" });
			const base = { id: "chatcmpl-fake", object: "chat.completion.chunk", created: 0, model: "fakemodel" };
			res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { content: "Continued after reload." }, finish_reason: null }] })}\n\n`);
			res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
			res.write(`data: ${JSON.stringify({ ...base, choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\n`);
			res.write("data: [DONE]\n\n");
			res.end();
		});
	});
	servers.push(server);
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	return (server.address() as { port: number }).port;
};

type JournalEntry = Readonly<{ type: string; customType?: string; data?: unknown; message?: { role: string; content: unknown; stopReason?: string } }>;

const textOf = (content: unknown): string => {
	if (typeof content === "string") return content;
	if (Array.isArray(content)) return content.filter((part) => part?.type === "text").map((part) => (part as { text: string }).text).join("\n");
	return "";
};

const isContinuation = (entry: JournalEntry): boolean =>
	entry.type === "message" && entry.message?.role === "user" && textOf(entry.message.content).includes(RELOAD_CONTINUE_MESSAGE);

const isAssistantStop = (entry: JournalEntry): boolean =>
	entry.type === "message" && entry.message?.role === "assistant" && entry.message.stopReason === "stop";

const waitFor = async (predicate: () => boolean, what: string, timeoutMs = 10_000): Promise<void> => {
	const start = Date.now();
	while (!predicate()) {
		if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
};

describe("reload auto-continue", () => {
	it("resumes the turn after a tool-triggered reload and stays idle on a manual reload", async () => {
		const port = await startFakeModelServer();
		const agentDir = mkdtempSync(join(tmpdir(), "pi-reload-continue-agent-"));
		const cwd = mkdtempSync(join(tmpdir(), "pi-reload-continue-cwd-"));
		scratch.push(agentDir, cwd);
		writeFileSync(agentDir + "/models.json", JSON.stringify({
			providers: {
				fakeprov: {
					baseUrl: `http://127.0.0.1:${port}/v1`,
					api: "openai-completions",
					apiKey: "fake-key",
					models: [{
						id: "fakemodel",
						name: "Fake Model",
						reasoning: false,
						input: ["text"],
						contextWindow: 8192,
						maxTokens: 8192,
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
					}],
				},
			},
		}));
		// Pin the fake provider: without a default, provider-default discovery picks a real
		// configured provider (env-auth) and the continuation turn would leave localhost.
		const settingsManager = SettingsManager.inMemory({
			compaction: { enabled: false },
			defaultProvider: "fakeprov",
			defaultModel: "fakemodel",
		});
		const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager, extensionFactories: [reloadRuntime] });
		await loader.reload();
		const { session } = await createAgentSession({
			cwd, agentDir, settingsManager, resourceLoader: loader,
			sessionManager: SessionManager.inMemory(cwd),
		});
		try {
			// Mirrors print-mode's binding: without it ctx.reload() is a no-op stub.
			await session.bindExtensions({ mode: "print", commandContextActions: { reload: () => session.reload() } });

			const tool = session.agent.state.tools.find((entry) => entry.name === "reload_runtime");
			if (!tool) throw new Error("reload_runtime tool unavailable");
			await tool.execute("test-call", {}, undefined, undefined);

			// The deferred command reloads, the reloaded instance consumes the pending marker
			// and the continuation turn runs to a stop response — no human prompt involved.
			const entries = (): JournalEntry[] => session.sessionManager.getEntries() as JournalEntry[];
			await waitFor(() => {
				const journal = entries();
				const continuationIndex = journal.findIndex(isContinuation);
				return continuationIndex >= 0 && journal.slice(continuationIndex + 1).some(isAssistantStop);
			}, "assistant response after the continuation prompt");

			const journal = entries();
			const markers = journal.filter((e) => e.type === "custom" && e.customType === RELOAD_CONTINUE_CUSTOM_TYPE);
			expect(markers.map((m) => (m.data as { kind: string }).kind)).toEqual(["pending", "consumed"]);
			const continuationIndex = journal.findIndex(isContinuation);
			expect(continuationIndex).toBeGreaterThan(0);
			expect(textOf(journal[continuationIndex].message?.content)).toBe(RELOAD_CONTINUE_MESSAGE);
			const firstMessageAfter = journal.slice(continuationIndex + 1).find((e) => e.type === "message");
			expect(firstMessageAfter && isAssistantStop(firstMessageAfter)).toBe(true);

			// A manual reload afterwards must not spawn another continuation: only the
			// "consumed" marker remains, so the session gains no new pair and no new turn.
			const markersBefore = markers.length;
			const continuationsBefore = journal.filter(isContinuation).length;
			await session.reload();
			const after = entries();
			expect(after.filter((e) => e.type === "custom" && e.customType === RELOAD_CONTINUE_CUSTOM_TYPE).length).toBe(markersBefore);
			expect(after.filter(isContinuation).length).toBe(continuationsBefore);
		} finally {
			session.dispose();
		}
	}, 20_000);
});
