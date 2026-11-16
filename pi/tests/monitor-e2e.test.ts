// End-to-end contract for the monitor extension: the monitor tool must run a command in the
// background, keep the session interactive, and deliver the completion (exit code + output
// tail) as an injected message that triggers a turn. Cancel terminates the process without a
// completion. A reload must re-adopt running monitors through the session journal, and a
// monitor that ended while pi was away must be completed as missed on the next session start.
// Drives the real extension through createAgentSession against a fake model server, mirroring
// pi/tests/reload-autocontinue.test.ts.
import { afterEach, describe, expect, it } from "bun:test";
import { spawn } from "node:child_process";
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
import monitorExtension from "../extensions/monitor";

const scratch: string[] = [];
const closers: Array<() => Promise<void>> = [];
afterEach(async () => {
	for (const close of closers.splice(0)) await close();
	for (const directory of scratch.splice(0)) rmSync(directory, { recursive: true, force: true });
});

const setupSession = async () => {
	const server = await startFakeModelServer();
	closers.push(server.close);
	const agentDir = mkdtempSync(join(tmpdir(), "pi-monitor-e2e-agent-"));
	const cwd = mkdtempSync(join(tmpdir(), "pi-monitor-e2e-cwd-"));
	scratch.push(agentDir, cwd);
	writeFileSync(agentDir + "/models.json", fakeProviderModelsJson(server.port));
	const settingsManager = SettingsManager.inMemory(fakeProviderSettings());
	const loader = new DefaultResourceLoader({ cwd, agentDir, settingsManager, extensionFactories: [monitorExtension] });
	await loader.reload();
	const { session } = await createAgentSession({
		cwd, agentDir, settingsManager, resourceLoader: loader,
		sessionManager: SessionManager.inMemory(cwd),
	});
	await session.bindExtensions({ mode: "print", commandContextActions: { reload: () => session.reload() } });
	const tool = (name: string) => {
		const found = session.agent.state.tools.find((entry) => entry.name === name);
		if (!found) throw new Error(`${name} tool unavailable`);
		return found;
	};
	const entries = (): JournalEntry[] => session.sessionManager.getEntries() as JournalEntry[];
	return { session, tool, entries };
};

const monitorData = (entries: readonly JournalEntry[], kind: string): Array<Record<string, unknown>> =>
	entries
		.filter((e) => e.type === "custom" && e.customType === "monitor" && (e.data as { kind?: string } | undefined)?.kind === kind)
		.map((e) => e.data as Record<string, unknown>);

// Injected completions are custom messages: entry type "custom_message" with a top-level content.
const customMessages = (entries: readonly JournalEntry[], needle: string): string[] =>
	entries
		.filter((e) => e.type === "custom_message" && textOf(e.content).includes(needle))
		.map((e) => textOf(e.content));

const assistantStopsAfter = (entries: readonly JournalEntry[], index: number): boolean =>
	entries.slice(index + 1).some((e) => e.type === "message" && e.message?.role === "assistant" && e.message.stopReason === "stop");

