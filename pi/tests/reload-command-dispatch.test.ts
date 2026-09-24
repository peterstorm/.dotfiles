import { afterEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentSession, DefaultResourceLoader, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const scratch: string[] = [];
afterEach(() => { for (const directory of scratch.splice(0)) rmSync(directory, { recursive: true, force: true }); });

describe("idle extension-command dispatch", () => {
	it("executes a tool-scheduled command without sending its slash text to the model", async () => {
		const cwd = mkdtempSync(join(tmpdir(), "pi-reload-dispatch-"));
		scratch.push(cwd);
		const settingsManager = SettingsManager.inMemory();
		let invoked = 0;
		const loader = new DefaultResourceLoader({
			cwd,
			agentDir: cwd,
			settingsManager,
			extensionFactories: [(pi) => {
				pi.registerCommand("record-reload", { handler: async () => { invoked++; } });
				pi.registerTool({
					name: "schedule_reload_test", label: "Schedule Reload Test", description: "Dispatch a test command",
					parameters: Type.Object({}),
					async execute() {
						pi.sendUserMessage("/record-reload", { deliverAs: "followUp", executeCommandAfterIdle: true });
						return { content: [{ type: "text", text: "scheduled" }], details: {} };
					},
				});
			}],
		});
		await loader.reload();
		const { session } = await createAgentSession({
			cwd, agentDir: cwd, settingsManager, resourceLoader: loader,
			sessionManager: SessionManager.inMemory(cwd),
		});
		try {
			const tool = session.agent.state.tools.find((entry) => entry.name === "schedule_reload_test");
			if (!tool) throw new Error("test tool unavailable");
			await tool.execute("test-call", {}, undefined, undefined);
			await new Promise<void>((resolve) => setImmediate(resolve));
			expect(invoked).toBe(1);
			await expect(session.sendUserMessage("/missing-command", {
				deliverAs: "followUp", executeCommandAfterIdle: true,
			})).rejects.toThrow("unknown deferred extension command");
			await expect(session.sendUserMessage("plain text", {
				deliverAs: "followUp", executeCommandAfterIdle: true,
			})).rejects.toThrow("deferred extension command requires slash text");
			expect(session.messages.some((message) => message.role === "user" &&
				message.content.some((part) => part.type === "text"))).toBe(false);
		} finally {
			session.dispose();
		}
	});
});
