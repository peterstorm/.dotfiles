import { describe, expect, it } from "bun:test";
import type { ExtensionAPI, ExtensionCommandContext, ExtensionContext } from "@earendil-works/pi-coding-agent";
import reloadRuntime, {
	RELOAD_CONTINUE_CUSTOM_TYPE,
	RELOAD_CONTINUE_MESSAGE,
	parseReloadContinueMarker,
	reloadContinueMarker,
	shouldReloadAutoContinue,
} from "../extensions/reload-runtime";

type SentMessage = { text: string; deliverAs?: string; executeCommandAfterIdle?: boolean };
type AppendedEntry = { customType: string; data: unknown };

// Minimal ExtensionAPI double capturing what reload-runtime registers and emits.
const harness = () => {
	const sent: SentMessage[] = [];
	const appended: AppendedEntry[] = [];
	let command: Parameters<ExtensionAPI["registerCommand"]>[1] | undefined;
	let tool: Parameters<ExtensionAPI["registerTool"]>[0] | undefined;
	let sessionStart: ((event: { reason: string }, ctx: ExtensionContext) => void) | undefined;
	const api = {
		registerCommand(name: string, definition: typeof command) {
			expect(name).toBe("reload-runtime");
			command = definition;
		},
		registerTool(definition: typeof tool) {
			tool = definition;
		},
		on(event: string, handler: (event: { reason: string }, ctx: ExtensionContext) => void) {
			if (event === "session_start") sessionStart = handler;
		},
		sendUserMessage(text: string, options: { deliverAs?: string; executeCommandAfterIdle?: boolean } = {}) {
			sent.push({ text, deliverAs: options.deliverAs, executeCommandAfterIdle: options.executeCommandAfterIdle });
		},
		appendEntry(customType: string, data: unknown) {
			appended.push({ customType, data });
		},
	} as unknown as ExtensionAPI;
	reloadRuntime(api);
	if (!tool || !command || !sessionStart) throw new Error("extension must register command, tool and session_start handler");
	return { sent, appended, command, tool, sessionStart };
};

const entry = (kind: "pending" | "consumed", ts: number, customType = RELOAD_CONTINUE_CUSTOM_TYPE) => ({
	type: "custom",
	customType,
	data: { kind, ts },
});

describe("reload runtime extension", () => {
	it("journals a pending marker, queues the command as a follow-up, then reloads the parent session", async () => {
		const h = harness();
		const outcome = await h.tool.execute("call-id", {}, undefined, undefined, {} as ExtensionContext);
		expect(outcome.content[0]).toEqual({
			type: "text",
			text: "Reload queued. Pi reloads after this response, then auto-continues the task.",
		});
		// The marker lands before the deferred command: it must survive the reload it triggers.
		expect(h.appended).toEqual([{ customType: RELOAD_CONTINUE_CUSTOM_TYPE, data: { kind: "pending", ts: expect.any(Number) } }]);
		expect(h.sent).toEqual([{ text: "/reload-runtime", deliverAs: "followUp", executeCommandAfterIdle: true }]);

		let reloads = 0;
		await h.command.handler("", { reload: async () => { reloads++; } } as ExtensionCommandContext);
		expect(reloads).toBe(1);
	});

	it("consumes a pending marker on reload, sending the continuation before the consumed twin", () => {
		const h = harness();
		h.sessionStart({ reason: "reload" }, {
			sessionManager: { getEntries: () => [entry("pending", Date.now() - 1_000)] },
		} as unknown as ExtensionContext);
		expect(h.sent).toEqual([{ text: RELOAD_CONTINUE_MESSAGE, deliverAs: undefined, executeCommandAfterIdle: undefined }]);
		expect(h.appended).toEqual([
			{ customType: RELOAD_CONTINUE_CUSTOM_TYPE, data: { kind: "consumed", ts: expect.any(Number) } },
		]);
	});

	it("ignores startup session_start events", () => {
		const h = harness();
		h.sessionStart({ reason: "startup" }, {
			sessionManager: { getEntries: () => [entry("pending", Date.now())] },
		} as unknown as ExtensionContext);
		expect(h.appended).toEqual([]);
		expect(h.sent).toEqual([]);
	});

	it("stays idle on a manual reload after the continuation was already delivered", () => {
		const h = harness();
		const now = Date.now();
		h.sessionStart({ reason: "reload" }, {
			sessionManager: { getEntries: () => [entry("pending", now - 2_000), entry("consumed", now - 1_000)] },
		} as unknown as ExtensionContext);
		expect(h.appended).toEqual([]);
		expect(h.sent).toEqual([]);
	});
});

describe("shouldReloadAutoContinue", () => {
	const now = Date.now();
	const other = { type: "custom", customType: "unrelated", data: { kind: "pending", ts: now } };

	it("consumes a fresh pending marker", () => {
		expect(shouldReloadAutoContinue([entry("pending", now - 1_000)])).toBe(true);
	});

	it("consumes a pending marker of any age: the reload that lands is the one it asked for", () => {
		expect(shouldReloadAutoContinue([entry("pending", now - 3_600_000)])).toBe(true);
	});

	it("skips a consumed marker (continue already delivered)", () => {
		expect(shouldReloadAutoContinue([entry("pending", now - 2_000), entry("consumed", now - 1_000)])).toBe(false);
	});

	it("only the newest marker decides", () => {
		expect(shouldReloadAutoContinue([entry("consumed", now - 3_000), other, entry("pending", now - 1_000)])).toBe(true);
		expect(shouldReloadAutoContinue([entry("pending", now - 3_000), other, entry("consumed", now - 1_000)])).toBe(false);
	});

	it("is false with no markers and parses malformed journal data defensively", () => {
		expect(shouldReloadAutoContinue([])).toBe(false);
		expect(shouldReloadAutoContinue([{ type: "custom", customType: RELOAD_CONTINUE_CUSTOM_TYPE, data: "garbage" }])).toBe(false);
		expect(shouldReloadAutoContinue([{ type: "custom", customType: RELOAD_CONTINUE_CUSTOM_TYPE }])).toBe(false);
		expect(shouldReloadAutoContinue([entry("pending", now - 1_000, "other-type")])).toBe(false);
	});
});

describe("marker codec", () => {
	it("round-trips through the named constructor and parser", () => {
		expect(parseReloadContinueMarker(reloadContinueMarker("pending"))?.kind).toBe("pending");
		expect(parseReloadContinueMarker(reloadContinueMarker("consumed"))?.kind).toBe("consumed");
	});

	it("rejects malformed journal data", () => {
		expect(parseReloadContinueMarker("garbage")).toBeUndefined();
		expect(parseReloadContinueMarker(null)).toBeUndefined();
		expect(parseReloadContinueMarker({ kind: "other", ts: 5 })).toBeUndefined();
		expect(parseReloadContinueMarker({ kind: "pending" })).toBeUndefined();
		expect(parseReloadContinueMarker({ kind: "pending", ts: "5" })).toBeUndefined();
		expect(parseReloadContinueMarker({ kind: "pending", ts: Number.NaN })).toBeUndefined();
	});
});
