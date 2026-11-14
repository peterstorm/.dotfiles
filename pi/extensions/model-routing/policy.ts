import type { ModelThinkingLevel } from "@earendil-works/pi-ai";

const THINKING_LEVELS = ["off", "minimal", "low", "medium", "high", "xhigh", "max"] as const;
const MODEL_PATTERN = /^[^/\s]+\/(?:\*|[^\s*]+)$/;
const MODEL_REFERENCE = /^[^/\s]+\/[^\s*]+$/;
const PROVIDER = /^[^/\s*]+$/;

export type Result<T, E> =
	| Readonly<{ ok: true; value: T }>
	| Readonly<{ ok: false; error: E }>;

const MODEL_REFERENCE_BRAND: unique symbol = Symbol("ModelReference");

export type ModelReference = Readonly<{
	provider: string;
	id: string;
	readonly [MODEL_REFERENCE_BRAND]: true;
}>;

export type ModelBinding = Readonly<{
	model: ModelReference;
	thinkingLevel?: ModelThinkingLevel;
}>;

/** A fixed model: always this provider/id. */
export type ExactTarget = Readonly<{
	kind: "exact";
	model: ModelReference;
	thinkingLevel?: ModelThinkingLevel;
}>;

/**
 * Whatever model `provider` serves right now. The policy cannot know that; the
 * shell probes the provider once per routing snapshot and passes the answer in
 * `RoutingRequest.served`. Without a pinned thinking level the parent's carries over.
 */
export type ServedTarget = Readonly<{
	kind: "served";
	provider: string;
	thinkingLevel?: ModelThinkingLevel;
}>;

export type PolicyTarget = ExactTarget | ServedTarget;

export type RuleSelector = Readonly<{
	parentClass?: string;
	parentModel?: string;
	workload?: string;
	profile?: string;
	agent?: string;
}>;

export type RuleTarget =
	| Readonly<{ kind: "declared" }>
	| Readonly<{ kind: "parent" }>
	| Readonly<{ kind: "named"; target: string }>;

export type RoutingRule = Readonly<{
	id: string;
	when: RuleSelector;
	use: RuleTarget;
	specificity: number;
}>;

export type ModelRoutingPolicy = Readonly<{
	schemaVersion: 1;
	defaultClass: string;
	modelClasses: Readonly<Record<string, readonly string[]>>;
	targets: Readonly<Record<string, PolicyTarget>>;
	rules: readonly RoutingRule[];
}>;

export type PolicyParseResult = Result<ModelRoutingPolicy, readonly string[]>;

export type RoutingRequest = Readonly<{
	parent?: ModelBinding;
	declared?: ModelBinding;
	workload: string;
	profile?: string;
	agent?: string;
	/** provider -> the model it serves now, as probed by the shell (see servedProviders). */
	served?: Readonly<Record<string, ModelReference>>;
}>;

type RoutingDecisionBase = Readonly<{
	declared?: ModelBinding;
	parentClass?: string;
	ruleId?: string;
	policyDigest: string;
}>;

export type RoutingDecision =
	| Readonly<RoutingDecisionBase & { kind: "declared"; effective?: ModelBinding }>
	| Readonly<RoutingDecisionBase & { kind: "override"; effective: ModelBinding }>;

export type RoutingError =
	| Readonly<{ kind: "ambiguous-model-class"; model: string; classes: readonly string[] }>
	| Readonly<{ kind: "ambiguous-rule"; ruleIds: readonly string[] }>
	| Readonly<{ kind: "parent-unavailable"; ruleId: string }>
	| Readonly<{ kind: "served-model-unknown"; ruleId: string; provider: string }>;

const isRecord = (value: unknown): value is Record<string, unknown> =>
	typeof value === "object" && value !== null && !Array.isArray(value);

const isThinkingLevel = (value: unknown): value is ModelThinkingLevel =>
	typeof value === "string" && (THINKING_LEVELS as readonly string[]).includes(value);

