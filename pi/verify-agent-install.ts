import { existsSync, lstatSync, readFileSync, readlinkSync, readdirSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";
import { getAgentDir, parseFrontmatter } from "@earendil-works/pi-coding-agent";
import { discoverAgents, resolvePackageAgentDirs } from "./extensions/subagent/agents";

const requiredPanelAgents = [
  "arch-interviewer-agent",
  "arch-designer-agent",
  "arch-judge-agent",
  "review-verifier-agent",
] as const;

const loomMarker = "<!-- LOOM_PI_AGENT_ID:";

function fail(message: string): never {
  process.stderr.write(`pi agent verification failed: ${message}\n`);
  process.exit(1);
}

const agentDir = getAgentDir();
const userAgentsDir = join(agentDir, "agents");

// Loom renders its roster into this directory, so it must be real storage under
// ~/.pi — a symlink into the dotfiles repo would commit generated, machine-bound
// definitions to version control.
if (!existsSync(userAgentsDir)) fail(`${userAgentsDir} is missing`);
if (lstatSync(userAgentsDir).isSymbolicLink()) {
  fail(
    `${userAgentsDir} is a symlink to ${readlinkSync(userAgentsDir)}; ` +
      `Loom renders into it, so generated agents would land in the dotfiles repo`,
  );
}
if (!lstatSync(userAgentsDir).isDirectory()) fail(`${userAgentsDir} is not a directory`);

// The generic agents this repo owns are installed as per-file symlinks, so edits
// in the repo stay live.
const ownedAgentsDir = resolve(process.env.HOME ?? "", ".dotfiles/pi/agents");
for (const entry of readdirSync(ownedAgentsDir)) {
  if (!entry.endsWith(".md")) continue;
  const source = join(ownedAgentsDir, entry);
  const link = join(userAgentsDir, entry);
  if (!existsSync(link)) fail(`agent ${entry} owned by the dotfiles is not installed at ${link}`);
  if (!lstatSync(link).isSymbolicLink()) fail(`${link} should be a symlink to ${source}`);
  if (resolve(dirname(link), readlinkSync(link)) !== source) {
    fail(`${link} points to ${readlinkSync(link)}, expected ${source}`);
  }
}

const modelsLink = join(agentDir, "models.json");
const expectedModelsFile = resolve(process.env.HOME ?? "", ".dotfiles/pi/models.json");
if (!existsSync(modelsLink)) fail(`${modelsLink} is missing`);
if (!lstatSync(modelsLink).isSymbolicLink()) fail(`${modelsLink} is not Home Manager's model-catalog symlink`);
if (resolve(dirname(modelsLink), readlinkSync(modelsLink)) !== expectedModelsFile) {
  fail(`${modelsLink} points to ${readlinkSync(modelsLink)}, expected ${expectedModelsFile}`);
}

const modelsConfig = JSON.parse(readFileSync(modelsLink, "utf8")) as {
  providers?: Record<
    string,
    {
      baseUrl?: string;
      models?: Array<{
        id?: string;
        thinkingLevelMap?: Record<string, string | null>;
      }>;
    }
  >;
};
const desktopProvider = modelsConfig.providers?.["desktop-vllm"];
const deepSeek = desktopProvider?.models?.find((model) => model.id === "deepseek-v4-flash");
if (desktopProvider?.baseUrl !== "http://192.168.0.80:8000/v1") {
  fail("desktop-vllm does not target the workstation's OpenAI-compatible endpoint");
}
if (!deepSeek) fail("desktop-vllm is missing deepseek-v4-flash");
for (const level of ["low", "high", "max"] as const) {
  if (deepSeek.thinkingLevelMap?.[level] !== level) {
    fail(`deepseek-v4-flash does not expose the ${level} reasoning contract`);
  }
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

// Discovery only makes an agent visible. Loom's pre-tool-use guard additionally
// requires a generated definition that is byte-for-byte the current render, and
// blocks the spawn otherwise — so prove both here, using Loom's own validator.
const renderedAgents = new Set<string>();
for (const packageDir of packageAgentDirs) {
  const packageRoot = dirname(packageDir);
  const rendererPath = join(packageRoot, "engine/src/utils/render-pi-agent.ts");
  if (!existsSync(rendererPath)) continue;
  const { validatePiAgentDefinitionFile } = (await import(rendererPath)) as {
    validatePiAgentDefinitionFile: (
      path: string,
      agent: string,
      packageRoot: string,
    ) => { ok: true } | { ok: false; error: string };
  };

  for (const entry of readdirSync(packageDir)) {
    if (!entry.endsWith(".md") || entry === "README.md") continue;
    const agent = basename(entry, ".md");
    const generated = join(userAgentsDir, entry);
    renderedAgents.add(entry);

    if (!existsSync(generated)) fail(`${agent} has no generated definition at ${generated} — run loom-sync`);
    if (lstatSync(generated).isSymbolicLink()) {
      fail(`${generated} is a symlink; the raw package agent cannot satisfy Loom's model policy — run loom-sync`);
    }
    if (!readFileSync(generated, "utf8").includes(`${loomMarker}${agent} -->`)) {
      fail(`${generated} is missing its ${loomMarker}${agent} --> marker — run loom-sync`);
    }
    const validation = validatePiAgentDefinitionFile(generated, agent, packageRoot);
    if (!validation.ok) fail(`${agent} render is stale: ${validation.error} — run loom-sync`);
  }
}

// A render left behind after its source agent was deleted would keep resolving
// for spawns; activation prunes these, so none should survive.
for (const entry of readdirSync(userAgentsDir)) {
  if (!entry.endsWith(".md")) continue;
  const path = join(userAgentsDir, entry);
  if (lstatSync(path).isSymbolicLink()) continue;
  if (!readFileSync(path, "utf8").includes(loomMarker)) continue;
  if (!renderedAgents.has(entry)) fail(`${path} is a render of an agent no longer shipped by any package`);
}

for (const name of requiredPanelAgents) {
  const sourceExists = packageAgentDirs.some((dir) => existsSync(join(dir, `${name}.md`)));
  if (sourceExists && !discoveredByName.has(name)) fail(`panel agent ${name} exists in Loom but is unavailable`);
}

// A skill reaches an agent by one of two routes: Loom inlines it when it renders
// the agent ("## Preloaded Loom Skill: <name>"), or the subagent extension
// injects it from the skill map ("## Preloaded Skill: <name>"). Exactly one must
// happen — none means the agent lost its skill, two means the whole skill body
// sits in the system prompt twice.
const designer = discoveredByName.get("arch-designer-agent");
if (designer) {
  const preloads = [
    ...designer.systemPrompt.matchAll(/^##[ \t]+Preloaded\b[^\n]*\bSkill:[ \t]*architecture-tech-lead[ \t]*$/gm),
  ];
  if (preloads.length === 0) fail("arch-designer-agent is missing its architecture-tech-lead skill");
  if (preloads.length > 1) {
    fail(
      `arch-designer-agent preloads architecture-tech-lead ${preloads.length}×: ` +
        `Loom already inlines it, so the extension must not inject it again`,
    );
  }
}

process.stdout.write(
  `Pi install verified: DeepSeek model catalog, ${discovered.length} agents, ` +
    `${packageAgentDirs.length} package agent dir(s), ${renderedAgents.size} current Loom render(s), ` +
    `panel roster available.\n`,
);