describe("monitor end to end", () => {
	it("runs in the background, delivers the completion, and the completion triggers a turn", async () => {
		const { session, tool, entries } = await setupSession();
		try {
			const result = await tool("monitor").execute("call-1", { name: "ci", command: "echo phase-one; sleep 0.3; echo phase-two" }, undefined, undefined);
			const resultText = (result.content as Array<{ type: string; text: string }>)[0]?.text ?? "";
			expect(resultText).toContain("Monitor 'ci' started (pid ");
			// The turn was not blocked: the tool result is already here while the command sleeps.

			await waitFor(() => monitorData(entries(), "finished").length === 1, "finished journal entry");
			await waitFor(() => customMessages(entries(), "Monitor 'ci' finished").length === 1, "injected completion message");
			// The injected message triggers a turn; wait for its assistant response.
			await waitFor(() => {
				const j = entries();
				const finishedIndex = j.findIndex((e) => e.type === "custom" && (e.data as { kind?: string })?.kind === "finished");
				return finishedIndex >= 0 && assistantStopsAfter(j, finishedIndex);
			}, "assistant stop after the completion");

			const journal = entries();
			const finishedIndex = journal.findIndex((e) => e.type === "custom" && (e.data as { kind?: string })?.kind === "finished");
			const completion = customMessages(journal, "Monitor 'ci' finished")[0];
			expect(completion).toContain("exit 0");
			expect(completion).toContain("phase-two");
			expect(assistantStopsAfter(journal, finishedIndex)).toBe(true);
		} finally {
			session.dispose();
		}
	}, 20_000);

	it("cancels: process terminated, cancelled entry, no completion message", async () => {
		const { session, tool, entries } = await setupSession();
		try {
			const result = await tool("monitor").execute("call-1", { name: "slow", command: "sleep 30" }, undefined, undefined);
			const pid = Number(((result.content as Array<{ type: string; text: string }>)[0]?.text ?? "").match(/pid (\d+)/)?.[1]);
			expect(pid).toBeGreaterThan(0);

			await tool("monitor_cancel").execute("call-2", { name: "slow" }, undefined, undefined);
			await waitFor(() => monitorData(entries(), "cancelled").length === 1, "cancelled journal entry");
			await waitFor(() => {
				try {
					process.kill(pid, 0);
					return false;
				} catch {
					return true;
				}
			}, "monitor pid to die");

			expect(monitorData(entries(), "finished")).toHaveLength(0);
			expect(customMessages(entries(), "Monitor 'slow'")).toHaveLength(0);
		} finally {
			session.dispose();
		}
	}, 20_000);

	it("re-adopts a running monitor across a reload and completes it afterwards", async () => {
		const { session, tool, entries } = await setupSession();
		try {
			const result = await tool("monitor").execute("call-1", { name: "re", command: "echo before-reload; sleep 1; echo survived-the-reload" }, undefined, undefined);
			expect((result.content as Array<{ type: string; text: string }>)[0]?.text).toContain("started (pid");

			// Reload while the command is still sleeping: the old instance drops its
			// handles, the new one re-adopts via the journal and completes the monitor.
			await session.reload();

			await waitFor(() => monitorData(entries(), "finished").length === 1, "post-reload completion");
			const completion = customMessages(entries(), "survived-the-reload")[0];
			expect(completion).toContain("Monitor 're' finished (exit 0)");
			expect(monitorData(entries(), "started")).toHaveLength(1);
		} finally {
			session.dispose();
		}
	}, 20_000);

	it("completes a monitor that ended while pi was away as missed on the next session start", async () => {
		const { session, entries } = await setupSession();
		try {
			const child = spawn("sleep", ["0.05"]);
			await new Promise<void>((resolve) => child.on("exit", resolve));
			const dir = mkdtempSync(join(tmpdir(), "pi-monitor-e2e-missed-"));
			scratch.push(dir);
			const logPath = join(dir, "gone.log");
			const codePath = join(dir, "gone.code");
			writeFileSync(logPath, "the answer was 42\n");
			writeFileSync(codePath, "0");
			session.sessionManager.appendCustomEntry("monitor", {
				kind: "started",
				spec: { id: "missed-1", name: "gone", command: "echo hi", pid: child.pid, logPath, codePath, startedAt: Date.now() - 60_000 },
			});

			await session.reload();
			await waitFor(() => monitorData(entries(), "finished").length === 1, "missed completion entry");
			await waitFor(() => customMessages(entries(), "ended while pi was not watching").length === 1, "missed completion message");
			const completion = customMessages(entries(), "ended while pi was not watching")[0];
			expect(completion).toContain("Monitor 'gone'");
			expect(completion).toContain("the answer was 42");
		} finally {
			session.dispose();
		}
	}, 20_000);
});
