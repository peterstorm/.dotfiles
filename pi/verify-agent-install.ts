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
import { parseModelReference, resolveModelRoute, servedProviders, type ServedModels } from "./extensions/model-routing/policy";
import { PRIMARY_PROVIDER } from "./extensions/primary-switch/switch";
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

// Wire decoders. Every JSON document this verifier reads (catalog, settings, Pi's
// RPC lines) is bound as unknown and narrowed here; nothing is cast.
const parseJson = (raw: string): unknown => JSON.parse(raw);
const readJson = (path: string): unknown => parseJson(readFileSync(path, "utf8"));
const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null && !Array.isArray(value);
const field = (value: unknown, key: string): unknown => (isRecord(value) ? value[key] : undefined);
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const list = (value: unknown): readonly unknown[] => (Array.isArray(value) ? value : []);

type CatalogModel = Readonly<{
  id?: string;
  defaultThinkingLevel?: string;
  thinkingLevelMap: Readonly<Record<string, unknown>>;
  contextWindow?: number;
  supportsDeveloperRole: unknown;
  thinkingFormat?: string;
}>;
const catalogModel = (raw: unknown): CatalogModel => {
  const levels = field(raw, "thinkingLevelMap");
  const context = field(raw, "contextWindow");
  return {
    id: text(field(raw, "id")),
    defaultThinkingLevel: text(field(raw, "defaultThinkingLevel")),
    thinkingLevelMap: isRecord(levels) ? levels : {},
    contextWindow: typeof context === "number" ? context : undefined,
    supportsDeveloperRole: field(field(raw, "compat"), "supportsDeveloperRole"),
    thinkingFormat: text(field(field(raw, "compat"), "thinkingFormat")),
  };
};

