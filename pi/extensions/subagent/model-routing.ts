import type { ModelThinkingLevel } from "@earendil-works/pi-ai";
import type { AgentConfig } from "./agents.js";
import {
	formatModelBinding,
	parseModelReference,
	resolveModelRoute,
	routingErrorMessage,
	type ModelBinding,
	type ModelRoutingPolicy,
	type Result,
	type RoutingDecision,
} from "../model-routing/policy.js";

export type SubagentRoutingSnapshot = Readonly<{
	policy: ModelRoutingPolicy;
	policyDigest: string;
	parent?: ModelBinding;
}>;

export type RoutingAudit = Readonly<{
	decision: "declared" | "override";
	declared?: string;
	effective?: string;
	parentClass?: string;
	ruleId?: string;
	policyDigest: string;
}>;

export type ResolvedSubagentRoute = Readonly<{
	decision: RoutingDecision;
	args: readonly string[];
	audit: RoutingAudit;
}>;

export function parentBinding(
	model: Readonly<{ provider: string; id: string }> | undefined,
	thinkingLevel: ModelThinkingLevel | undefined,
): ModelBinding | undefined {
	if (!model) return undefined;
	const parsed = parseModelReference(`${model.provider}/${model.id}`);
	if (!parsed.ok) return undefined;
	return Object.freeze({
		model: parsed.value,
		...(thinkingLevel ? { thinkingLevel } : {}),
	});
}

export function bindingArguments(binding: ModelBinding | undefined): readonly string[] {
	if (!binding) return [];
	return Object.freeze([
		"--model",
		`${binding.model.provider}/${binding.model.id}`,
		...(binding.thinkingLevel ? ["--thinking", binding.thinkingLevel] : []),
	]);
}

export function resolveSubagentRoute(
	snapshot: SubagentRoutingSnapshot,
	agent: Pick<AgentConfig, "name" | "model" | "modelProfile">,
): Result<ResolvedSubagentRoute, string> {
	// Agent model declarations are Pi CLI expressions, not policy model bindings.
	// Keep them opaque so bare aliases and model IDs containing ':' retain Pi's
	// catalog-aware resolution semantics. Local/named overrides are exact policy
	// bindings and never depend on parsing the declaration.
	const routed = resolveModelRoute(
		snapshot.policy,
		{
			parent: snapshot.parent,
			workload: "subagent",
			profile: agent.modelProfile,
			agent: agent.name,
		},
		snapshot.policyDigest,
	);
	if (!routed.ok) return { ok: false, error: routingErrorMessage(routed.error) };
	const decision = routed.value;
	const usesDeclaration = decision.kind === "declared";
	const args = usesDeclaration
		? Object.freeze(agent.model ? ["--model", agent.model] : [])
		: bindingArguments(decision.effective);
	const effective = usesDeclaration
		? agent.model
		: decision.effective
			? formatModelBinding(decision.effective)
			: undefined;
	return {
		ok: true,
		value: Object.freeze({
			decision,
			args,
			audit: Object.freeze({
				decision: decision.kind,
				declared: agent.model,
				effective,
				parentClass: decision.parentClass,
				ruleId: decision.ruleId,
				policyDigest: decision.policyDigest,
			}),
		}),
	};
}