export const canonicalModel = ({ provider, id }: ModelReference): string => `${provider}/${id}`;

export function formatModelBinding(binding: ModelBinding): string {
	const model = canonicalModel(binding.model);
	return binding.thinkingLevel ? `${model}:${binding.thinkingLevel}` : model;
}

export function parseModelReference(raw: string): Result<ModelReference, string> {
	if (!MODEL_REFERENCE.test(raw)) return { ok: false, error: `invalid model reference ${JSON.stringify(raw)}` };
	const separator = raw.indexOf("/");
	return {
		ok: true,
		value: Object.freeze({
			provider: raw.slice(0, separator),
			id: raw.slice(separator + 1),
			[MODEL_REFERENCE_BRAND]: true as const,
		}),
	};
}

export function parseModelBinding(raw: string): Result<ModelBinding, string> {
	const match = raw.match(/^([^/\s]+)\/((?!\*)[^\s:]+)(?::(off|minimal|low|medium|high|xhigh|max))?$/);
	if (!match) return { ok: false, error: `invalid model binding ${JSON.stringify(raw)}` };
	const model = parseModelReference(`${match[1]}/${match[2]}`);
	if (!model.ok) return model;
	return {
		ok: true,
		value: Object.freeze({
			model: model.value,
			...(match[3] ? { thinkingLevel: match[3] as ModelThinkingLevel } : {}),
		}),
	};
}

function matchesModel(pattern: string, model: ModelReference): boolean {
	return pattern.endsWith("/*")
		? model.provider === pattern.slice(0, -2)
		: canonicalModel(model) === pattern;
}

function modelPatternsOverlap(first: string, second: string): boolean {
	const firstWildcard = first.endsWith("/*");
	const secondWildcard = second.endsWith("/*");
	if (!firstWildcard && !secondWildcard) return first === second;
	const firstProvider = first.slice(0, first.indexOf("/"));
	const secondProvider = second.slice(0, second.indexOf("/"));
	return firstProvider === secondProvider;
}

function unknownFields(record: Record<string, unknown>, allowed: readonly string[], path: string): string[] {
	const known = new Set(allowed);
	return Object.keys(record)
		.filter((key) => !known.has(key))
		.map((key) => `${path} contains unknown field ${key}`);
}

function parseSelector(raw: unknown, path: string, errors: string[]): RuleSelector | undefined {
	if (!isRecord(raw)) {
		errors.push(`${path} must be an object`);
		return undefined;
	}
	errors.push(...unknownFields(raw, ["parentClass", "parentModel", "workload", "profile", "agent"], path));
	const parsed: Record<string, string> = {};
	for (const field of ["parentClass", "parentModel", "workload", "profile", "agent"] as const) {
		const value = raw[field];
		if (value === undefined) continue;
		if (typeof value !== "string" || value.trim() === "") {
			errors.push(`${path}.${field} must be a non-empty string`);
			continue;
		}
		if (field === "parentModel" && !MODEL_PATTERN.test(value)) {
			errors.push(`${path}.parentModel is not a valid model pattern`);
			continue;
		}
		parsed[field] = value;
	}
	return Object.freeze(parsed);
}

function parseRuleTarget(raw: unknown, path: string, errors: string[]): RuleTarget | undefined {
	if (!isRecord(raw)) {
		errors.push(`${path} must be an object`);
		return undefined;
	}
	if (raw.kind === "declared" || raw.kind === "parent") {
		errors.push(...unknownFields(raw, ["kind"], path));
		return Object.freeze({ kind: raw.kind });
	}
	if (raw.kind === "named") {
		errors.push(...unknownFields(raw, ["kind", "target"], path));
		if (typeof raw.target !== "string" || raw.target.trim() === "") {
			errors.push(`${path}.target must be a non-empty string`);
			return undefined;
		}
		return Object.freeze({ kind: "named", target: raw.target });
	}
	errors.push(`${path}.kind must be declared, parent, or named`);
	return undefined;
}

