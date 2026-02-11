/**
 * Enforce agent model matches frontmatter declaration.
 * Blocks Task calls where model is missing or mismatches the agent's declared model.
 * Only active during loom orchestration (task graph exists).
 */

import { existsSync, readFileSync } from "node:fs";
import { execSync } from "node:child_process";
import { join } from "node:path";
import type { HookHandler, PreToolUseInput } from "../../types";
import {
  TASK_GRAPH_PATH, PHASE_AGENT_MAP, IMPL_AGENTS, REVIEW_AGENTS,
  UTILITY_AGENTS,
} from "../../config";

/** All agents whose model we validate */
const VALIDATED_AGENTS = new Set([
  ...Object.keys(PHASE_AGENT_MAP),
  ...IMPL_AGENTS,
  ...REVIEW_AGENTS,
]);

/** Resolve agent .md path — checks git root then home dir */
function resolveAgentPath(agentName: string): string | null {
  const candidates: string[] = [];

  try {
    const root = execSync("git rev-parse --show-toplevel", { encoding: "utf-8" }).trim();
    candidates.push(join(root, ".claude/agents", `${agentName}.md`));
  } catch {}

  candidates.push(join(process.env.HOME ?? "", ".claude/agents", `${agentName}.md`));

  return candidates.find((p) => existsSync(p)) ?? null;
}

/** Parse model field from YAML frontmatter */
function parseModelFromFrontmatter(filePath: string): string | null {
  try {
    const content = readFileSync(filePath, "utf-8");
    const fm = content.match(/^---\n([\s\S]*?)\n---/);
    if (!fm) return null;
    const modelLine = fm[1].match(/^model:\s*(.+)$/m);
    return modelLine ? modelLine[1].trim() : null;
  } catch {
    return null;
  }
}

const handler: HookHandler = async (stdin) => {
  if (!existsSync(TASK_GRAPH_PATH)) return { kind: "allow" };

  const input: PreToolUseInput = JSON.parse(stdin);
  if (input.tool_name !== "Task") return { kind: "allow" };

  const subagentType = (input.tool_input?.subagent_type as string) ?? "";

  // Only validate known loom agents, skip utility agents
  if (!VALIDATED_AGENTS.has(subagentType)) return { kind: "allow" };
  if (UTILITY_AGENTS.has(subagentType)) return { kind: "allow" };

  const agentPath = resolveAgentPath(subagentType);
  if (!agentPath) return { kind: "allow" };

  const declaredModel = parseModelFromFrontmatter(agentPath);

  if (!declaredModel) {
    return {
      kind: "block",
      message: [
        `BLOCKED: Agent "${subagentType}" has no model in frontmatter.`,
        "",
        `Add \`model: sonnet\` (or opus) to: ${agentPath}`,
      ].join("\n"),
    };
  }

  const requestedModel = (input.tool_input?.model as string) ?? null;

  if (!requestedModel) {
    return {
      kind: "block",
      message: [
        `BLOCKED: Task call for "${subagentType}" missing \`model\` parameter.`,
        "",
        `Frontmatter declares: model: ${declaredModel}`,
        `Add \`model: "${declaredModel}"\` to the Task tool call.`,
      ].join("\n"),
    };
  }

  if (requestedModel !== declaredModel) {
    return {
      kind: "block",
      message: [
        `BLOCKED: Model mismatch for "${subagentType}".`,
        "",
        `  Task call:   model: ${requestedModel}`,
        `  Frontmatter: model: ${declaredModel}`,
        "",
        `Use model: "${declaredModel}" or update agent frontmatter.`,
      ].join("\n"),
    };
  }

  return { kind: "allow" };
};

export default handler;