type RpcResponse = Readonly<{
  type?: string;
  command?: string;
  data?: Readonly<{
    thinkingLevel?: string;
    model?: Readonly<{ provider?: string; id?: string }>;
  }>;
}>;
const rpcResponse = (raw: unknown): RpcResponse => {
  const data = field(raw, "data");
  const model = field(data, "model");
  return {
    type: text(field(raw, "type")),
    command: text(field(raw, "command")),
    data: isRecord(data)
      ? {
        thinkingLevel: text(field(data, "thinkingLevel")),
        model: isRecord(model)
          ? { provider: text(field(model, "provider")), id: text(field(model, "id")) }
          : undefined,
      }
      : undefined,
  };
};
const settingsThinkingLevel = (path: string): string | undefined =>
  text(field(readJson(path), "defaultThinkingLevel"));

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
// The local catalog is exactly the four primaries' served ids: WARMIND and
// stock DeepSeek-V4.1-Flash-1017 on ds4-native, and GLM-5.3 v16 and its
// CYBERSECURITY hybrid on Hyperflare.
const primaryModels = [
  "warmind-1017-native",
  "deepseek-v4.1-flash-native",
  "glm-5.3-flash-hyperflare-tp2-v16",
  "glm-5.3-flash-hyperflare-tp2-cyber-hybrid",
] as const;
const warmindModel = parseModelReference("desktop-vllm/warmind-1017-native");
const glmModel = parseModelReference("desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16");
const cloudModel = parseModelReference("openai-codex/gpt-5.6-sol");
const llamaCppModel = parseModelReference("llama.cpp/local-model");
if (!warmindModel.ok || !glmModel.ok || !cloudModel.ok || !llamaCppModel.ok) {
  fail("verification model references are invalid");
}
// /switch moves a session onto PRIMARY_PROVIDER's served model; routing must probe that
// same provider, or children and the switched parent would follow different engines.
const routedProviders = servedProviders(loadedRouting.value.policy);
if (routedProviders.length !== 1 || routedProviders[0] !== PRIMARY_PROVIDER) {
  fail(`routing probes [${routedProviders.join(", ")}] but /switch serves the primaries under ${PRIMARY_PROVIDER}`);
}
// Routing follows whatever desktop-vllm serves now. The shell probes that once per
// subagent call; here the probe's answer is fixed input, so the policy is checked
// deterministically for every primary regardless of which one is live.
const reviewer = { workload: "subagent", profile: "general-review", agent: "code-reviewer" } as const;
const declaredCloud = { model: cloudModel.value, thinkingLevel: "high" as const };
const servedAs = (model: typeof glmModel.value): ServedModels => ({ "desktop-vllm": { ok: true, value: model } });
const routeTo = (
  parent: Parameters<typeof resolveModelRoute>[1]["parent"],
  served: ServedModels | undefined,
  agent: string = reviewer.agent,
) => resolveModelRoute(
  loadedRouting.value.policy,
  { ...reviewer, agent, parent, declared: declaredCloud, ...(served ? { served } : {}) },
  loadedRouting.value.digest,
);
const expectRoute = (
  route: ReturnType<typeof routeTo>,
  expected: Readonly<{ provider: string; id: string; thinkingLevel: string }>,
  message: string,
): void => {
  if (
    !route.ok ||
    route.value.kind !== "override" ||
    route.value.effective?.model.provider !== expected.provider ||
    route.value.effective?.model.id !== expected.id ||
    route.value.effective?.thinkingLevel !== expected.thinkingLevel
  ) {
    fail(`${message}: ${JSON.stringify(route.ok ? route.value.effective : route.error)}`);
  }
};
// A local parent's children follow the served model, keeping the parent's effort,
// even when the parent session is pinned to the other primary.
expectRoute(
  routeTo({ model: warmindModel.value, thinkingLevel: "max" }, servedAs(glmModel.value)),
  { provider: "desktop-vllm", id: "glm-5.3-flash-hyperflare-tp2-v16", thinkingLevel: "max" },
  "a WARMIND-pinned parent's child does not follow the served GLM",
);
expectRoute(
  routeTo({ model: glmModel.value, thinkingLevel: "low" }, servedAs(warmindModel.value)),
  { provider: "desktop-vllm", id: "warmind-1017-native", thinkingLevel: "low" },
  "a GLM-pinned parent's child does not follow the served WARMIND",
);
// Only desktop-vllm parents follow what desktop-vllm serves; another local
// provider's children stay on their parent, whatever the desktop is serving.
expectRoute(
  routeTo({ model: llamaCppModel.value, thinkingLevel: "medium" }, servedAs(glmModel.value)),
  { provider: "llama.cpp", id: "local-model", thinkingLevel: "medium" },
  "a llama.cpp parent's child does not stay on its parent",
);
// A cloud parent's children run locally on the served model at max effort...
expectRoute(
  routeTo({ model: cloudModel.value, thinkingLevel: "xhigh" }, servedAs(glmModel.value)),
  { provider: "desktop-vllm", id: "glm-5.3-flash-hyperflare-tp2-v16", thinkingLevel: "max" },
  "a cloud parent's child is not routed to the served local model at max",
);
// ...except its workers, which stay on the cloud parent.
expectRoute(
  routeTo({ model: cloudModel.value, thinkingLevel: "xhigh" }, servedAs(glmModel.value), "worker"),
  { provider: "openai-codex", id: "gpt-5.6-sol", thinkingLevel: "xhigh" },
  "a cloud parent's worker does not stay on the parent",
);
// Not knowing what is served is an error, never a silent fallback.
const blind = routeTo({ model: cloudModel.value, thinkingLevel: "high" }, undefined);
if (blind.ok || blind.error.kind !== "served-model-unknown") {
  fail("routing without a served model does not fail closed");
}
// A failed probe fails closed too, and the refusal carries the probe's reason.
const unreachable = routeTo(
  { model: cloudModel.value, thinkingLevel: "high" },
  { "desktop-vllm": { ok: false, error: "cannot reach desktop-vllm: connect ECONNREFUSED" } },
);
if (
  unreachable.ok ||
  unreachable.error.kind !== "served-model-unknown" ||
  !JSON.stringify(unreachable.error).includes("ECONNREFUSED")
) {
  fail(`routing after a failed probe does not fail closed with its reason: ${JSON.stringify(unreachable)}`);
}

