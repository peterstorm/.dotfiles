import { spawn, spawnSync } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  readdirSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { createAgentSession, getAgentDir, ModelRuntime, parseFrontmatter, SessionManager } from "@earendil-works/pi-coding-agent";
import { loadModelRoutingPolicy } from "./extensions/model-routing/config";
import { parseModelReference, resolveModelRoute } from "./extensions/model-routing/policy";
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

const routingLink = join(agentDir, "model-routing.json");
const expectedRoutingFile = resolve(process.env.HOME ?? "", ".dotfiles/pi/model-routing.json");
if (!existsSync(routingLink)) fail(`${routingLink} is missing`);
if (!lstatSync(routingLink).isSymbolicLink()) fail(`${routingLink} is not Home Manager's routing-policy symlink`);
if (resolve(dirname(routingLink), readlinkSync(routingLink)) !== expectedRoutingFile) {
  fail(`${routingLink} points to ${readlinkSync(routingLink)}, expected ${expectedRoutingFile}`);
}

const loadedRouting = loadModelRoutingPolicy(agentDir);
if (!loadedRouting.ok) fail(`invalid model routing policy: ${loadedRouting.error.message}`);
const deepSeekModel = parseModelReference("desktop-vllm/deepseek-v4-flash");
const cloudModel = parseModelReference("openai-codex/gpt-5.6-sol");
if (!deepSeekModel.ok || !cloudModel.ok) fail("verification model references are invalid");
const deepSeekBinding = {
  model: deepSeekModel.value,
  thinkingLevel: "max" as const,
};
const localRoute = resolveModelRoute(
  loadedRouting.value.policy,
  {
    parent: deepSeekBinding,
    declared: {
      model: cloudModel.value,
      thinkingLevel: "high",
    },
    workload: "subagent",
    profile: "general-review",
    agent: "code-reviewer",
  },
  loadedRouting.value.digest,
);
if (!localRoute.ok) fail(`cannot resolve local subagent route: ${localRoute.error.kind}`);
if (
  localRoute.value.kind !== "override" ||
  localRoute.value.effective?.model.provider !== "desktop-vllm" ||
  localRoute.value.effective?.model.id !== "deepseek-v4-flash" ||
  localRoute.value.effective?.thinkingLevel !== "max"
) {
  fail("local parent does not override a subagent's declared cloud binding");
}

