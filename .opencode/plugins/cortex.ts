import type { Plugin } from "@opencode-ai/plugin";

const CORTEX_CLI = `${process.env.HOME}/.claude/plugins/cortex/engine/src/cli.ts`;
const GEMINI_ENV = `${process.env.HOME}/.config/sops-nix/secrets/rendered/gemini-env`;

// Track message count per session to avoid redundant extractions
const sessionMessageCount = new Map<string, number>();

export const CortexPlugin: Plugin = async ({ client, $, directory }) => {
  const log = (message: string, extra?: Record<string, unknown>) =>
    client.app.log({
      body: { service: "cortex", level: "info", message, extra: extra ?? {} },
    }).catch(() => {});

  const logError = (message: string, extra?: Record<string, unknown>) =>
    client.app.log({
      body: { service: "cortex", level: "error", message, extra: extra ?? {} },
    }).catch(() => {});

  let env: Record<string, string>;
  try {
    env = { ...process.env as Record<string, string>, ...(await loadGeminiEnv()) };
  } catch {
    env = process.env as Record<string, string>;
  }

  // Low-level SDK client for direct HTTP requests
  // Workaround: client.session.messages() has a URL interpolation bug
  // where {sessionID} becomes {id}, causing 500 errors
  const innerClient = (client as any).session._client ?? (client as any)._client;

  return {
    // Inject GEMINI_API_KEY into shell commands
    "shell.env": async (_input, output) => {
      const geminiEnv = await loadGeminiEnv();
      for (const [k, v] of Object.entries(geminiEnv)) {
        output.env[k] = v;
      }
    },

    // Inject cortex surface memories into system prompt
    "experimental.chat.system.transform": async (_input, output) => {
      try {
        const surfacePath = `${directory}/.claude/cortex-memory.local.md`;
        const file = Bun.file(surfacePath);
        if (await file.exists()) {
          const content = await file.text();
          if (content.trim()) {
            output.system.push(content);
          }
        }
      } catch {}
    },

    event: async ({ event }) => {
      // Session start: load cached surface markdown
      if (event.type === "session.created") {
        const cwd = event.properties.info.directory;
        if (!cwd) return;
        try {
          await $`bun ${CORTEX_CLI} load-surface ${cwd}`
            .env(env)
            .quiet()
            .nothrow();
        } catch (e) {
          await logError("load-surface failed", { error: String(e) });
        }
      }

      // Session idle: extract memories from transcript
      if (event.type === "session.idle") {
        const sessionID = event.properties.sessionID;

        try {
          // Fetch messages via low-level client to bypass SDK URL bug
          const msgRes = await innerClient.get({
            url: `/session/${sessionID}/message`,
          });
          const messages: Array<{ info: any; parts: any[] }> = msgRes.data ?? [];
          if (messages.length === 0) return;

          // Skip if no new messages since last extraction
          const prevCount = sessionMessageCount.get(sessionID) ?? 0;
          if (messages.length <= prevCount) return;
          sessionMessageCount.set(sessionID, messages.length);

          // Derive cwd from last assistant message, fallback to plugin directory
          let cwd = "";
          for (let i = messages.length - 1; i >= 0; i--) {
            const info = messages[i].info;
            if (info.role === "assistant" && (info as any).path?.cwd) {
              cwd = (info as any).path.cwd;
              break;
            }
          }
          if (!cwd) cwd = directory;

          // Convert to JSONL transcript
          const lines: string[] = [];
          for (const { info, parts } of messages) {
            for (const part of parts) {
              if (part.type === "text" && part.text) {
                lines.push(
                  JSON.stringify({ role: info.role, type: "text", text: part.text })
                );
              } else if (part.type === "tool" && part.state.status === "completed") {
                lines.push(
                  JSON.stringify({
                    role: "assistant",
                    type: "tool_use",
                    tool: part.tool,
                    input: part.state.input,
                  })
                );
                lines.push(
                  JSON.stringify({
                    role: "tool",
                    type: "tool_result",
                    tool: part.tool,
                    output: part.state.output,
                  })
                );
              }
            }
          }
          if (lines.length === 0) return;

          // Write temp files
          const tmpFile = `/tmp/cortex-opencode-${sessionID}.jsonl`;
          await Bun.write(tmpFile, lines.join("\n") + "\n");
          const hookInputFile = `/tmp/cortex-opencode-input-${sessionID}.json`;
          await Bun.write(hookInputFile, JSON.stringify({
            session_id: sessionID,
            transcript_path: tmpFile,
            cwd,
          }));

          // Extract → backfill → generate
          await $`cat ${hookInputFile} | bun ${CORTEX_CLI} extract`
            .env(env).quiet().nothrow();
          await $`bun ${CORTEX_CLI} backfill ${cwd}`
            .env(env).quiet().nothrow();
          await $`bun ${CORTEX_CLI} generate ${cwd}`
            .env(env).quiet().nothrow();

          // Cleanup
          try {
            await $`rm -f ${tmpFile} ${hookInputFile}`.quiet().nothrow();
          } catch {}
        } catch (e) {
          await logError("extraction failed", { error: String(e) });
        }
      }
    },
  };
}

async function loadGeminiEnv(): Promise<Record<string, string>> {
  try {
    const content = await Bun.file(GEMINI_ENV).text();
    const env: Record<string, string> = {};
    for (const line of content.split("\n")) {
      const trimmed = line.trim();
      if (!trimmed || trimmed.startsWith("#")) continue;
      const clean = trimmed.replace(/^export\s+/, "");
      const eq = clean.indexOf("=");
      if (eq === -1) continue;
      const key = clean.slice(0, eq);
      let val = clean.slice(eq + 1);
      if (
        (val.startsWith('"') && val.endsWith('"')) ||
        (val.startsWith("'") && val.endsWith("'"))
      ) {
        val = val.slice(1, -1);
      }
      env[key] = val;
    }
    return env;
  } catch {
    return {};
  }
}
