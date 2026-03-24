/**
 * Loom Bridge Plugin for OpenCode
 *
 * Translates OpenCode's plugin hooks into Loom's expected handler
 * input format and calls the Loom engine handlers directly.
 *
 * OpenCode hook → Loom handler mapping:
 *   tool.execute.before (task)            → SubagentStart (mark-subagent-active)
 *                                           + PreToolUse validators (phase-order, task-execution, etc.)
 *   tool.execute.after  (task)            → SubagentStop  (dispatch → advance-phase, update-task-status, etc.)
 *   tool.execute.before (edit/write/bash)  → PreToolUse    (block-direct-edits, guard-state-file)
 *   session.created event                 → SessionStart   (cleanup-stale-subagents)
 *
 * Known limitations:
 *   - Synthetic transcript lacks tool_use/tool_result blocks. This means:
 *     - update-task-status: files_modified is always [], tests_passed falls back to
 *       git-diff-based detection only (no anti-spoofed bash output parsing)
 *     - advance-phase: artifact discovery from Write tool calls is unavailable,
 *       falls back to filesystem scanning
 *   - Review/spec-check findings extraction works because those markers are in
 *     the agent's final text output, which IS captured in output.output
 */

import type { Plugin } from "@opencode-ai/plugin";

// --- Loom engine root (no changes to loom codebase) ---

const LOOM_ENGINE = `${process.env.HOME}/dev/claude-plugins/loom/engine/src`;

// --- Tool name translation: OpenCode (lowercase) → Claude Code (PascalCase) ---

const TOOL_NAME_MAP: Record<string, string> = {
  edit: "Edit",
  write: "Write",
  patch: "MultiEdit",
  bash: "Bash",
  task: "Task",
  read: "Read",
  glob: "Glob",
  grep: "Grep",
  webfetch: "WebFetch",
  todowrite: "TodoWrite",
  question: "Question",
  skill: "Skill",
};

// Track tools we've warned about to avoid log spam
const warnedUnmappedTools = new Set<string>();

function mapToolName(
  tool: string,
  log: (msg: string, extra?: Record<string, unknown>) => void,
): string {
  const mapped = TOOL_NAME_MAP[tool];
  if (!mapped && !warnedUnmappedTools.has(tool)) {
    warnedUnmappedTools.add(tool);
    log(`unmapped tool name: "${tool}" — passing through as-is`, { tool });
  }
  return mapped ?? tool;
}

// --- Lazy handler imports (loaded once, cached) ---

type HookResult =
  | { kind: "allow" }
  | { kind: "block"; message: string }
  | { kind: "error"; message: string }
  | { kind: "passthrough" };

type HookHandler = (stdin: string, args: string[]) => Promise<HookResult>;

const handlerCache = new Map<string, HookHandler>();

async function loadHandler(hookType: string, handlerName: string): Promise<HookHandler> {
  const key = `${hookType}/${handlerName}`;
  const cached = handlerCache.get(key);
  if (cached) return cached;

  const mod = await import(`${LOOM_ENGINE}/handlers/${hookType}/${handlerName}.ts`);
  const handler: HookHandler = mod.default;
  handlerCache.set(key, handler);
  return handler;
}

// --- Sentinel for block errors that must propagate through catch blocks ---

class LoomBlockError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LoomBlockError";
  }
}

// --- Helper: run a gatekeeper handler, throw on block ---

async function runGatekeeper(
  hookType: string,
  handlerName: string,
  stdinJson: string,
  log: (msg: string, extra?: Record<string, unknown>) => void,
): Promise<void> {
  try {
    const handler = await loadHandler(hookType, handlerName);
    const result = await handler(stdinJson, []);

    if (result.kind === "block") {
      throw new LoomBlockError(result.message);
    }
    if (result.kind === "error") {
      log(`loom handler ${handlerName} error: ${result.message}`);
    }
  } catch (e) {
    if (e instanceof LoomBlockError) throw e;
    log(`loom handler ${handlerName} failed: ${e}`);
  }
}

// --- Helper: run an event listener handler (never blocks) ---

