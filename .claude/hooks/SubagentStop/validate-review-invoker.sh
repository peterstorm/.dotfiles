#!/bin/bash
# Validates that review-invoker agent called /review-pr skill
# Checks transcript for evidence of skill invocation

INPUT=$(cat)

# Read agent_id from stdin and get agent type from stored file (set by SubagentStart hook)
AGENT_ID=$(echo "$INPUT" | jq -r '.agent_id // empty')
AGENT_TYPE=""
if [[ -n "$AGENT_ID" && -f "/tmp/claude-subagents/${AGENT_ID}.type" ]]; then
  AGENT_TYPE=$(cat "/tmp/claude-subagents/${AGENT_ID}.type")
fi

# Only validate review-invoker agents
if [ "$AGENT_TYPE" != "review-invoker" ]; then
  exit 0
fi

# Read transcript text from JSONL file
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.agent_transcript_path // empty')
source ~/.claude/hooks/helpers/parse-transcript.sh
AGENT_OUTPUT=""
if [[ -n "$TRANSCRIPT_PATH" ]]; then
  AGENT_OUTPUT=$(parse_transcript "$TRANSCRIPT_PATH")
fi

# Grep transcript for evidence of /review-pr invocation
if echo "$AGENT_OUTPUT" | grep -qiE '(review-pr|/review-pr|Launching skill: review-pr)'; then
  echo "review-invoker correctly invoked /review-pr (transcript evidence found)" >&2
  exit 0
fi

echo "WARNING: review-invoker may not have invoked /review-pr (no transcript evidence found)" >&2
echo "Actual quality validation is done by store-reviewer-findings.sh" >&2
exit 0
