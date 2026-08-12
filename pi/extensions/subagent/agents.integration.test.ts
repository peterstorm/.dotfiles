import { afterEach, describe, expect, it } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

const scratch: string[] = [];

afterEach(() => {
	for (const dir of scratch.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("agent skill discovery failure boundary", () => {
	it("fails closed when an agent declares a skill that cannot be resolved", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-missing-skill-"));
		scratch.push(root);
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = root;
		mkdirSync(join(root, "agents"), { recursive: true });
		writeFileSync(join(root, "settings.json"), JSON.stringify({ packages: [] }));
		writeFileSync(join(root, "agents", "broken.md"), [
			"---",
			"name: broken",
			"description: broken skill",
			"skills: definitely-missing-skill",
			"---",
			"body",
		].join("\n"));

		try {
			const { discoverAgents } = await import("./agents");
			expect(() => discoverAgents(process.cwd(), "user")).toThrow("Declared skill definitely-missing-skill");
		} finally {
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
		}
	});

	it("fails closed when a configured agent definition is malformed", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-malformed-agent-"));
		scratch.push(root);
		mkdirSync(join(root, "agents"), { recursive: true });
		writeFileSync(join(root, "settings.json"), JSON.stringify({ packages: [] }));
		writeFileSync(join(root, "agents", "broken.md"), "---\ninvalid: [unterminated\n---\nbody");
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = root;
		try {
			const { discoverAgents } = await import("./agents");
			expect(() => discoverAgents(process.cwd(), "user")).toThrow("Failed to parse agent definition");
		} finally {
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
		}
	});

	it("fails closed when a configured agent omits required frontmatter", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-incomplete-agent-"));
		scratch.push(root);
		mkdirSync(join(root, "agents"), { recursive: true });
		writeFileSync(join(root, "settings.json"), JSON.stringify({ packages: [] }));
		writeFileSync(join(root, "agents", "broken.md"), "---\nname: broken\n---\nbody");
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = root;
		try {
			const { discoverAgents } = await import("./agents");
			expect(() => discoverAgents(process.cwd(), "user")).toThrow("requires name and description");
		} finally {
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
		}
	});

	it("fails closed when a declared skill file cannot be parsed", async () => {
		const root = mkdtempSync(join(tmpdir(), "pi-malformed-skill-"));
		scratch.push(root);
		const agentDir = join(root, "agent");
		const packageDir = join(root, "package");
		const skillDir = join(packageDir, "skills", "malformed");
		mkdirSync(join(agentDir, "agents"), { recursive: true });
		mkdirSync(skillDir, { recursive: true });
		writeFileSync(join(packageDir, "package.json"), JSON.stringify({ name: "fixture" }));
		writeFileSync(join(agentDir, "settings.json"), JSON.stringify({ packages: ["../package"] }));
		writeFileSync(join(skillDir, "SKILL.md"), "---\ninvalid: [unterminated\n---\nbody");
		writeFileSync(join(agentDir, "agents", "broken.md"), [
			"---",
			"name: broken",
			"description: malformed skill",
			"skills: malformed",
			"---",
			"body",
		].join("\n"));
		const previous = process.env.PI_CODING_AGENT_DIR;
		process.env.PI_CODING_AGENT_DIR = agentDir;

		try {
			const { discoverAgents } = await import("./agents");
			expect(() => discoverAgents(process.cwd(), "user")).toThrow("Failed to discover Pi skills");
		} finally {
			if (previous === undefined) delete process.env.PI_CODING_AGENT_DIR;
			else process.env.PI_CODING_AGENT_DIR = previous;
		}
	});
});