async function runListener(
  hookType: string,
  handlerName: string,
  stdinJson: string,
  log: (msg: string, extra?: Record<string, unknown>) => void,
): Promise<void> {
  try {
    const handler = await loadHandler(hookType, handlerName);
    await handler(stdinJson, []);
  } catch (e) {
    log(`loom listener ${handlerName} failed: ${e}`);
  }
}

// --- Input builders ---

function buildPreToolUseInput(
  tool: string,
  args: Record<string, unknown>,
  sessionID: string,
  log: (msg: string, extra?: Record<string, unknown>) => void,
): string {
  return JSON.stringify({
    tool_name: mapToolName(tool, log),
    tool_input: args,
    session_id: sessionID,
  });
}

function buildSubagentStartInput(
  sessionID: string,
  callID: string,
  args: Record<string, unknown>,
): string {
  return JSON.stringify({
    session_id: sessionID,
    agent_id: callID,
    agent_type: extractAgentType(args),
  });
}

function buildSubagentStopInput(
  sessionID: string,
  callID: string,
  args: Record<string, unknown>,
  transcriptPath: string | null,
): string {
  return JSON.stringify({
    session_id: sessionID,
    agent_id: callID,
    agent_type: extractAgentType(args),
    agent_transcript_path: transcriptPath,
  });
}

function extractAgentType(args: Record<string, unknown>): string {
  return (args.subagent_type as string) ?? "";
}

// --- Synthetic transcript ---
// Creates a JSONL file in the format Loom's parsers expect so that
// store-reviewer-findings and store-spec-check-findings can parse
// structured markers (CRITICAL_COUNT, etc.) from the agent's text output.
//
// Format: {"message":{"role":"assistant","content":[{"type":"text","text":"..."}]}}
//
// Limitation: does NOT contain tool_use/tool_result blocks, so parsers
// that extract files_modified or bash test output will get empty results.

async function writeSyntheticTranscript(
  sessionID: string,
  callID: string,
  output: string,
): Promise<string | null> {
  if (!output) return null;

  try {
    const tmpPath = `/tmp/loom-opencode-transcript-${sessionID}-${callID}.jsonl`;
    const line = JSON.stringify({
      message: {
        role: "assistant",
        content: [{ type: "text", text: output }],
      },
    });
    await Bun.write(tmpPath, line + "\n");
    return tmpPath;
  } catch {
    return null;
  }
}

async function cleanupTranscript(path: string | null): Promise<void> {
  if (!path) return;
  try {
    const { unlink } = await import("node:fs/promises");
    await unlink(path);
  } catch {}
}

// --- Handler registry (for eager loading at init) ---

const ALL_HANDLERS: ReadonlyArray<readonly [string, string]> = [
  ["pre-tool-use", "block-direct-edits"],
  ["pre-tool-use", "guard-state-file"],
  ["pre-tool-use", "validate-phase-order"],
  ["pre-tool-use", "validate-task-execution"],
  ["pre-tool-use", "validate-template-substitution"],
  ["pre-tool-use", "validate-agent-model"],
  ["pre-tool-use", "validate-agent-skill"],
  ["subagent-start", "mark-subagent-active"],
  ["subagent-stop", "dispatch"],
  ["session-start", "cleanup-stale-subagents"],
] as const;

const TASK_GATEKEEPERS = [
  "validate-phase-order",
  "validate-task-execution",
  "validate-template-substitution",
  "validate-agent-model",
  "validate-agent-skill",
] as const;

const FILE_TOOL_GATEKEEPERS = ["block-direct-edits"] as const;
const BASH_GATEKEEPERS = ["guard-state-file"] as const;

// ===== Plugin Entry Point =====

