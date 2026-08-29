#!/usr/bin/env bun
import { spawn } from "node:child_process";
import { copyFileSync, createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { StringDecoder } from "node:string_decoder";
import { join, resolve } from "node:path";

export type JsonlState = Readonly<{ carry: string }>;
export type JsonlStep = Readonly<{ lines: readonly string[]; state: JsonlState }>;

export const splitJsonl = (state: JsonlState, decodedChunk: string): JsonlStep => {
  const records = `${state.carry}${decodedChunk}`.split("\n");
  const carry = records.pop() ?? "";
  return {
    lines: records.map((line) => line.endsWith("\r") ? line.slice(0, -1) : line),
    state: { carry },
  };
};

const isRecord = (value: unknown): value is Readonly<Record<string, unknown>> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const isStringArray = (value: unknown): value is readonly string[] =>
  Array.isArray(value) && value.every((item) => typeof item === "string");

export const isPlanningBoundary = (value: unknown): boolean => {
  if (!isRecord(value) || value.current_phase !== "execute" || value.current_wave !== 1) return false;
  if (!Array.isArray(value.tasks) || value.tasks.length === 0) return false;
  if (!value.tasks.every((task) => isRecord(task) && task.status === "pending")) return false;
  if (!Array.isArray(value.executing_tasks) || value.executing_tasks.length !== 0) return false;
  if (!isRecord(value.wave_gates) || Object.keys(value.wave_gates).length === 0) return false;
  return Object.values(value.wave_gates).every((gate) => isRecord(gate) &&
    gate.impl_complete === false && gate.reviews_complete === false && gate.tests_passed === null);
};

type DriverConfig = Readonly<{
  worktree: string;
  runDir: string;
  model: string;
  prompt: string;
  timeoutMinutes: number;
}>;

type ParseResult =
  | Readonly<{ ok: true; value: DriverConfig }>
  | Readonly<{ ok: false; error: string }>;

export const parseDriverArgs = (args: readonly string[]): ParseResult => {
  const values = new Map<string, string>();
  for (let index = 0; index < args.length; index += 2) {
    const key = args[index];
    const value = args[index + 1];
    if (!key?.startsWith("--") || value === undefined) {
      return { ok: false, error: `expected --name value pairs; stopped at ${key ?? "<end>"}` };
    }
    if (!["--worktree", "--run-dir", "--model", "--prompt", "--timeout-minutes"].includes(key)) {
      return { ok: false, error: `unknown option: ${key}` };
    }
    if (values.has(key)) return { ok: false, error: `duplicate option: ${key}` };
    values.set(key, value);
  }
  const worktree = values.get("--worktree");
  const runDir = values.get("--run-dir");
  const model = values.get("--model");
  const prompt = values.get("--prompt");
  if (!worktree?.trim()) return { ok: false, error: "missing --worktree" };
  if (!runDir?.trim()) return { ok: false, error: "missing --run-dir" };
  if (!model?.trim()) return { ok: false, error: "missing --model" };
  if (!prompt?.trim()) return { ok: false, error: "missing --prompt" };
  const timeoutRaw = values.get("--timeout-minutes") ?? "240";
  const timeoutMinutes = Number(timeoutRaw);
  if (!Number.isSafeInteger(timeoutMinutes) || timeoutMinutes < 1 || timeoutMinutes > 720) {
    return { ok: false, error: "--timeout-minutes must be an integer from 1 to 720" };
  }
  return {
    ok: true,
    value: {
      worktree: resolve(worktree),
      runDir: resolve(runDir),
      model,
      prompt,
      timeoutMinutes,
    },
  };
};

const parseJson = (line: string): unknown => JSON.parse(line) as unknown;
const timestamp = (): string => new Date().toISOString();

const readBoundary = (path: string): boolean => {
  try {
    return isPlanningBoundary(parseJson(readFileSync(path, "utf8")));
  } catch {
    return false;
  }
};

const textOf = (value: unknown): string => typeof value === "string" ? value : "";

const answerOfResponse = (response: Readonly<Record<string, unknown>>): string => {
  if (response.cancelled === true) return "CANCELLED";
  if (response.confirmed !== undefined) return String(response.confirmed);
  return textOf(response.value);
};

const confirmationResponse = (id: string, rawAnswer: string): Readonly<Record<string, unknown>> => {
  const answer = rawAnswer.trim().toLowerCase();
  if (answer === "x") return { type: "extension_ui_response", id, cancelled: true };
  if (answer === "y" || answer === "yes") return { type: "extension_ui_response", id, confirmed: true };
  if (answer === "n" || answer === "no") return { type: "extension_ui_response", id, confirmed: false };
  throw new Error(`invalid confirmation: ${rawAnswer}`);
};

const run = async (config: DriverConfig): Promise<number> => {
  if (!existsSync(config.worktree)) throw new Error(`worktree does not exist: ${config.worktree}`);
  if (!process.stdin.isTTY) throw new Error("supervised RPC driver requires an operator TTY");
  mkdirSync(config.runDir, { recursive: true });

  const eventsPath = join(config.runDir, "rpc-events.jsonl");
  const commandsPath = join(config.runDir, "rpc-commands.jsonl");
  const interviewPath = join(config.runDir, "interview.md");
  const graphPath = join(config.worktree, ".claude/state/active_task_graph.json");
  const sessionDir = join(config.runDir, "pi-session");
  mkdirSync(sessionDir, { recursive: true });
  writeFileSync(interviewPath, "# Supervised RPC interview\n\n", { flag: "wx" });

  const events = createWriteStream(eventsPath, { flags: "wx", mode: 0o600 });
  const commands = createWriteStream(commandsPath, { flags: "wx", mode: 0o600 });
  const operator = createInterface({ input: process.stdin, output: process.stderr });
  const child = spawn("pi", [
    "--mode", "rpc",
    "--model", config.model,
    "--session-dir", sessionDir,
    "--name", "fugue-f1-planning",
    "--approve",
  ], {
    cwd: config.worktree,
    env: {
      ...process.env,
      PI_SKIP_VERSION_CHECK: "1",
      PI_TELEMETRY: "0",
    },
    stdio: ["pipe", "pipe", "inherit"],
  });

  let sessionFile: string | null = null;
  let boundaryAt: string | null = null;
  let abortSent = false;
  let protocolError: string | null = null;
  let settled = false;
  let closing = false;
  let uiQueue = Promise.resolve();

  const send = (command: Readonly<Record<string, unknown>>): void => {
    const line = JSON.stringify(command);
    commands.write(`${JSON.stringify({ at: timestamp(), command })}\n`);
    child.stdin.write(`${line}\n`);
  };

  const appendInterview = (request: Readonly<Record<string, unknown>>, response: Readonly<Record<string, unknown>>): void => {
    const title = textOf(request.title) || textOf(request.message) || textOf(request.method);
    const answer = answerOfResponse(response);
    writeFileSync(interviewPath, `## ${timestamp()} — ${textOf(request.method)}\n\n**Question:** ${title}\n\n**Answer:** ${answer}\n\n`, { flag: "a" });
  };

  const handleUi = async (request: Readonly<Record<string, unknown>>): Promise<void> => {
    const id = textOf(request.id);
    const method = textOf(request.method);
    if (!id) throw new Error("extension UI request has no id");
    if (["notify", "setStatus", "setWidget", "setTitle", "set_editor_text"].includes(method)) return;

    process.stderr.write(`\n[${method}] ${textOf(request.title)}\n`);
    if (request.message !== undefined) process.stderr.write(`${textOf(request.message)}\n`);
    let response: Readonly<Record<string, unknown>>;
    if (method === "select") {
      if (!isStringArray(request.options) || request.options.length === 0) throw new Error("select request has no options");
      request.options.forEach((option, index) => process.stderr.write(`  ${index + 1}. ${option}\n`));
      const raw = (await operator.question("Choose an option number, or x to cancel: ")).trim();
      if (/^x$/i.test(raw)) response = { type: "extension_ui_response", id, cancelled: true };
      else {
        const selected = Number(raw);
        if (!Number.isSafeInteger(selected) || selected < 1 || selected > request.options.length) {
          throw new Error(`invalid selection: ${raw}`);
        }
        const selectedOption = request.options[selected - 1];
        if (selectedOption === undefined) throw new Error(`invalid selection: ${raw}`);
        response = { type: "extension_ui_response", id, value: selectedOption };
      }
    } else if (method === "confirm") {
      response = confirmationResponse(id, await operator.question("Confirm? [y/n/x]: "));
    } else if (method === "input" || method === "editor") {
      const raw = await operator.question("Answer exactly from the frozen answer key (x alone cancels): ");
      response = raw === "x"
        ? { type: "extension_ui_response", id, cancelled: true }
        : { type: "extension_ui_response", id, value: raw };
    } else {
      throw new Error(`unsupported extension UI method: ${method}`);
    }
    appendInterview(request, response);
    send(response);
  };

  const stopAtBoundary = (): void => {
    if (abortSent || !readBoundary(graphPath)) return;
    boundaryAt = timestamp();
    abortSent = true;
    writeFileSync(join(config.runDir, "boundary-detected.json"), `${JSON.stringify({ at: boundaryAt }, null, 2)}\n`, { mode: 0o600 });
    send({ id: "boundary-abort", type: "abort" });
  };

  const terminate = (): void => {
    if (closing) return;
    closing = true;
    clearInterval(boundaryPoll);
    clearTimeout(timeout);
    operator.close();
    child.stdin.end();
    child.kill("SIGTERM");
    setTimeout(() => child.kill("SIGKILL"), 5_000).unref();
  };

  const onEvent = (event: unknown): void => {
    if (!isRecord(event)) throw new Error("RPC frame is not an object");
    if (event.type === "response" && event.id === "initial-state" && isRecord(event.data)) {
      sessionFile = typeof event.data.sessionFile === "string" ? event.data.sessionFile : null;
    }
    if (event.type === "message_update" && isRecord(event.assistantMessageEvent) && event.assistantMessageEvent.type === "text_delta") {
      process.stdout.write(textOf(event.assistantMessageEvent.delta));
    }
    if (event.type === "extension_ui_request") {
      uiQueue = uiQueue.then(() => handleUi(event)).catch((error: unknown) => {
        protocolError = error instanceof Error ? error.message : String(error);
        send({ id: "ui-error-abort", type: "abort" });
      });
    }
    if (event.type === "extension_error") protocolError = `extension error: ${textOf(event.error)}`;
    if (event.type === "agent_settled") {
      settled = true;
      stopAtBoundary();
      if (!boundaryAt) setTimeout(terminate, 1_000).unref();
    }
    if (event.type === "response" && event.id === "boundary-abort") setTimeout(terminate, 1_000).unref();
  };

  const decoder = new StringDecoder("utf8");
  let jsonlState: JsonlState = { carry: "" };
  child.stdout.on("data", (chunk: Buffer) => {
    const step = splitJsonl(jsonlState, decoder.write(chunk));
    jsonlState = step.state;
    for (const line of step.lines) {
      events.write(`${line}\n`);
      if (line === "") continue;
      try { onEvent(parseJson(line)); }
      catch (error) {
        protocolError = error instanceof Error ? error.message : String(error);
        if (!abortSent) send({ id: "protocol-error-abort", type: "abort" });
      }
    }
  });
  child.stdout.on("end", () => {
    const final = decoder.end();
    const step = splitJsonl(jsonlState, final);
    jsonlState = step.state;
    for (const line of step.lines) events.write(`${line}\n`);
    if (jsonlState.carry !== "") protocolError = "Pi stdout ended with an unterminated JSONL frame";
  });

  const boundaryPoll = setInterval(stopAtBoundary, 50);
  const timeout = setTimeout(() => {
    protocolError = `driver timeout after ${config.timeoutMinutes} minutes`;
    if (!abortSent) send({ id: "timeout-abort", type: "abort" });
    setTimeout(terminate, 2_000).unref();
  }, config.timeoutMinutes * 60_000);

  process.once("SIGINT", () => {
    protocolError = "operator interrupted the run";
    if (!abortSent) send({ id: "operator-abort", type: "abort" });
    setTimeout(terminate, 1_000).unref();
  });

  send({ id: "initial-state", type: "get_state" });
  send({ id: "loom-prompt", type: "prompt", message: config.prompt });

  const exit = await new Promise<Readonly<{ code: number | null; signal: NodeJS.Signals | null }>>((resolveExit) => {
    child.once("exit", (code, signal) => resolveExit({ code, signal }));
  });
  clearInterval(boundaryPoll);
  clearTimeout(timeout);
  operator.close();
  events.end();
  commands.end();

  let sessionCopied = false;
  if (sessionFile && existsSync(sessionFile)) {
    copyFileSync(sessionFile, join(config.runDir, "session.jsonl"));
    sessionCopied = true;
  }
  const passed = boundaryAt !== null && sessionCopied && protocolError === null;
  writeFileSync(join(config.runDir, "driver-receipt.json"), `${JSON.stringify({
    passed,
    boundary_at: boundaryAt,
    abort_sent: abortSent,
    agent_settled: settled,
    session_file: sessionFile,
    session_copied: sessionCopied,
    protocol_error: protocolError,
    process_exit: exit,
    finished_at: timestamp(),
  }, null, 2)}\n`, { mode: 0o600 });
  return passed ? 0 : 1;
};

if (import.meta.main) {
  const parsed = parseDriverArgs(process.argv.slice(2));
  if (!parsed.ok) {
    console.error(parsed.error);
    console.error("usage: rpc-driver.ts --worktree PATH --run-dir PATH --model SELECTOR --prompt TEXT [--timeout-minutes N]");
    process.exit(2);
  }
  run(parsed.value)
    .then((code) => process.exit(code))
    .catch((error: unknown) => {
      console.error(error instanceof Error ? error.message : String(error));
      process.exit(1);
    });
}