const modelsConfig = JSON.parse(readFileSync(modelsLink, "utf8")) as {
  providers?: Record<
    string,
    {
      baseUrl?: string;
      models?: Array<{
        id?: string;
        defaultThinkingLevel?: string;
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
if (deepSeek.defaultThinkingLevel !== "max") fail("deepseek-v4-flash does not declare max as its model default");
for (const level of ["low", "high", "max"] as const) {
  if (deepSeek.thinkingLevelMap?.[level] !== level) {
    fail(`deepseek-v4-flash does not expose the ${level} reasoning contract`);
  }
}

const runtimeAgentDir = mkdtempSync(join(tmpdir(), "pi-routing-verify-"));
const installedSettings = JSON.parse(readFileSync(join(agentDir, "settings.json"), "utf8")) as {
  defaultThinkingLevel?: string;
};
copyFileSync(join(agentDir, "settings.json"), join(runtimeAgentDir, "settings.json"));
symlinkSync(modelsLink, join(runtimeAgentDir, "models.json"));
symlinkSync(routingLink, join(runtimeAgentDir, "model-routing.json"));
symlinkSync(join(agentDir, "extensions"), join(runtimeAgentDir, "extensions"));
for (const credentialFile of ["auth.json", "models-store.json"]) {
  const source = join(agentDir, credentialFile);
  if (existsSync(source)) copyFileSync(source, join(runtimeAgentDir, credentialFile));
}

type RpcResponse = Readonly<{
  type?: string;
  command?: string;
  data?: {
    thinkingLevel?: string;
    model?: { provider?: string; id?: string };
  };
}>;

function runtimeThinkingLevel(extraArgs: readonly string[], includeModel: boolean = true): string | undefined {
  const result = spawnSync(
    "pi",
    [
      "--mode",
      "rpc",
      "--no-session",
      ...(includeModel ? ["--model", "desktop-vllm/deepseek-v4-flash"] : []),
      ...extraArgs,
    ],
    {
      input: '{"type":"get_state"}\n',
      encoding: "utf8",
      timeout: 10_000,
      env: {
        ...process.env,
        CORTEX_EXTRACTING: "1",
        PI_CODING_AGENT_DIR: runtimeAgentDir,
      },
    },
  );
  if (result.error || result.status !== 0) {
    fail(`cannot inspect DeepSeek startup state: ${result.error?.message ?? result.stderr}`);
  }
  for (const line of result.stdout.split("\n")) {
    try {
      const event = JSON.parse(line) as {
        type?: string;
        command?: string;
        data?: { thinkingLevel?: string };
      };
      if (event.type === "response" && event.command === "get_state") return event.data?.thinkingLevel;
    } catch {
      // Extensions may write non-protocol diagnostics; ignore those lines.
    }
  }
  return undefined;
}

async function thinkingAfterCycle(options: Readonly<{
  startModel: string;
  models: string;
  expectedProvider: string;
  expectedModel: string;
  thinkingLevel?: string;
}>): Promise<Readonly<{
  thinkingLevel?: string;
  model?: string;
}>> {
  const proc = spawn(
    "pi",
    [
      "--mode",
      "rpc",
      "--no-session",
      "--model",
      options.startModel,
      "--models",
      options.models,
      ...(options.thinkingLevel ? ["--thinking", options.thinkingLevel] : []),
    ],
    {
      stdio: ["pipe", "pipe", "pipe"],
      env: {
        ...process.env,
        CORTEX_EXTRACTING: "1",
        PI_CODING_AGENT_DIR: runtimeAgentDir,
      },
    },
  );
  let stdout = "";
  let stderr = "";
  const waiters: Array<{
    command: string;
    resolve: (response: RpcResponse) => void;
  }> = [];
  const acceptLine = (line: string): void => {
    try {
      const response = JSON.parse(line) as RpcResponse;
      if (response.type !== "response") return;
      const index = waiters.findIndex((waiter) => waiter.command === response.command);
      if (index < 0) return;
      waiters.splice(index, 1)[0].resolve(response);
    } catch {
      // Ignore extension diagnostics that are not RPC JSON.
    }
  };
  proc.stdout.on("data", (chunk) => {
    stdout += chunk.toString();
    const lines = stdout.split("\n");
    stdout = lines.pop() ?? "";
    for (const line of lines) acceptLine(line);
  });
  proc.stderr.on("data", (chunk) => { stderr += chunk.toString(); });
  const request = (command: Record<string, unknown>, expected: string): Promise<RpcResponse> =>
    new Promise((resolveResponse, rejectResponse) => {
      const timer = setTimeout(() => rejectResponse(new Error(`RPC ${expected} timed out: ${stderr}`)), 10_000);
      waiters.push({
        command: expected,
        resolve: (response) => {
          clearTimeout(timer);
          resolveResponse(response);
        },
      });
      proc.stdin.write(`${JSON.stringify(command)}\n`);
    });
  try {
    const cycle = await request({ type: "cycle_model" }, "cycle_model");
    if (
      cycle.data?.model?.provider !== options.expectedProvider ||
      cycle.data.model.id !== options.expectedModel
    ) {
      throw new Error(`cycle_model selected the wrong model: ${JSON.stringify(cycle.data)}`);
    }
    const state = await request({ type: "get_state" }, "get_state");
    return {
      thinkingLevel: state.data?.thinkingLevel,
      model: state.data?.model ? `${state.data.model.provider}/${state.data.model.id}` : undefined,
    };
  } finally {
    proc.stdin.end();
    proc.kill("SIGTERM");
  }
}

try {
  if (runtimeThinkingLevel([]) !== "max") fail("DeepSeek does not start at its max model default");
  const settingsAfterModelDefault = JSON.parse(readFileSync(join(runtimeAgentDir, "settings.json"), "utf8")) as {
    defaultThinkingLevel?: string;
  };
  if (settingsAfterModelDefault.defaultThinkingLevel !== installedSettings.defaultThinkingLevel) {
    fail("DeepSeek's model default mutated Pi's global cloud-model thinking default");
  }
  if (runtimeThinkingLevel(["--thinking", "low"]) !== "low") {
    fail("DeepSeek model default overwrites an explicit child thinking level");
  }
  if (runtimeThinkingLevel(["--models", "desktop-vllm/deepseek-v4-flash:low"], false) !== "low") {
    fail("DeepSeek model default overwrites a scoped model's explicit thinking level");
  }
  if (runtimeThinkingLevel([
    "--models",
    "desktop-vllm/deepseek-v4-flash,openai-codex/gpt-5.6-sol:low",
  ], false) !== "max") {
    fail("another scoped model's thinking pin suppresses DeepSeek's model default");
  }
  const crossCapability = await thinkingAfterCycle({
    startModel: "google/gemini-2.0-flash",
    models: "google/gemini-2.0-flash,desktop-vllm/deepseek-v4-flash",
    expectedProvider: "desktop-vllm",
    expectedModel: "deepseek-v4-flash",
    thinkingLevel: "low",
  });
  if (
    crossCapability.model !== "desktop-vllm/deepseek-v4-flash" ||
    crossCapability.thinkingLevel !== "low"
  ) {
    fail("model cycling does not restore an explicit preference after startup clamping");
  }

  const isolatedSettingsPath = join(runtimeAgentDir, "settings.json");
  const lowBaseline = {
    ...JSON.parse(readFileSync(isolatedSettingsPath, "utf8")) as Record<string, unknown>,
    defaultThinkingLevel: "low",
  };
  writeFileSync(isolatedSettingsPath, JSON.stringify(lowBaseline, null, 2));
  const afterModelDefault = await thinkingAfterCycle({
    startModel: "desktop-vllm/deepseek-v4-flash",
    models: "desktop-vllm/deepseek-v4-flash,google/gemini-3.1-flash-lite",
    expectedProvider: "google",
    expectedModel: "gemini-3.1-flash-lite",
  });
  if (
    afterModelDefault.model !== "google/gemini-3.1-flash-lite" ||
    afterModelDefault.thinkingLevel !== "low"
  ) {
    fail("leaving DeepSeek does not restore the cloud baseline thinking preference");
  }
  const settingsAfterCycle = JSON.parse(readFileSync(isolatedSettingsPath, "utf8")) as {
    defaultThinkingLevel?: string;
  };
  if (settingsAfterCycle.defaultThinkingLevel !== "low") {
    fail("model-default cycling mutated Pi's global thinking preference");
  }
} finally {
  rmSync(runtimeAgentDir, { recursive: true, force: true });
}

// Persisted sessions must retain their own thinking selection even when the
// selected model declares a different model-local default.
const resumeDir = mkdtempSync(join(tmpdir(), "pi-routing-resume-"));
try {
  const sessionFile = join(resumeDir, "saved-session.jsonl");
  const sessionId = "019ff540-7419-7c7a-8f91-c84d253a6f7d";
  writeFileSync(sessionFile, [
    JSON.stringify({
      type: "session",
      version: 3,
      id: sessionId,
      timestamp: new Date().toISOString(),
      cwd: process.cwd(),
    }),
    JSON.stringify({
      type: "model_change",
      id: "model-entry",
      parentId: null,
      timestamp: new Date().toISOString(),
      provider: "desktop-vllm",
      modelId: "deepseek-v4-flash",
    }),
    JSON.stringify({
      type: "thinking_level_change",
      id: "thinking-entry",
      parentId: "model-entry",
      timestamp: new Date().toISOString(),
      thinkingLevel: "low",
    }),
    JSON.stringify({
      type: "message",
      id: "message-entry",
      parentId: "thinking-entry",
      timestamp: new Date().toISOString(),
      message: { role: "user", content: [{ type: "text", text: "resume verification" }] },
    }),
    "",
  ].join("\n"));
  const resumed = spawnSync(
    "pi",
    ["--mode", "rpc", "--session", sessionFile],
    {
      input: '{"type":"get_state"}\n',
      encoding: "utf8",
      timeout: 10_000,
      env: { ...process.env, CORTEX_EXTRACTING: "1", PI_CODING_AGENT_DIR: agentDir },
    },
  );
  const resumedThinking = resumed.stdout.split("\n").flatMap((line) => {
    try {
      const response = JSON.parse(line) as { data?: { thinkingLevel?: string } };
      return response.data?.thinkingLevel ? [response.data.thinkingLevel] : [];
    } catch {
      return [];
    }
  })[0];
  if (resumedThinking !== "low") fail("resumed DeepSeek session did not preserve its saved thinking level");

  const modelRuntime = await ModelRuntime.create({
    authPath: join(agentDir, "auth.json"),
    modelsPath: join(agentDir, "models.json"),
    modelsStorePath: join(agentDir, "models-store.json"),
    allowModelNetwork: false,
  });
  const resumedSession = await createAgentSession({
    cwd: process.cwd(),
    agentDir,
    modelRuntime,
    sessionManager: SessionManager.open(sessionFile),
    thinkingPreference: { kind: "pinned", level: "low" },
  });
  const cloud = modelRuntime.getModel("google", "gemini-3.1-flash-lite");
  if (!cloud) fail("cannot find cloud model for resumed SDK pin verification");
  await resumedSession.session.setModel(cloud);
  if (resumedSession.session.thinkingLevel !== "low") {
    fail("resumed SDK session discarded its explicit thinking preference on model switch");
  }
} finally {
  rmSync(resumeDir, { recursive: true, force: true });
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

const codeReviewer = discoveredByName.get("code-reviewer");
if (codeReviewer && codeReviewer.modelProfile !== "general-review") {
  fail("code-reviewer's Loom model-profile was not preserved during discovery");
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
  `Pi install verified: DeepSeek model catalog and local-aware routing, ${discovered.length} agents, ` +
    `${packageAgentDirs.length} package agent dir(s), ${renderedAgents.size} current Loom render(s), ` +
    `panel roster available.\n`,
);