const desktopProvider = field(field(readJson(modelsLink), "providers"), "desktop-vllm");
if (text(field(desktopProvider, "baseUrl")) !== "http://192.168.0.80:8000/v1") {
  fail("desktop-vllm does not target the workstation's OpenAI-compatible endpoint");
}
const localModels = list(field(desktopProvider, "models")).map(catalogModel);
const localIds = localModels.map((model) => model.id ?? "").sort();
if (JSON.stringify(localIds) !== JSON.stringify([...primaryModels].sort())) {
  fail(`desktop-vllm must list exactly the primaries ${primaryModels.join(", ")}; found ${localIds.join(", ")}`);
}
// Both engines answer any model id with whatever is loaded, so a pinned id keeps
// working across a primary switch; the entries differ only in context and input.
const expectedContext: Readonly<Record<(typeof primaryModels)[number], number>> = {
  "warmind-1017-native": 262_144,
  "deepseek-v4.1-flash-native": 262_144,
  // Capped at 400K in the catalog (2026-11-15): at the engine's full 1M both GLM builds spiral into
  // degenerate reasoning, so Pi must compact well before that.
  "glm-5.3-flash-hyperflare-tp2-v16": 400_000,
  "glm-5.3-flash-hyperflare-tp2-cyber-hybrid": 400_000,
};
for (const id of primaryModels) {
  const model = localModels.find((entry) => entry.id === id);
  if (!model) fail(`desktop-vllm is missing ${id}`);
  if (model.defaultThinkingLevel !== "max") fail(`${id} does not declare max as its model default`);
  for (const level of ["low", "high", "max"] as const) {
    if (model.thinkingLevelMap[level] !== level) fail(`${id} does not expose the ${level} reasoning contract`);
  }
  for (const level of ["minimal", "medium", "xhigh"] as const) {
    if (model.thinkingLevelMap[level] !== null) fail(`${id} does not hide unsupported ${level} reasoning`);
  }
  if (model.supportsDeveloperRole !== false || model.thinkingFormat !== "deepseek") {
    fail(`${id} does not use the system-role reasoning_content contract both engines serve`);
  }
  if (model.contextWindow !== expectedContext[id]) {
    fail(`${id} declares ${model.contextWindow} context, expected ${expectedContext[id]}`);
  }
}

const runtimeAgentDir = mkdtempSync(join(tmpdir(), "pi-routing-verify-"));
const installedThinkingLevel = settingsThinkingLevel(join(agentDir, "settings.json"));
copyFileSync(join(agentDir, "settings.json"), join(runtimeAgentDir, "settings.json"));
// Two fixtures in the isolated catalog. The cross-capability check needs a model
// that cannot think (upstream's built-in catalog rotates). The model-local-default
// checks need a model whose default differs from the global one; every local
// primary defaults to the global "max", so that model (default "high") is declared here.
const nonThinkingFixture = "verify-fixture/no-thinking";
const modelDefaultFixture = "verify-fixture/high-default";
// A thinking model with no model-local default, standing in for "any cloud model"
// (Gemini 3.1 Flash Lite, the previous stand-in, left the built-in catalog too).
const plainFixture = "verify-fixture/plain";
const installedCatalog = readJson(modelsLink);
const installedProviders = field(installedCatalog, "providers");
if (!isRecord(installedCatalog) || !isRecord(installedProviders)) fail(`${modelsLink} has no providers object`);
const fixtureCost = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
writeFileSync(
  join(runtimeAgentDir, "models.json"),
  JSON.stringify({
    ...installedCatalog,
    providers: {
      ...installedProviders,
      "verify-fixture": {
        baseUrl: "http://127.0.0.1:9/v1",
        api: "openai-completions",
        apiKey: "verify-fixture-key",
        models: [{
          id: "no-thinking",
          name: "Verification fixture without thinking",
          reasoning: false,
          input: ["text"],
          contextWindow: 8192,
          maxTokens: 1024,
          cost: fixtureCost,
        }, {
          id: "high-default",
          name: "Verification fixture with a high model default",
          reasoning: true,
          defaultThinkingLevel: "high",
          thinkingLevelMap: { minimal: null, low: "low", medium: null, high: "high", xhigh: null, max: "max" },
          input: ["text"],
          contextWindow: 8192,
          maxTokens: 1024,
          cost: fixtureCost,
          compat: { supportsDeveloperRole: false, supportsReasoningEffort: true, thinkingFormat: "deepseek" },
        }, {
          id: "plain",
          name: "Verification fixture that thinks with no model default",
          reasoning: true,
          input: ["text"],
          contextWindow: 8192,
          maxTokens: 1024,
          cost: fixtureCost,
        }],
      },
    },
  }, null, 2),
);
symlinkSync(routingLink, join(runtimeAgentDir, "model-routing.json"));
symlinkSync(join(agentDir, "extensions"), join(runtimeAgentDir, "extensions"));
for (const credentialFile of ["auth.json", "models-store.json"]) {
  const source = join(agentDir, credentialFile);
  if (existsSync(source)) copyFileSync(source, join(runtimeAgentDir, credentialFile));
}

