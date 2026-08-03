import { existsSync, lstatSync, readFileSync, readlinkSync, readdirSync, realpathSync } from "node:fs";
import { join, resolve } from "node:path";
import { getAgentDir, parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { discoverAgents, resolvePackageAgentDirs } from "./extensions/subagent/agents";

const requiredPanelAgents = [
  "arch-interviewer-agent",
  "arch-designer-agent",
  "arch-judge-agent",
  "review-verifier-agent",
] as const;

function fail(message: string): never {
  process.stderr.write(`pi agent verification failed: ${message}\n`);
  process.exit(1);
}

const agentDir = getAgentDir();
const userAgentsLink = join(agentDir, "agents");
if (!existsSync(userAgentsLink)) fail(`${userAgentsLink} is missing`);
if (!lstatSync(userAgentsLink).isSymbolicLink()) fail(`${userAgentsLink} is not Home Manager's directory symlink`);

const expectedUserDir = resolve(process.env.HOME ?? "", ".dotfiles/pi/agents");
if (realpathSync(userAgentsLink) !== realpathSync(expectedUserDir)) {
  fail(`${userAgentsLink} points to ${readlinkSync(userAgentsLink)}, expected ${expectedUserDir}`);
}

const packageAgentDirs = resolvePackageAgentDirs(agentDir);
if (packageAgentDirs.length === 0) fail("no configured local Pi package exposes an agents directory");

const discovered = discoverAgents(process.cwd(), "user").agents;
const discoveredByName = new Map(discovered.map((agent) => [agent.name, agent]));

for (const packageDir of packageAgentDirs) {
  for (const entry of readdirSync(packageDir, { withFileTypes: true })) {
    if (!entry.name.endsWith(".md") || entry.name === "README.md") continue;
    const filePath = join(packageDir, entry.name);
    const raw = readFileSync(filePath, "utf8");
    let name: string | undefined;
    try {
      name = parseFrontmatter<Record<string, string>>(raw).frontmatter.name;
    } catch {
      continue;
    }
    if (name && !discoveredByName.has(name)) fail(`${name} from ${filePath} was not discovered`);
  }
}

for (const name of requiredPanelAgents) {
  const sourceExists = packageAgentDirs.some((dir) => existsSync(join(dir, `${name}.md`)));
  if (sourceExists && !discoveredByName.has(name)) fail(`panel agent ${name} exists in Loom but is unavailable`);
}

const designer = discoveredByName.get("arch-designer-agent");
if (designer && !designer.systemPrompt.includes("## Preloaded Skill: architecture-tech-lead")) {
  fail("arch-designer-agent is missing its architecture-tech-lead skill injection");
}

process.stdout.write(
  `Pi agent install verified: ${discovered.length} agents, ${packageAgentDirs.length} package agent dir(s), panel roster available.\n`,
);
