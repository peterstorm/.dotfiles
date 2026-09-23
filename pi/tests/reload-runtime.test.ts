import { describe, expect, it } from "bun:test";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import reloadRuntime from "../extensions/reload-runtime";

describe("reload runtime extension", () => {
	it("queues the command as a follow-up, then reloads the parent session", async () => {
		let command: Parameters<ExtensionAPI["registerCommand"]>[1] | undefined;
		let tool: Parameters<ExtensionAPI["registerTool"]>[0] | undefined;
		const messages: Array<{ text: string; deliverAs: string | undefined }> = [];
		const api = {
			registerCommand(name: string, definition: typeof command) {
				expect(name).toBe("reload-runtime");
				command = definition;
			},
			registerTool(definition: typeof tool) {
				tool = definition;
			},
			sendUserMessage(text: string, options: { deliverAs?: string }) {
				messages.push({ text, deliverAs: options.deliverAs });
			},
		} as unknown as ExtensionAPI;

		reloadRuntime(api);
		expect(tool?.name).toBe("reload_runtime");
		if (!tool || !command) throw new Error("Reload command and tool must be registered");

		const outcome = await tool.execute("call-id", {}, undefined, undefined, {} as ExtensionContext);
		expect(outcome.content[0]).toEqual({ type: "text", text: "Queued /reload-runtime as a follow-up command." });
		expect(messages).toEqual([{ text: "/reload-runtime", deliverAs: "followUp" }]);

		let reloads = 0;
		await command.handler("", { reload: async () => { reloads++; } } as ExtensionCommandContext);
		expect(reloads).toBe(1);
	});
});