function selectorsOverlap(first: RuleSelector, second: RuleSelector): boolean {
	for (const field of ["parentClass", "workload", "profile", "agent"] as const) {
		if (first[field] !== undefined && second[field] !== undefined && first[field] !== second[field]) return false;
	}
	if (first.parentModel && second.parentModel && !modelPatternsOverlap(first.parentModel, second.parentModel)) return false;
	return true;
}

export function parseModelRoutingPolicy(raw: unknown): PolicyParseResult {
	if (!isRecord(raw)) return { ok: false, error: ["model routing policy must be an object"] };

	const errors: string[] = [];
	errors.push(...unknownFields(raw, ["schemaVersion", "defaultClass", "modelClasses", "targets", "rules"], "policy"));
	if (raw.schemaVersion !== 1) errors.push("schemaVersion must be 1");
	if (typeof raw.defaultClass !== "string" || raw.defaultClass.trim() === "") {
		errors.push("defaultClass must be a non-empty string");
	}

	const parsedClasses: Record<string, readonly string[]> = {};
	if (!isRecord(raw.modelClasses)) {
		errors.push("modelClasses must be an object");
	} else {
		for (const [className, patterns] of Object.entries(raw.modelClasses)) {
			if (className.trim() === "") errors.push("modelClasses keys must be non-empty");
			if (!Array.isArray(patterns) || patterns.length === 0) {
				errors.push(`modelClasses.${className} must be a non-empty array`);
				continue;
			}
			const validPatterns = patterns.filter((pattern): pattern is string => {
				const valid = typeof pattern === "string" && MODEL_PATTERN.test(pattern);
				if (!valid) errors.push(`modelClasses.${className} contains invalid model pattern ${JSON.stringify(pattern)}`);
				return valid;
			});
			parsedClasses[className] = Object.freeze(validPatterns);
		}
	}

	const classEntries = Object.entries(parsedClasses);
	for (let first = 0; first < classEntries.length; first++) {
		for (let second = first + 1; second < classEntries.length; second++) {
			for (const firstPattern of classEntries[first][1]) {
				for (const secondPattern of classEntries[second][1]) {
					if (modelPatternsOverlap(firstPattern, secondPattern)) {
						errors.push(
							`model classes ${classEntries[first][0]} and ${classEntries[second][0]} overlap at ${firstPattern} / ${secondPattern}`,
						);
					}
				}
			}
		}
	}

	const parsedTargets: Record<string, PolicyTarget> = {};
	if (!isRecord(raw.targets)) {
		errors.push("targets must be an object");
	} else {
		for (const [name, target] of Object.entries(raw.targets)) {
			const targetPath = `targets.${name}`;
			if (name.trim() === "") errors.push("targets keys must be non-empty");
			if (!isRecord(target)) {
				errors.push(`${targetPath} must be an object`);
				continue;
			}
			errors.push(...unknownFields(target, ["model", "served", "thinkingLevel"], targetPath));
			const hasModel = typeof target.model === "string";
			const hasServed = typeof target.served === "string" && target.served.trim() !== "";
			if (hasModel === hasServed) {
				errors.push(`${targetPath} must name exactly one of model or served`);
				continue;
			}
			if (target.thinkingLevel !== undefined && !isThinkingLevel(target.thinkingLevel)) {
				errors.push(`${targetPath}.thinkingLevel is invalid`);
				continue;
			}
			const thinking = target.thinkingLevel ? { thinkingLevel: target.thinkingLevel } : {};
			if (typeof target.served === "string" && hasServed) {
				if (!PROVIDER.test(target.served)) {
					errors.push(`${targetPath}.served must be a provider name`);
					continue;
				}
				parsedTargets[name] = Object.freeze({ kind: "served", provider: target.served, ...thinking });
				continue;
			}
			const model = parseModelReference(String(target.model));
			if (!model.ok) {
				errors.push(`${targetPath}.model must be an exact provider/model reference`);
				continue;
			}
			parsedTargets[name] = Object.freeze({ kind: "exact", model: model.value, ...thinking });
		}
	}

	const parsedRules: RoutingRule[] = [];
	const ruleIds = new Set<string>();
	if (!Array.isArray(raw.rules)) {
		errors.push("rules must be an array");
	} else {
		raw.rules.forEach((rule, index) => {
			const rulePath = `rules[${index}]`;
			if (!isRecord(rule)) {
				errors.push(`${rulePath} must be an object`);
				return;
			}
			errors.push(...unknownFields(rule, ["id", "when", "use"], rulePath));
			if (typeof rule.id !== "string" || rule.id.trim() === "") {
				errors.push(`${rulePath}.id must be a non-empty string`);
				return;
			}
			if (ruleIds.has(rule.id)) errors.push(`duplicate routing rule id ${rule.id}`);
			ruleIds.add(rule.id);
			const selector = parseSelector(rule.when, `${rulePath}.when`, errors);
			const target = parseRuleTarget(rule.use, `${rulePath}.use`, errors);
			if (!selector || !target) return;
			if (selector.parentClass) {
				const knownClasses = new Set([raw.defaultClass, ...Object.keys(parsedClasses)]);
				if (!knownClasses.has(selector.parentClass)) {
					errors.push(`${rulePath}.when.parentClass references unknown class ${selector.parentClass}`);
				}
			}
			if (target.kind === "named" && !Object.hasOwn(parsedTargets, target.target)) {
				errors.push(`${rulePath}.use references unknown target ${target.target}`);
			}
			parsedRules.push(Object.freeze({
				id: rule.id,
				when: selector,
				use: target,
				specificity: Object.keys(selector).length,
			}));
		});
	}

	for (let first = 0; first < parsedRules.length; first++) {
		for (let second = first + 1; second < parsedRules.length; second++) {
			if (
				parsedRules[first].specificity === parsedRules[second].specificity &&
				selectorsOverlap(parsedRules[first].when, parsedRules[second].when)
			) {
				errors.push(
					`equal-specificity routing rules ${parsedRules[first].id} and ${parsedRules[second].id} can match the same workload`,
				);
			}
		}
	}

	if (errors.length > 0) return { ok: false, error: Object.freeze(errors) };

	return {
		ok: true,
		value: Object.freeze({
			schemaVersion: 1,
			defaultClass: raw.defaultClass as string,
			modelClasses: Object.freeze(parsedClasses),
			targets: Object.freeze(parsedTargets),
			rules: Object.freeze(parsedRules),
		}),
	};
}

