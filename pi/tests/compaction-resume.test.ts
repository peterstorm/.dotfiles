// Contract for overlays/patches/pi-autocontinue-after-compact.patch, unit level: how the working
// context is shaped before agent.continue() resumes a turn after threshold compaction.
// agent.continue() rejects an assistant-tailed transcript, so the tail must be repaired first.
// End-to-end behaviour is covered by tests/pi-compaction-autocontinue-contract.sh.
import { afterEach, describe, expect, it } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createAgentSession, SessionManager, SettingsManager } from "@earendil-works/pi-coding-agent";

const scratch: string[] = [];
afterEach(() => {
  for (const directory of scratch.splice(0)) rmSync(directory, { recursive: true, force: true });
});

type Message = Readonly<{ role: string; stopReason?: string; content: unknown; timestamp: number }>;
type ResumablePart = Readonly<{
  agent: { state: { messages: Message[] }; hasQueuedMessages(): boolean };
  _prepareTurnResumeAfterCompaction(): Promise<boolean>;
  getFollowUpMessages(): readonly string[];
  dispose(): void;
}>;

const user = (text: string): Message => ({ role: "user", content: [{ type: "text", text }], timestamp: 1 });
const assistant = (stopReason: string): Message => ({
  role: "assistant",
  stopReason,
  content: [{ type: "text", text: "answer" }],
  timestamp: 2,
});

const sessionWith = async (messages: readonly Message[]): Promise<ResumablePart> => {
  const cwd = mkdtempSync(join(tmpdir(), "pi-compaction-resume-"));
  scratch.push(cwd);
  const { session } = await createAgentSession({
    cwd,
    agentDir: cwd,
    settingsManager: SettingsManager.inMemory(),
    sessionManager: SessionManager.inMemory(cwd),
  });
  const resumable = session as unknown as ResumablePart;
  resumable.agent.state.messages = [...messages];
  return resumable;
};

describe("resuming a turn after threshold compaction", () => {
  it("leaves a user-tailed context alone", async () => {
    const session = await sessionWith([user("hi")]);
    try {
      expect(await session._prepareTurnResumeAfterCompaction()).toBe(true);
      expect(session.agent.state.messages.map((m) => m.role)).toEqual(["user"]);
      expect(session.agent.hasQueuedMessages()).toBe(false);
    } finally {
      session.dispose();
    }
  });

  it("drops a failed assistant tail so the loop resumes from the preceding message", async () => {
    const session = await sessionWith([user("hi"), assistant("error")]);
    try {
      expect(await session._prepareTurnResumeAfterCompaction()).toBe(true);
      expect(session.agent.state.messages.map((m) => m.role)).toEqual(["user"]);
      expect(session.agent.hasQueuedMessages()).toBe(false);
    } finally {
      session.dispose();
    }
  });

  it("queues a continuation prompt after a completed assistant tail with nothing queued", async () => {
    const session = await sessionWith([user("hi"), assistant("stop")]);
    try {
      expect(await session._prepareTurnResumeAfterCompaction()).toBe(true);
      expect(session.agent.state.messages.map((m) => m.role)).toEqual(["user", "assistant"]);
      expect(session.getFollowUpMessages().join("\n")).toContain("[auto-compacted]");
    } finally {
      session.dispose();
    }
  });

  it("does not add a second prompt when the user already queued one", async () => {
    const session = await sessionWith([user("hi"), assistant("stop")]);
    try {
      await (session as unknown as { _queueFollowUp(text: string): Promise<void> })._queueFollowUp("my follow-up");
      expect(await session._prepareTurnResumeAfterCompaction()).toBe(true);
      expect(session.getFollowUpMessages()).toEqual(["my follow-up"]);
    } finally {
      session.dispose();
    }
  });
});