function runtimeThinkingLevel(
  extraArgs: readonly string[],
  includeModel: boolean = true,
  model: string = modelDefaultFixture,
): string | undefined {
  const result = spawnSync(
    "pi",
    [
      "--mode",
      "rpc",
      "--no-session",
      ...(includeModel ? ["--model", model] : []),
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
    fail(`cannot inspect ${model} startup state: ${result.error?.message ?? result.stderr}`);
  }
  for (const line of result.stdout.split("\n")) {
    try {
      const event = rpcResponse(parseJson(line));
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
      const response = rpcResponse(parseJson(line));
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
  if (runtimeThinkingLevel([]) !== "high") fail("a model's high model default is not applied at startup");
  if (runtimeThinkingLevel([], true, "desktop-vllm/glm-5.3-flash-hyperflare-tp2-v16") !== "max") {
    fail("GLM v16 does not start at its max model default");
  }
  if (settingsThinkingLevel(join(runtimeAgentDir, "settings.json")) !== installedThinkingLevel) {
    fail("a model default mutated Pi's global cloud-model thinking default");
  }
  if (runtimeThinkingLevel(["--thinking", "low"]) !== "low") {
    fail("a model default overwrites an explicit child thinking level");
  }
  if (runtimeThinkingLevel(["--models", `${modelDefaultFixture}:low`], false) !== "low") {
    fail("a model default overwrites a scoped model's explicit thinking level");
  }
  if (runtimeThinkingLevel([
    "--models",
    `${modelDefaultFixture},openai-codex/gpt-5.6-sol:low`,
  ], false) !== "high") {
    fail("another scoped model's thinking pin suppresses a model default");
  }
  const crossCapability = await thinkingAfterCycle({
    startModel: nonThinkingFixture,
    models: `${nonThinkingFixture},${modelDefaultFixture}`,
    expectedProvider: "verify-fixture",
    expectedModel: "high-default",
    thinkingLevel: "low",
  });
  if (
    crossCapability.model !== modelDefaultFixture ||
    crossCapability.thinkingLevel !== "low"
  ) {
    fail("model cycling does not restore an explicit preference after startup clamping");
  }

  const isolatedSettingsPath = join(runtimeAgentDir, "settings.json");
  const isolatedSettings = readJson(isolatedSettingsPath);
  if (!isRecord(isolatedSettings)) fail(`${isolatedSettingsPath} is not a settings object`);
  writeFileSync(isolatedSettingsPath, JSON.stringify({ ...isolatedSettings, defaultThinkingLevel: "low" }, null, 2));
  const afterModelDefault = await thinkingAfterCycle({
    startModel: modelDefaultFixture,
    models: `${modelDefaultFixture},${plainFixture}`,
    expectedProvider: "verify-fixture",
    expectedModel: "plain",
  });
  if (
    afterModelDefault.model !== plainFixture ||
    afterModelDefault.thinkingLevel !== "low"
  ) {
    fail("leaving a model with its own default does not restore the cloud baseline thinking preference");
  }
  if (settingsThinkingLevel(isolatedSettingsPath) !== "low") {
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
      modelId: "warmind-1017-native",
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
      const thinking = rpcResponse(parseJson(line)).data?.thinkingLevel;
      return thinking ? [thinking] : [];
    } catch {
      return [];
    }
  })[0];
  if (resumedThinking !== "low") fail("resumed WARMIND session did not preserve its saved thinking level");

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
  const cloud = modelRuntime.getModel("openai-codex", "gpt-5.6-sol");
  if (!cloud) fail("cannot find cloud model for resumed SDK pin verification");
  await resumedSession.session.setModel(cloud);
  if (resumedSession.session.thinkingLevel !== "low") {
    fail("resumed SDK session discarded its explicit thinking preference on model switch");
  }
} finally {
  rmSync(resumeDir, { recursive: true, force: true });
}

// The Obsidian Claude plugin is also a Pi package via its conventional
// skills/ directory. Query Pi itself so this verifies the installed settings,
// package resolution, skill parsing, and command registration together.
const commandsResult = spawnSync(
  "pi",
  ["--mode", "rpc", "--no-session", "--no-tools"],
  {
    input: '{"type":"get_commands"}\n',
    encoding: "utf8",
    timeout: 10_000,
    env: { ...process.env, CORTEX_EXTRACTING: "1", PI_CODING_AGENT_DIR: agentDir },
  },
);
if (commandsResult.error || commandsResult.status !== 0) {
  fail(`cannot inspect Pi commands: ${commandsResult.error?.message ?? commandsResult.stderr}`);
}
const obsidianCommand = commandsResult.stdout.split("\n").flatMap((line) => {
  try {
    const response: unknown = parseJson(line);
    if (text(field(response, "type")) !== "response" || text(field(response, "command")) !== "get_commands") return [];
    return list(field(field(response, "data"), "commands"))
      .filter((command) => text(field(command, "name")) === "skill:obsidian-vault")
      .map((command) => ({
        path: text(field(field(command, "sourceInfo"), "path")) ?? text(field(command, "path")),
      }));
  } catch {
    return [];
  }
})[0];
if (!obsidianCommand) fail("the obsidian-vault skill is not registered as /skill:obsidian-vault");
const registeredCommands = commandsResult.stdout.split("\n").flatMap((line) => {
  try {
    const response: unknown = parseJson(line);
    if (text(field(response, "command")) !== "get_commands") return [];
    return list(field(field(response, "data"), "commands")).map((command) => text(field(command, "name")) ?? "");
  } catch {
    return [];
  }
});
if (!registeredCommands.includes("switch")) fail("the primary-switch extension does not register /switch");
const expectedObsidianSkill = resolve(
  process.env.HOME ?? "",
  "dev/claude-plugins/obsidian/skills/obsidian-vault/SKILL.md",
);
const installedObsidianSkill = obsidianCommand.path;
if (!installedObsidianSkill || resolve(installedObsidianSkill) !== expectedObsidianSkill) {
  fail(
    `obsidian-vault resolves to ${installedObsidianSkill ?? "an unknown path"}, ` +
      `expected canonical source ${expectedObsidianSkill}`,
  );
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
  `Pi install verified: primary local catalog (WARMIND, DeepSeek-V4.1 native, GLM v16, GLM cyber hybrid) and local-aware routing, ` +
    `Obsidian skill, ${discovered.length} agents, ` +
    `${packageAgentDirs.length} package agent dir(s), ${renderedAgents.size} current Loom render(s), ` +
    `panel roster available.\n`,
);