export function classifyModel(
	policy: ModelRoutingPolicy,
	model: ModelReference,
): Result<string, RoutingError> {
	const matchingClasses = Object.entries(policy.modelClasses)
		.filter(([, patterns]) => patterns.some((pattern) => matchesModel(pattern, model)))
		.map(([className]) => className);
	if (matchingClasses.length > 1) {
		return {
			ok: false,
			error: { kind: "ambiguous-model-class", model: canonicalModel(model), classes: Object.freeze(matchingClasses) },
		};
	}
	return { ok: true, value: matchingClasses[0] ?? policy.defaultClass };
}

function ruleMatches(rule: RoutingRule, request: RoutingRequest, parentClass: string | undefined): boolean {
	const selector = rule.when;
	if (selector.parentClass !== undefined && selector.parentClass !== parentClass) return false;
	if (selector.parentModel !== undefined && (!request.parent || !matchesModel(selector.parentModel, request.parent.model))) return false;
	if (selector.workload !== undefined && selector.workload !== request.workload) return false;
	if (selector.profile !== undefined && selector.profile !== request.profile) return false;
	if (selector.agent !== undefined && selector.agent !== request.agent) return false;
	return true;
}

/** The binding a named target stands for, given what the shell probed. */
function targetBinding(
	target: PolicyTarget,
	request: RoutingRequest,
	ruleId: string,
): Result<ModelBinding, RoutingError> {
	switch (target.kind) {
		case "exact":
			return {
				ok: true,
				value: Object.freeze({
					model: target.model,
					...(target.thinkingLevel ? { thinkingLevel: target.thinkingLevel } : {}),
				}),
			};
		case "served": {
			const model = request.served?.[target.provider];
			if (!model) return { ok: false, error: { kind: "served-model-unknown", ruleId, provider: target.provider } };
			const thinkingLevel = target.thinkingLevel ?? request.parent?.thinkingLevel;
			return { ok: true, value: Object.freeze({ model, ...(thinkingLevel ? { thinkingLevel } : {}) }) };
		}
		default:
			return assertNever(target);
	}
}

