// The /switch shell: the registered handler against a stub Pi API and context,
// with a live HTTP stub as desktop-vllm's /v1/models. Covers what switch.test.ts
// (the pure flow over fakes) cannot: the idle wait, and every port's error arm.
import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ExtensionAPI, ExtensionCommandContext } from "@earendil-works/pi-coding-agent";
import primarySwitchExtension from "./index";

const GLM = "glm-5.3-flash-hyperflare-tp2-v16";
const REPORT = `switching: warmind -> glm\nPRIMARY: glm (${GLM} on :8000)\npi:      pi --model desktop-vllm/${GLM}\n`;

type ExecResult = Readonly<{ stdout: string; stderr: string; code: number; killed: boolean; truncated: boolean }>;
type Handler = (args: string, ctx: ExtensionCommandContext) => Promise<void>;

let dir = "";
let server: { port: number; stop: (force?: boolean) => void } | undefined;
const servedIds: string[] = [];

beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "primary-switch-"));
	writeFileSync(join(dir, "switch-primary.sh"), "#!/usr/bin/env bash\n");
	process.env.PI_SWITCH_PRIMARY_SCRIPT = join(dir, "switch-primary.sh");
	servedIds.splice(0, servedIds.length, GLM);
	server = Bun.serve({
		port: 0,
		hostname: "127.0.0.1",
		fetch: () => Response.json({ object: "list", data: [{ id: servedIds[0], object: "model" }] }),
	});
});

afterEach(() => {
	server?.stop(true);
	rmSync(dir, { recursive: true, force: true });
	delete process.env.PI_SWITCH_PRIMARY_SCRIPT;
});

/** Register the extension against a stub API and return its handler plus a call log. */
function harness(options: Readonly<{
	exec?: (args: readonly string[]) => Promise<ExecResult>;
	setModel?: () => Promise<boolean>;
	/** How many catalog lookups succeed before find stops returning the model. */
	catalogHits?: number;
	idle?: boolean;
}> = {}) {
	const log: string[] = [];
	const notices: Array<Readonly<{ message: string; type?: string }>> = [];
	let handler: Handler | undefined;
	let lookups = 0;
	const pi = {
		registerCommand: (name: string, command: { handler: Handler }) => {
			if (name === "switch") handler = command.handler;
		},
		exec: async (_command: string, args: string[]) => {
			log.push(`exec:${args[1]}`);
			return options.exec
				? options.exec(args)
				: { stdout: REPORT, stderr: "", code: 0, killed: false, truncated: false };
		},
		setModel: async (model: { id: string }) => {
			log.push(`setModel:${model.id}`);
			return options.setModel ? options.setModel() : true;
		},
	};
	const ctx = {
		isIdle: () => options.idle ?? true,
		waitForIdle: async () => {
			log.push("waitForIdle");
		},
		ui: {
			notify: (message: string, type?: string) => notices.push({ message, type }),
			setStatus: () => {},
		},
		modelRegistry: {
			getAll: () => [{ provider: "desktop-vllm", baseUrl: `http://127.0.0.1:${server?.port}/v1` }],
			find: (provider: string, id: string) =>
				provider === "desktop-vllm" && ++lookups <= (options.catalogHits ?? Infinity) ? { provider, id } : undefined,
			getApiKeyForProvider: async () => "key",
		},
	};
	primarySwitchExtension(pi as unknown as ExtensionAPI);
	if (!handler) throw new Error("/switch was not registered");
	const run = (args: string) => handler!(args, ctx as unknown as ExtensionCommandContext);
	return { run, log, notices };
}

describe("/switch handler", () => {
	it("waits for a busy session before switching, then moves it onto the served model", async () => {
		const { run, log, notices } = harness({ idle: false });
		await run("glm");
		expect(log).toEqual(["waitForIdle", "exec:glm", `setModel:${GLM}`]);
		expect(notices.at(-1)).toEqual({
			message: `Primary: glm (served after 0 s). This session now uses desktop-vllm/${GLM}.`,
			type: "info",
		});
	});

	it("reads status without waiting for a busy session or touching the model", async () => {
		const { run, log, notices } = harness({
			idle: false,
			exec: async () => ({ stdout: "active:     glm\n", stderr: "", code: 0, killed: false, truncated: false }),
		});
		await run("status");
		expect(log).toEqual(["exec:status"]);
		expect(notices).toEqual([{ message: "active:     glm", type: "info" }]);
	});

	it("refuses an unknown argument without running anything", async () => {
		const { run, log, notices } = harness();
		await run("qwen");
		expect(log).toEqual([]);
		expect(notices[0]?.type).toBe("error");
		expect(notices[0]?.message).toContain("usage: /switch");
	});

	it("reports a missing script as a script failure", async () => {
		process.env.PI_SWITCH_PRIMARY_SCRIPT = join(dir, "absent.sh");
		const { run, log, notices } = harness();
		await run("glm");
		expect(log).toEqual([]);
		expect(notices.at(-1)?.message).toContain("/switch failed (script): switch-primary.sh exited 127");
		expect(notices.at(-1)?.message).toContain("absent.sh does not exist");
	});

	it("turns a throwing exec into a script failure, not an exception", async () => {
		const { run, notices } = harness({ exec: async () => { throw new Error("spawn bash ENOENT"); } });
		await run("glm");
		expect(notices.at(-1)?.message).toContain("/switch failed (script)");
		expect(notices.at(-1)?.message).toContain("spawn bash ENOENT");
	});

	it("reports each model-selection failure and leaves the session alone", async () => {
		const cases: ReadonlyArray<readonly [Parameters<typeof harness>[0], string]> = [
			// The probe saw it in the catalog (lookup 1); by selection it was gone.
			[{ catalogHits: 1 }, `desktop-vllm/${GLM} is served but missing from pi/models.json`],
			[{ setModel: async () => false }, "no credentials for desktop-vllm"],
			[{ setModel: async () => { throw new Error("model locked"); } }, "model locked"],
		];
		for (const [options, reason] of cases) {
			const { run, notices } = harness(options);
			await run("glm");
			expect(notices.at(-1)?.type).toBe("error");
			expect(notices.at(-1)?.message).toContain("/switch failed (model)");
			expect(notices.at(-1)?.message).toContain(reason);
		}
	});
});
