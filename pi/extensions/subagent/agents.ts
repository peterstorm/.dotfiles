/**
 * Agent discovery and configuration
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { getAgentDir, loadSkills, parseFrontmatter } from "@earendil-works/pi-coding-agent";
import {
	hasPreloadedSkill,
	resolvePackageAgentDirs as resolvePackageAgentDirsFrom,
	resolvePackageSkillDirs as resolvePackageSkillDirsFrom,
} from "./package-resources.js";

export type AgentScope = "user" | "project" | "both";

export type AgentSource = "package" | "user" | "project";

export type AgentConfig = Readonly<{
	name: string;
	description: string;
	tools?: readonly string[];
	model?: string;
	modelProfile?: string;
	declaredSkills: readonly string[];
	systemPrompt: string;
	source: AgentSource;
	filePath: string;
}>;

/** Cached skill name → file path map, lazily populated. */
let skillPathCache: Map<string, string> | null = null;

export class AgentDiscoveryError extends Error {
	constructor(message: string, options?: ErrorOptions) {
		super(message, options);
		this.name = "AgentDiscoveryError";
	}
}

/**
 * Parse the `skills` frontmatter field.
 * Accepts either a comma-separated string or a YAML array.
 */
function parseSkillNames(raw: unknown): string[] {
	if (!raw) return [];
	if (Array.isArray(raw)) return raw.map(String).map((s) => s.trim()).filter(Boolean);
	if (typeof raw === "string") return raw.split(",").map((s) => s.trim()).filter(Boolean);
	return [];
}

/**
 * Parse the `tools` frontmatter field.
 * Accepts either a comma-separated string or a YAML array.
 */
function parseToolNames(raw: unknown): readonly string[] | undefined {
	if (!raw) return undefined;
	let tools: string[];
	if (Array.isArray(raw)) {
		tools = raw.map(String).map((s) => s.trim().toLowerCase()).filter(Boolean);
	} else if (typeof raw === "string") {
		tools = raw.split(",").map((s) => s.trim()).filter(Boolean);
	} else {
		return undefined;
	}
	return tools.length > 0 ? Object.freeze(tools) : undefined;
}

/** Resolve local package agent directories from the active Pi settings. */
export function resolvePackageAgentDirs(agentDir: string = getAgentDir()): string[] {
	return resolvePackageAgentDirsFrom(agentDir);
}

/**
 * Resolve skill paths from local packages declared in settings.json.
 * loadSkills doesn't resolve packages itself — we must expand them.
 */
function resolvePackageSkillPaths(): string[] {
	return resolvePackageSkillDirsFrom(getAgentDir());
}

/**
 * Discover all available skills and build a name → filePath map.
 * Resolves skills from packages in settings.json + pi's built-in discovery.
 */
function getSkillPathMap(cwd: string): Map<string, string> {
	if (skillPathCache) return skillPathCache;
	try {
		const packageSkillPaths = resolvePackageSkillPaths();
		const { skills, diagnostics } = loadSkills({
			cwd,
			agentDir: getAgentDir(),
			skillPaths: packageSkillPaths,
			includeDefaults: true,
		});
		const failures = diagnostics.filter((diagnostic) => diagnostic.type === "error" || diagnostic.type === "warning");
		if (failures.length > 0) {
			const summary = failures
				.map(({ message, path: diagnosticPath }) => `${diagnosticPath ? `${diagnosticPath}: ` : ""}${message}`)
				.join("; ");
			throw new AgentDiscoveryError(`Failed to discover Pi skills for ${cwd}: ${summary}`);
		}
		skillPathCache = new Map(skills.map((s) => [s.name, s.filePath]));
	} catch (error) {
		if (error instanceof AgentDiscoveryError) throw error;
		throw new AgentDiscoveryError(`Failed to discover Pi skills for ${cwd}`, { cause: error });
	}
	return skillPathCache;
}

/**
 * Read skill file contents and format them for injection into system prompt.
 *
 * `body` is the agent's own prompt: a skill it already preloads (Loom inlines
 * them when it renders its Pi agents) is skipped rather than duplicated.
 */
function resolveSkillContents(skillNames: string[], cwd: string, body: string): string {
	if (skillNames.length === 0) return "";

	let skillMap: Map<string, string> | undefined;
	const sections: string[] = [];

	for (const name of skillNames) {
		// Loom's generated body can include CRLF or other harmless formatting
		// differences; checking the explicit preload heading before discovery
		// keeps already-inlined skills independent of package skill discovery.
		if (body.includes(`## Preloaded Loom Skill: ${name}`) || hasPreloadedSkill(body, name)) continue;
		skillMap ??= getSkillPathMap(cwd);
		const filePath = skillMap.get(name);
		if (!filePath) {
			throw new AgentDiscoveryError(`Declared skill ${name} could not be resolved for ${cwd}`);
		}

		try {
			const raw = fs.readFileSync(filePath, "utf-8");
			// Strip frontmatter, keep just the instructions
			const { body } = parseFrontmatter<Record<string, string>>(raw);
			if (body.trim()) {
				const skillDir = path.dirname(filePath);
				sections.push(
					`\n---\n## Preloaded Skill: ${name}\n` +
					`Skill directory: ${skillDir}\n` +
					`When the skill references relative paths, resolve them against: ${skillDir}\n\n` +
					body.trim(),
				);
			}
		} catch (error) {
			if (error instanceof AgentDiscoveryError) throw error;
			throw new AgentDiscoveryError(`Failed to load declared skill ${name} from ${filePath}`, { cause: error });
		}
	}

	return sections.join("\n");
}