export const LoomPlugin: Plugin = async ({ client }) => {
  const log = (message: string, extra?: Record<string, unknown>) =>
    client.app
      .log({
        body: { service: "loom", level: "info", message, extra: extra ?? {} },
      })
      .catch(() => {});

  const logError = (message: string, extra?: Record<string, unknown>) =>
    client.app
      .log({
        body: { service: "loom", level: "error", message, extra: extra ?? {} },
      })
      .catch(() => {});

  // --- Eager-load all handlers at plugin init ---
  // Fail loudly if any handler can't be imported (missing deps, bad paths, etc.)
  // rather than silently degrading at runtime.
  let loadFailures = 0;
  for (const [hookType, name] of ALL_HANDLERS) {
    try {
      await loadHandler(hookType, name);
    } catch (e) {
      loadFailures++;
      await logError(`failed to load handler ${hookType}/${name}`, {
        error: String(e),
      });
    }
  }

  if (loadFailures > 0) {
    await logError(
      `loom bridge: ${loadFailures}/${ALL_HANDLERS.length} handlers failed to load`,
    );
  } else {
    await log(
      `loom bridge initialized — all ${ALL_HANDLERS.length} handlers loaded`,
    );
  }

  return {
    // ===== tool.execute.before =====
    // Handles:
    //  1. Task tool → run gatekeepers FIRST, then mark subagent active (only if allowed)
    //  2. Edit/Write/Patch → run block-direct-edits
    //  3. Bash → run guard-state-file
    "tool.execute.before": async (input, output) => {
      const tool = input.tool;
      const sessionID = input.sessionID;
      const args = output.args ?? {};

      // --- Task tool: subagent is about to start ---
      if (tool === "task") {
        // 1. Run all PreToolUse gatekeepers FIRST
        //    If any blocks, we throw before marking the subagent active.
        //    This prevents stale .active flags from orphaned subagent starts.
        const preToolInput = buildPreToolUseInput(tool, args, sessionID, logError);
        for (const handler of TASK_GATEKEEPERS) {
          await runGatekeeper("pre-tool-use", handler, preToolInput, logError);
        }

        // 2. Gatekeepers passed — now safe to mark subagent active
        const startInput = buildSubagentStartInput(sessionID, input.callID, args);
        await runListener(
          "subagent-start",
          "mark-subagent-active",
          startInput,
          logError,
        );
        return;
      }

      // --- File-modifying tools: block direct edits from orchestrator ---
      if (tool === "edit" || tool === "write" || tool === "patch") {
        const preToolInput = buildPreToolUseInput(tool, args, sessionID, logError);
        for (const handler of FILE_TOOL_GATEKEEPERS) {
          await runGatekeeper("pre-tool-use", handler, preToolInput, logError);
        }
        return;
      }

      // --- Bash tool: guard state files ---
      if (tool === "bash") {
        const preToolInput = buildPreToolUseInput(tool, args, sessionID, logError);
        for (const handler of BASH_GATEKEEPERS) {
          await runGatekeeper("pre-tool-use", handler, preToolInput, logError);
        }
        return;
      }
    },

    // ===== tool.execute.after =====
    // Handles:
    //  Task tool completed → SubagentStop (dispatch → advance-phase, update-task-status, etc.)
    "tool.execute.after": async (input, output) => {
      if (input.tool !== "task") return;

      const sessionID = input.sessionID;
      const callID = input.callID;
      const args = input.args ?? {};

      // Create synthetic transcript from the Task tool's text output
      const transcriptPath = await writeSyntheticTranscript(
        sessionID,
        callID,
        output.output,
      );

      const stopInput = buildSubagentStopInput(
        sessionID,
        callID,
        args,
        transcriptPath,
      );

      // dispatch is the single entry point for all SubagentStop logic.
      // It internally runs cleanup-subagent-flag, then routes by agent category:
      //   phase agents  → advance-phase
      //   impl agents   → update-task-status
      //   review agents → store-reviewer-findings
      //   spec-check    → store-spec-check-findings
      await runListener("subagent-stop", "dispatch", stopInput, logError);

      await cleanupTranscript(transcriptPath);

      await log("subagent completed", {
        agent_type: extractAgentType(args),
        callID,
      });
    },

    // ===== event: session lifecycle =====
    event: async ({ event }) => {
      if (event.type === "session.created") {
        const sessionID =
          (event.properties as Record<string, unknown>)?.sessionID ?? "";
        const stdinJson = JSON.stringify({ session_id: sessionID });
        await runListener(
          "session-start",
          "cleanup-stale-subagents",
          stdinJson,
          logError,
        );
        await log("session created — cleaned up stale subagent files");
      }
    },
  };
};
