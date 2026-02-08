/**
 * Validate review-invoker called /review-pr skill.
 * Warning only — actual validation done by store-reviewer-findings.
 */

import type { HookHandler, SubagentStopInput } from "../../types";
import { parseTranscript } from "../../parsers/parse-transcript";

const handler: HookHandler = async (stdin) => {
  const input: SubagentStopInput = JSON.parse(stdin);

  if (input.agent_type !== "review-invoker") return { kind: "passthrough" };

  const transcript = input.agent_transcript_path
    ? parseTranscript(input.agent_transcript_path)
    : "";

  if (/(review-pr|\/review-pr|Launching skill: review-pr)/i.test(transcript)) {
    process.stderr.write("review-invoker correctly invoked /review-pr\n");
  } else {
    process.stderr.write("WARNING: review-invoker may not have invoked /review-pr\n");
  }

  return { kind: "passthrough" };
};

export default handler;
