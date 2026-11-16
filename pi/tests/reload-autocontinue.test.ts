// End-to-end contract for the reload auto-continue: an LLM-callable reload_runtime tool must
// resume the agent turn after the reload it triggered, without a human prompt — the reload-side
// twin of the compaction "[auto-compacted]" nudge (pi/tests/compaction-resume.test.ts and
// tests/pi-compaction-autocontinue-contract.sh). A manual /reload must stay idle.
// Drives the real extension through createAgentSession against a fake OpenAI-compatible server,
// mirroring pi/tests/reload-command-dispatch.test.ts and the CLI-level contract test.
import { afterEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
	createAgentSession,
	DefaultResourceLoader,
	SessionManager,
	SettingsManager,
} from "@earendil-works/pi-coding-agent";
import { fakeProviderModelsJson, fakeProviderSettings, JournalEntry, startFakeModelServer, textOf, waitFor } from "./helpers/fake-model-server";
import reloadRuntime, { RELOAD_CONTINUE_CUSTOM_TYPE, RELOAD_CONTINUE_MESSAGE } from "../extensions/reload-runtime";

const scratch: string[] = [];
const closers: Array<() => Promise<void>> = [];
afterEach(async () => {
	for (const close of closers.splice(0)) await close();
	for (const directory of scratch.splice(0)) rmSync(directory, { recursive: true, force: true });
});

const isContinuation = (entry: JournalEntry): boolean =>
	entry.type === "message" && entry.message?.role === "user" && textOf(entry.message.content).includes(RELOAD_CONTINUE_MESSAGE);

const isAssistantStop = (entry: JournalEntry): boolean =>
	entry.type === "message" && entry.message?.role === "assistant" && entry.message.stopReason === "stop";

// The one continuation-completion predicate, used by both the wait and the assertion below:
// the first message entry after the continuation turn is its assistant stop response.
const continuationCompleted = (journal: readonly JournalEntry[]): boolean => {
	const continuationIndex = journal.findIndex(isContinuation);
	return continuationIndex >= 0 && isAssistantStop(journal.slice(continuationIndex + 1).find((e) => e.type === "message") ?? { type: "none" });
};

describe("reload auto-continue", () => {
	it("resumes the turn after a tool-triggered reload and stays idle on a manual reload", async () => {
		const server = await startFakeModelServer();
		closers.push(server.close);
		const agentDir = mkdtempSync(join(tmpdir(), "pi-reload-continue-agent-"));
		const cwd = mkdtempSync(join(tmpdir(), "pi-reload-continue-cwd-"));
		scratch.push(agentDir, cwd);
		writeFileSync(agentDir + "/models.json", fakeProviderModelsJson(server.port));
		const settingsManager = SettingsManager.inMemory(fakeProviderSettings());
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
			await waitFor(() => continuationCompleted(entries()), "assistant response after the continuation prompt");

			const journal = entries();
			const markers = journal.filter((e) => e.type === "custom" && e.customType === RELOAD_CONTINUE_CUSTOM_TYPE);
			expect(markers.map((m) => (m.data as { kind: string }).kind)).toEqual(["pending", "consumed"]);
			const continuationIndex = journal.findIndex(isContinuation);
			expect(continuationIndex).toBeGreaterThan(0);
			expect(textOf(journal[continuationIndex].message?.content)).toBe(RELOAD_CONTINUE_MESSAGE);
			expect(continuationCompleted(journal)).toBe(true);

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
