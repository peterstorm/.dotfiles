export const LOOM_SUBAGENT_LAUNCH_CHANNEL = "loom:subagent-launch:v2" as const;
export const LOOM_EMISSION_BINDING_ENV = "LOOM_EMISSION_BINDING" as const;
export const LOOM_EMISSION_DESCRIPTOR_MARKER = "LOOM_EMISSION_DESCRIPTOR:" as const;
export const LOOM_EMISSION_READINESS_COMMAND = "loom-emission-readiness" as const;

export type SubagentLaunchSlot =
	| Readonly<{ kind: "single"; index: 0 }>
	| Readonly<{ kind: "parallel"; index: number }>
	| Readonly<{ kind: "chain"; index: number }>;

export type EffectiveModel = Readonly<{
	provider: string;
	id: string;
}>;

export type ReadinessCommand = Readonly<{
	name: string;
	description?: string;
	source?: string;
	path?: string;
}>;

export type ReadinessState = Readonly<{
	model: null | Readonly<{ provider?: string; id?: string; [key: string]: unknown }>;
	[key: string]: unknown;
}>;

/**
 * Narrow RPC capability exposed to the directive-owned readiness verifier.
 * invokeReadiness invokes the fixed /loom-emission-readiness command and waits
 * for its bounded loom-emission-readiness entry_appended evidence. The verifier
 * then selects and observes the expected route; the launcher independently
 * checks that exact post-readiness sequence before delivering the task.
 */
export type ReadinessClient = Readonly<{
	getCommands: () => Promise<readonly ReadinessCommand[]>;
	invokeReadiness: () => Promise<readonly unknown[]>;
	setModel: (provider: string, modelId: string) => Promise<void>;
	getState: () => Promise<ReadinessState>;
}>;

export type ReadinessVerdict =
	| Readonly<{ ok: true }>
	| Readonly<{ ok: false; reason: string }>;

export type EmissionRpcDirective = Readonly<{
	kind: "emission-rpc";
	bindingEnv: string;
	expectedProvider: string;
	expectedModel: string;
	expectedToolName: string;
	verifyReadiness: (client: ReadinessClient) => Promise<ReadinessVerdict>;
}>;

export type SubagentLaunchReply =
	| Readonly<{ kind: "not-admitted" }>
	| Readonly<{ kind: "refused"; reason: string }>
	| Readonly<{ kind: "emission-rpc"; directive: EmissionRpcDirective }>;

/** The bus is synchronous. The launcher owns a one-shot responder; no listener
 * may mutate the request or issue a late/second launch directive. */
export type SubagentLaunchResolveRequest = Readonly<{
	kind: "resolve";
	sessionId: string;
	toolCallId: string;
	slot: SubagentLaunchSlot;
	agent: string;
	task: string;
	cwd: string;
	effectiveModel: EffectiveModel;
	respond: (reply: Exclude<SubagentLaunchReply, { kind: "not-admitted" }>) => void;
}>;

export type SubagentLaunchCapabilityProbe = Readonly<{
	kind: "capability";
	version: 2;
	respond: (reply: Readonly<{ kind: "available"; version: 2 }>) => void;
}>;

export type SubagentLaunchPortEvent = SubagentLaunchCapabilityProbe | SubagentLaunchResolveRequest;

export type SubagentLaunchEventBus = Readonly<{
	emit: (channel: string, data: unknown) => void;
	on?: (channel: string, handler: (data: unknown) => void) => () => void;
}>;

function isCapabilityProbe(value: unknown): value is SubagentLaunchCapabilityProbe {
	if (typeof value !== "object" || value === null || Array.isArray(value)) return false;
	const candidate = value as Record<string, unknown>;
	return candidate.kind === "capability" && candidate.version === 2 && typeof candidate.respond === "function";
}

/** Advertise this launcher to a future Loom extension through Pi's synchronous event bus. */
export function advertiseSubagentLaunchPort(events: Required<Pick<SubagentLaunchEventBus, "on">>): () => void {
	return events.on(LOOM_SUBAGENT_LAUNCH_CHANNEL, (event) => {
		if (isCapabilityProbe(event)) event.respond(Object.freeze({ kind: "available", version: 2 }));
	});
}