export type AgentDiscoveryResult = Readonly<{
	agents: readonly AgentConfig[];
	packageAgentsDirs: readonly string[];
	projectAgentsDir: string | null;
}>;

function loadAgentsFromDir(dir: string, source: AgentSource, cwd: string): AgentConfig[] {
	const agents: AgentConfig[] = [];

	if (!fs.existsSync(dir)) {
		return agents;
	}

	let entries: fs.Dirent[];
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch (error) {
		throw new AgentDiscoveryError(`Failed to read agent directory ${dir}`, { cause: error });
	}

	for (const entry of entries) {
		if (!entry.name.endsWith(".md")) continue;
		if (!entry.isFile() && !entry.isSymbolicLink()) continue;

		const filePath = path.join(dir, entry.name);
		let content: string;
		try {
			content = fs.readFileSync(filePath, "utf-8");
		} catch (error) {
			throw new AgentDiscoveryError(`Failed to read agent definition ${filePath}`, { cause: error });
		}

		let frontmatter: Record<string, string>;
		let body: string;
		try {
			const parsed = parseFrontmatter<Record<string, string>>(content);
			frontmatter = parsed.frontmatter;
			body = parsed.body;
		} catch (error) {
			throw new AgentDiscoveryError(`Failed to parse agent definition ${filePath}`, { cause: error });
		}

		const declaresAgent = frontmatter.name !== undefined || frontmatter.description !== undefined ||
			frontmatter.model !== undefined || frontmatter["model-profile"] !== undefined || frontmatter.skills !== undefined;
		if (!declaresAgent) continue;
		if (!frontmatter.name || !frontmatter.description) {
			throw new AgentDiscoveryError(`Agent definition ${filePath} requires name and description`);
		}

		const tools = parseToolNames(frontmatter.tools);
		const skillNames = parseSkillNames(frontmatter.skills);

		agents.push(Object.freeze({
			name: frontmatter.name,
			description: frontmatter.description,
			tools,
			model: frontmatter.model,
			modelProfile: frontmatter["model-profile"],
			declaredSkills: Object.freeze(skillNames),
			systemPrompt: body,
			source,
			filePath,
		}));
	}

	return agents;
}

function isDirectory(p: string): boolean {
	try {
		return fs.statSync(p).isDirectory();
	} catch {
		return false;
	}
}

function findNearestProjectAgentsDir(cwd: string): string | null {
	let currentDir = cwd;
	while (true) {
		const candidate = path.join(currentDir, ".pi", "agents");
		if (isDirectory(candidate)) return candidate;

		const parentDir = path.dirname(currentDir);
		if (parentDir === currentDir) return null;
		currentDir = parentDir;
	}
}

export function discoverAgents(cwd: string, scope: AgentScope): AgentDiscoveryResult {
	// Reset skill cache so skills are discovered fresh for this cwd
	skillPathCache = null;

	const agentDir = getAgentDir();
	const userDir = path.join(agentDir, "agents");
	const packageAgentsDirs = resolvePackageAgentDirs(agentDir);
	const projectAgentsDir = findNearestProjectAgentsDir(cwd);

	const packageAgents = scope === "project"
		? []
		: packageAgentsDirs.flatMap((dir) => loadAgentsFromDir(dir, "package", cwd));
	const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user", cwd);
	const projectAgents = scope === "user" || !projectAgentsDir ? [] : loadAgentsFromDir(projectAgentsDir, "project", cwd);

	const agentMap = new Map<string, AgentConfig>();

	// Precedence is package < user < project. A user can override a packaged
	// agent globally, and a trusted project can override either for that repo.
	for (const agent of packageAgents) agentMap.set(agent.name, agent);
	for (const agent of userAgents) agentMap.set(agent.name, agent);
	for (const agent of projectAgents) agentMap.set(agent.name, agent);

	const agents = Object.freeze(Array.from(agentMap.values()).map((agent) => {
		const skillContent = resolveSkillContents([...agent.declaredSkills], cwd, agent.systemPrompt);
		return skillContent
			? Object.freeze({ ...agent, systemPrompt: `${agent.systemPrompt}\n${skillContent}` })
			: agent;
	}));

	return Object.freeze({ agents, packageAgentsDirs: Object.freeze(packageAgentsDirs), projectAgentsDir });
}

export function formatAgentList(agents: readonly AgentConfig[], maxItems: number): { text: string; remaining: number } {
	if (agents.length === 0) return { text: "none", remaining: 0 };
	const listed = agents.slice(0, maxItems);
	const remaining = agents.length - listed.length;
	return {
		text: listed.map((a) => `${a.name} (${a.source}): ${a.description}`).join("; "),
		remaining,
	};
}
