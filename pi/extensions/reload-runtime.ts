import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// Tools cannot access ExtensionCommandContext. The pinned Pi package's
// executeCommandAfterIdle option waits for the parent turn to settle and
// dispatches this extension command without sending slash text to the model.
//
// A reload replaces this extension instance (the old runner is invalidated
// after ctx.reload()), so the auto-continue signal crosses the reload through
// the session journal: the tool appends a "pending" marker entry, and the
// reloaded instance's session_start handler consumes it exactly once and
// prompts the agent to resume — the reload-side twin of compaction's
// "[auto-compacted]" nudge. A manual /reload finds only the "consumed"
// marker and stays idle.

export const RELOAD_CONTINUE_CUSTOM_TYPE = "reload-runtime-auto-continue";
export const RELOAD_CONTINUE_MESSAGE = "[runtime-reloaded] Continue from where you left off.";

/** The journal marker: the only channel that outlives this extension instance. */
export type ReloadContinueMarker =
	| Readonly<{ kind: "pending"; ts: number }>
	| Readonly<{ kind: "consumed"; ts: number }>;

type SessionEntryShape = Readonly<{ type: string; customType?: string; data?: unknown }>;

/** Total parse of journal data into a marker, or undefined when the data is not one. */
export const parseReloadContinueMarker = (data: unknown): ReloadContinueMarker | undefined => {
	if (typeof data !== "object" || data === null) return undefined;
	const { kind, ts } = data as Record<string, unknown>;
	if ((kind !== "pending" && kind !== "consumed") || typeof ts !== "number" || !Number.isFinite(ts)) return undefined;
	return kind === "pending" ? { kind: "pending", ts } : { kind: "consumed", ts };
};

/** The marker to journal for a protocol step. */
export const reloadContinueMarker = (kind: "pending" | "consumed"): ReloadContinueMarker =>
	kind === "pending" ? { kind: "pending", ts: Date.now() } : { kind: "consumed", ts: Date.now() };

/**
 * Pure: the newest auto-continue marker decides whether the reloaded runtime resumes the task.
 * A session_start with reason "reload" is itself the reload a pending marker asked for — the
 * deferred dispatch fires after the whole calling run settles, however long its tail — and a
 * crashed run or fork re-enters the session with a different session_start reason, so no
 * wall-clock freshness gate is needed: any pending marker is consumed on the first reload.
 */
export const shouldReloadAutoContinue = (entries: readonly SessionEntryShape[]): boolean => {
	const marker = parseReloadContinueMarker(
		entries.findLast((entry) => entry.type === "custom" && entry.customType === RELOAD_CONTINUE_CUSTOM_TYPE)?.data,
	);
	return marker?.kind === "pending";
};

export default function (pi: ExtensionAPI) {
	pi.registerCommand("reload-runtime", {
		description: "Reload extensions, skills, prompts, themes, and context files",
		handler: async (_args, ctx) => {
			await ctx.reload();
			return;
		},
	});

	pi.registerTool({
		name: "reload_runtime",
		label: "Reload Runtime",
		description:
			"Reload extensions, skills, prompts, themes, and context files. Pi reloads after this response and automatically continues the current task.",
		parameters: Type.Object({}),
		async execute() {
			// The marker must be in the journal before the reload starts: it is the only
			// channel that outlives this extension instance.
			pi.appendEntry(RELOAD_CONTINUE_CUSTOM_TYPE, reloadContinueMarker("pending"));
			pi.sendUserMessage("/reload-runtime", { deliverAs: "followUp", executeCommandAfterIdle: true });
			return {
				content: [{ type: "text", text: "Reload queued. Pi reloads after this response, then auto-continues the task." }],
				details: {},
			};
		},
	});

	// Runs on the reloaded instance: consume a pending marker exactly once, then
	// resume the interrupted task. The continuation is queued before the consumed
	// twin is journaled, so the marker never records a turn that was not started.
	pi.on("session_start", (event, ctx) => {
		if (event.reason !== "reload") return;
		if (!shouldReloadAutoContinue(ctx.sessionManager.getEntries())) return;
		pi.sendUserMessage(RELOAD_CONTINUE_MESSAGE);
		pi.appendEntry(RELOAD_CONTINUE_CUSTOM_TYPE, reloadContinueMarker("consumed"));
	});
}
