import { existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import { errorMessage, probeServedModels, servedModelSourceFromRegistry } from "../model-routing/served.js";
import {
	PRIMARY_PROVIDER as PROVIDER,
	parseSwitchRequest,
	runPrimarySwitch,
	switchCompletions,
	type ScriptRun,
	type SwitchOutcome,
	type SwitchPorts,
} from "./switch.js";

const STATUS_KEY = "primary-switch";
/** Generous: a ds41 cold start plus the idle gate and a rollback can take many minutes. */
const SCRIPT_TIMEOUT_MS = 40 * 60_000;

/** The repo always lives at ~/.dotfiles (switch-primary.sh re-runs itself there over ssh). */
const switchScript = (): string =>
	process.env.PI_SWITCH_PRIMARY_SCRIPT ?? join(homedir(), ".dotfiles/scripts/inference/switch-primary.sh");

function ports(pi: ExtensionAPI, ctx: ExtensionCommandContext): SwitchPorts {
	const script = switchScript();
	const source = servedModelSourceFromRegistry(ctx.modelRegistry);
	const wired: SwitchPorts = {
		runScript: async (request): Promise<ScriptRun> => {
			if (!existsSync(script)) return { code: 127, stdout: "", stderr: `${script} does not exist`, killed: false };
			try {
				const run = await pi.exec("bash", [script, request], { timeout: SCRIPT_TIMEOUT_MS, cwd: homedir() });
				return { code: run.code, stdout: run.stdout, stderr: run.stderr, killed: run.killed };
			} catch (error) {
				return { code: 1, stdout: "", stderr: `cannot run ${script}: ${errorMessage(error)}`, killed: false };
			}
		},
		probeServed: async () => {
			const entry = (await probeServedModels([PROVIDER], source))[PROVIDER];
			if (!entry) return { ok: false, error: `${PROVIDER} was not probed` };
			return entry.ok ? { ok: true, value: entry.value.id } : entry;
		},
		selectModel: async (servedId) => {
			const model = ctx.modelRegistry.find(PROVIDER, servedId);
			if (!model) return { ok: false, error: `${PROVIDER}/${servedId} is served but missing from pi/models.json` };
			try {
				if (!(await pi.setModel(model))) return { ok: false, error: `no credentials for ${PROVIDER}` };
			} catch (error) {
				return { ok: false, error: `cannot select ${PROVIDER}/${servedId}: ${errorMessage(error)}` };
			}
			return { ok: true, value: `${PROVIDER}/${servedId}` };
		},
		sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
		now: () => Date.now(),
		progress: (text) => ctx.ui.setStatus(STATUS_KEY, text),
	};
	return Object.freeze(wired);
}

function render(outcome: SwitchOutcome, ctx: ExtensionCommandContext): void {
	switch (outcome.kind) {
		case "status":
			ctx.ui.notify(outcome.text, "info");
			return;
		case "switched": {
			const how = outcome.unchanged ? "already the primary" : `served after ${Math.round(outcome.waitedMs / 1000)} s`;
			ctx.ui.notify(`Primary: ${outcome.primary} (${how}). This session now uses ${outcome.model}.`, "info");
			return;
		}
		case "failed":
			ctx.ui.notify(`/switch failed (${outcome.stage}): ${outcome.message}`, "error");
			return;
		default:
			return assertNever(outcome);
	}
}

const assertNever = (value: never): never => {
	throw new Error(`unreachable: ${JSON.stringify(value)}`);
};

export default function primarySwitchExtension(pi: ExtensionAPI) {
	pi.registerCommand("switch", {
		description: "Switch desktop's primary model (toggle|glm|warmind|deepseek|status) and move this session onto it",
		getArgumentCompletions: (prefix) => [...switchCompletions(prefix)],
		handler: async (args, ctx) => {
			const request = parseSwitchRequest(args);
			if (!request.ok) {
				ctx.ui.notify(request.error, "error");
				return;
			}
			// The cutover is idle-gated on the server: a turn of this session still
			// streaming would block it (or be cut off by it), so let it finish first.
			if (request.value !== "status" && !ctx.isIdle()) {
				ctx.ui.notify("/switch waits for the current turn to finish", "info");
				await ctx.waitForIdle();
			}
			render(await runPrimarySwitch(request.value, ports(pi, ctx)), ctx);
		},
	});
}
