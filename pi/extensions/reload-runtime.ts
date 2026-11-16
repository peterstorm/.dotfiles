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

/** A pending marker older than this is stale (crashed run, forked session) and is never consumed. */
const PENDING_FRESH_MS = 60_000;

type SessionEntryShape = Readonly<{ type: string; customType?: string; data?: unknown }>;

/** Pure: the newest auto-continue marker decides whether the reloaded runtime resumes the task. */
export const shouldReloadAutoContinue = (entries: readonly SessionEntryShape[], now: number): boolean => {
	for (let i = entries.length - 1; i >= 0; i--) {
		const entry = entries[i];
		if (entry.type !== "custom" || entry.customType !== RELOAD_CONTINUE_CUSTOM_TYPE) continue;
		const data = entry.data;
		if (typeof data !== "object" || data === null) return false;
		const { kind, ts } = data as Record<string, unknown>;
		return kind === "pending" && typeof ts === "number" && now - ts <= PENDING_FRESH_MS;
	}
	return false;
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
			// channel that outlives this extension instance. Shapes: {kind: "pending"|"consumed", ts}.
			pi.appendEntry(RELOAD_CONTINUE_CUSTOM_TYPE, { kind: "pending", ts: Date.now() });
			pi.sendUserMessage("/reload-runtime", { deliverAs: "followUp", executeCommandAfterIdle: true });
			return {
				content: [{ type: "text", text: "Reload queued. Pi reloads after this response, then auto-continues the task." }],
				details: {},
			};
		},
	});

	// Runs on the reloaded instance: consume a pending marker exactly once, then
	// resume the interrupted task with a normal user turn.
	pi.on("session_start", (event, ctx) => {
		if (event.reason !== "reload") return;
		if (!shouldReloadAutoContinue(ctx.sessionManager.getEntries(), Date.now())) return;
		pi.appendEntry(RELOAD_CONTINUE_CUSTOM_TYPE, { kind: "consumed", ts: Date.now() });
		pi.sendUserMessage(RELOAD_CONTINUE_MESSAGE);
	});
}
