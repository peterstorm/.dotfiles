import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { parseModelRoutingPolicy, type ModelRoutingPolicy, type Result } from "./policy.js";

export type LoadedModelRoutingPolicy = Readonly<{
	policy: ModelRoutingPolicy;
	digest: string;
	path: string;
}>;

export type PolicyLoadError = Readonly<{
	path: string;
	message: string;
}>;

function defaultAgentDir(): string {
	const configured = process.env.PI_CODING_AGENT_DIR;
	if (!configured) return join(homedir(), ".pi", "agent");
	return configured === "~"
		? homedir()
		: configured.startsWith("~/")
			? join(homedir(), configured.slice(2))
			: configured;
}

export function loadModelRoutingPolicy(
	agentDir: string = defaultAgentDir(),
): Result<LoadedModelRoutingPolicy, PolicyLoadError> {
	const path = join(agentDir, "model-routing.json");
	try {
		const source = readFileSync(path, "utf-8");
		const parsedJson: unknown = JSON.parse(source);
		const parsed = parseModelRoutingPolicy(parsedJson);
		if (!parsed.ok) {
			return {
				ok: false,
				error: { path, message: parsed.error.map((error) => `  - ${error}`).join("\n") },
			};
		}
		return {
			ok: true,
			value: Object.freeze({
				policy: parsed.value,
				digest: createHash("sha256").update(source).digest("hex"),
				path,
			}),
		};
	} catch (error) {
		return {
			ok: false,
			error: {
				path,
				message: error instanceof Error ? error.message : String(error),
			},
		};
	}
}
