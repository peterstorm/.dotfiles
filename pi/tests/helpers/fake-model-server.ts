// Shared helpers for SDK-level pi tests: a fake OpenAI-compatible chat-completions
// server (every request gets a short stop response, so a turn ends after one assistant
// message) plus the journal-poking utilities the e2e contracts share.
// SSE shape mirrors the heredoc servers in tests/pi-*-contract.sh (those stay
// self-contained: separate processes that cannot import TS).
import { createServer, type Server } from "node:http";

export type JournalEntry = Readonly<{
	type: string;
	customType?: string;
	data?: unknown;
	content?: unknown;
	message?: { role: string; content: unknown; stopReason?: string };
}>;

export const textOf = (content: unknown): string => {
	if (typeof content === "string") return content;
	if (Array.isArray(content)) return content.filter((part) => part?.type === "text").map((part) => (part as { text: string }).text).join("\n");
	return "";
};

export const waitFor = async (predicate: () => boolean, what: string, timeoutMs = 10_000): Promise<void> => {
	const start = Date.now();
	while (!predicate()) {
		if (Date.now() - start > timeoutMs) throw new Error(`timed out waiting for ${what}`);
		await new Promise((resolve) => setTimeout(resolve, 25));
	}
};

export type FakeModelServer = Readonly<{ port: number; close: () => Promise<void> }>;

export const startFakeModelServer = async (): Promise<FakeModelServer> => {
	const server: Server = createServer((req, res) => {
		if (req.method !== "POST" || !req.url?.includes("/chat/completions")) {
			res.writeHead(404).end();
			return;
		}
		req.resume();
		req.on("end", () => {
			res.writeHead(200, { "content-type": "text/event-stream" });
			const base = { id: "chatcmpl-fake", object: "chat.completion.chunk", created: 0, model: "fakemodel" };
			res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: { content: "Acknowledged." }, finish_reason: null }] })}\n\n`);
			res.write(`data: ${JSON.stringify({ ...base, choices: [{ index: 0, delta: {}, finish_reason: "stop" }] })}\n\n`);
			res.write(`data: ${JSON.stringify({ ...base, choices: [], usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 } })}\n\n`);
			res.write("data: [DONE]\n\n");
			res.end();
		});
	});
	await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
	const port = (server.address() as { port: number }).port;
	return {
		port,
		close: () => new Promise<void>((resolve) => server.close(() => resolve())),
	};
};

/** models.json content for the fake provider, pinned as the session default. */
export const fakeProviderModelsJson = (port: number): string =>
	JSON.stringify({
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
	});

/** Settings that pin the fake provider: without a default, provider-default
 * discovery picks a real configured provider (env-auth) and turns leave localhost. */
export const fakeProviderSettings = (): Record<string, unknown> => ({
	compaction: { enabled: false },
	defaultProvider: "fakeprov",
	defaultModel: "fakemodel",
});
