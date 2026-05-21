/**
 * Agent discovery and configuration
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { getAgentDir, loadSkills, parseFrontmatter } from "@earendil-works/pi-coding-agent";

export type AgentScope = "user" | "project" | "both";

export interface AgentConfig {
	name: string;
	description: string;
	tools?: string[];
	model?: string;
	systemPrompt: string;
	source: "user" | "project";
	filePath: string;
}

/** Cached skill name → file path map, lazily populated. */
let skillPathCache: Map<string, string> | null = null;

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
function parseToolNames(raw: unknown): string[] | undefined {
	if (!raw) return undefined;
	let tools: string[];
	if (Array.isArray(raw)) {
		tools = raw.map(String).map((s) => s.trim().toLowerCase()).filter(Boolean);
	} else if (typeof raw === "string") {
		tools = raw.split(",").map((s) => s.trim()).filter(Boolean);
	} else {
		return undefined;
	}
	return tools.length > 0 ? tools : undefined;
}

/**
 * Resolve skill paths from packages declared in settings.json.
 * loadSkills doesn't resolve packages itself — we must expand them.
 */
function resolvePackageSkillPaths(): string[] {
	try {
		const agentDir = getAgentDir();
		const settingsPath = path.join(agentDir, "settings.json");
		if (!fs.existsSync(settingsPath)) return [];

		const settings = JSON.parse(fs.readFileSync(settingsPath, "utf-8"));
		const packages: string[] = settings.packages ?? [];

		return packages.flatMap((pkg: string) => {
			const resolved = path.resolve(agentDir, pkg);
			const pkgJsonPath = path.join(resolved, "package.json");
			if (!fs.existsSync(pkgJsonPath)) return [];

			const manifest = JSON.parse(fs.readFileSync(pkgJsonPath, "utf-8"));
			const piSkills: string[] = manifest.pi?.skills ?? [];
			return piSkills.map((s: string) => path.resolve(resolved, s));
		});
	} catch {
		return [];
	}
}

/**
 * Discover all available skills and build a name → filePath map.
 * Resolves skills from packages in settings.json + pi's built-in discovery.
 */
function getSkillPathMap(cwd: string): Map<string, string> {
	if (skillPathCache) return skillPathCache;
	try {
		const packageSkillPaths = resolvePackageSkillPaths();
		const { skills } = loadSkills({
			cwd,
			skillPaths: packageSkillPaths,
			includeDefaults: true,
		});
		skillPathCache = new Map(skills.map((s) => [s.name, s.filePath]));
	} catch {
		skillPathCache = new Map();
	}
	return skillPathCache;
}

/**
 * Read skill file contents and format them for injection into system prompt.
 */
function resolveSkillContents(skillNames: string[], cwd: string): string {
	if (skillNames.length === 0) return "";

	const skillMap = getSkillPathMap(cwd);
	const sections: string[] = [];

	for (const name of skillNames) {
		const filePath = skillMap.get(name);
		if (!filePath) continue;

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
		} catch {
			// Skill file unreadable, skip silently
		}
	}

	return sections.join("\n");
}

export interface AgentDiscoveryResult {
	agents: AgentConfig[];
	projectAgentsDir: string | null;
}

function loadAgentsFromDir(dir: string, source: "user" | "project", cwd: string): AgentConfig[] {
	const agents: AgentConfig[] = [];

	if (!fs.existsSync(dir)) {
		return agents;
	}

	let entries: fs.Dirent[];
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch {
		return agents;
	}

	for (const entry of entries) {
		if (!entry.name.endsWith(".md")) continue;
		if (!entry.isFile() && !entry.isSymbolicLink()) continue;

		const filePath = path.join(dir, entry.name);
		let content: string;
		try {
			content = fs.readFileSync(filePath, "utf-8");
		} catch {
			continue;
		}

		let frontmatter: Record<string, string>;
		let body: string;
		try {
			const parsed = parseFrontmatter<Record<string, string>>(content);
			frontmatter = parsed.frontmatter;
			body = parsed.body;
		} catch {
			// Skip files with malformed YAML frontmatter
			continue;
		}

		if (!frontmatter.name || !frontmatter.description) {
			continue;
		}

		const tools = parseToolNames(frontmatter.tools);
		const skillNames = parseSkillNames(frontmatter.skills);

		// Resolve and inject skill contents into the system prompt
		const skillContent = resolveSkillContents(skillNames, cwd);
		const fullPrompt = skillContent ? `${body}\n${skillContent}` : body;

		agents.push({
			name: frontmatter.name,
			description: frontmatter.description,
			tools,
			model: frontmatter.model,
			systemPrompt: fullPrompt,
			source,
			filePath,
		});
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

	const userDir = path.join(getAgentDir(), "agents");
	const projectAgentsDir = findNearestProjectAgentsDir(cwd);

	const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user", cwd);
	const projectAgents = scope === "user" || !projectAgentsDir ? [] : loadAgentsFromDir(projectAgentsDir, "project", cwd);

	const agentMap = new Map<string, AgentConfig>();

	if (scope === "both") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	} else if (scope === "user") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
	} else {
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	}

	return { agents: Array.from(agentMap.values()), projectAgentsDir };
}

export function formatAgentList(agents: AgentConfig[], maxItems: number): { text: string; remaining: number } {
	if (agents.length === 0) return { text: "none", remaining: 0 };
	const listed = agents.slice(0, maxItems);
	const remaining = agents.length - listed.length;
	return {
		text: listed.map((a) => `${a.name} (${a.source}): ${a.description}`).join("; "),
		remaining,
	};
}