/** Providers whose served model some rule depends on: the shell probes exactly these. */
export function servedProviders(policy: ModelRoutingPolicy): readonly string[] {
	const providers = new Set<string>();
	for (const rule of policy.rules) {
		if (rule.use.kind !== "named") continue;
		const target = policy.targets[rule.use.target];
		if (target?.kind === "served") providers.add(target.provider);
	}
	return Object.freeze([...providers].sort());
}

const assertNever = (value: never): never => {
	throw new Error(`unreachable: ${JSON.stringify(value)}`);
};

export function resolveModelRoute(
	policy: ModelRoutingPolicy,
	request: RoutingRequest,
	policyDigest: string,
): Result<RoutingDecision, RoutingError> {
	const classification = request.parent ? classifyModel(policy, request.parent.model) : undefined;
	if (classification && !classification.ok) return classification;
	const parentClass = classification?.value;
	const matching = policy.rules.filter((rule) => ruleMatches(rule, request, parentClass));
	const maxSpecificity = matching.reduce((max, rule) => Math.max(max, rule.specificity), -1);
	const winners = matching.filter((rule) => rule.specificity === maxSpecificity);
	if (winners.length > 1) {
		return { ok: false, error: { kind: "ambiguous-rule", ruleIds: Object.freeze(winners.map((rule) => rule.id)) } };
	}

	const winner = winners[0];
	if (!winner || winner.use.kind === "declared") {
		return {
			ok: true,
			value: Object.freeze({
				kind: "declared",
				declared: request.declared,
				effective: request.declared,
				parentClass,
				ruleId: winner?.id,
				policyDigest,
			}),
		};
	}

	if (winner.use.kind === "parent" && !request.parent) {
		return { ok: false, error: { kind: "parent-unavailable", ruleId: winner.id } };
	}
	const resolved = winner.use.kind === "parent"
		? (request.parent ? { ok: true as const, value: request.parent } : undefined)
		: targetBinding(policy.targets[winner.use.target], request, winner.id);
	if (!resolved) return { ok: false, error: { kind: "parent-unavailable", ruleId: winner.id } };
	if (!resolved.ok) return resolved;
	const effective = resolved.value;
	return {
		ok: true,
		value: Object.freeze({
			kind: "override",
			declared: request.declared,
			effective,
			parentClass,
			ruleId: winner.id,
			policyDigest,
		}),
	};
}

export function routingErrorMessage(error: RoutingError): string {
	switch (error.kind) {
		case "ambiguous-model-class":
			return `model ${error.model} matches multiple classes: ${error.classes.join(", ")}`;
		case "ambiguous-rule":
			return `routing rules are ambiguous: ${error.ruleIds.join(", ")}`;
		case "parent-unavailable":
			return `routing rule ${error.ruleId} requires an active parent model`;
		case "served-model-unknown":
			return `routing rule ${error.ruleId} routes to whatever ${error.provider} serves, but what it serves could not be determined`;
		default:
			return assertNever(error);
	}
}
