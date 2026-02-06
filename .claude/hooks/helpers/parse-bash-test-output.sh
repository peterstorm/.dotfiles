#!/bin/bash
# Extract test output ONLY from Bash tool_use/tool_result pairs in JSONL transcript
# Anti-spoofing: ignores free text — only returns output from actual test commands
#
# Matches: mvn test, mvn verify, ./gradlew test, npm test, npx vitest,
#          npx jest, pytest, cargo test, go test, dotnet test, mix test
#
# Usage:
#   source ~/.claude/hooks/helpers/parse-bash-test-output.sh
#   TEST_OUTPUT=$(parse_bash_test_output "/path/to/transcript.jsonl")
#
# Or standalone:
#   bash ~/.claude/hooks/helpers/parse-bash-test-output.sh "/path/to/transcript.jsonl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_UTILS_DIR="$SCRIPT_DIR/../ts-utils/dist"

parse_bash_test_output() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  if ! command -v node &>/dev/null; then
    echo "ERROR: node not found - required for parse-bash-test-output" >&2
    return 1
  fi

  node "$TS_UTILS_DIR/parse-bash-test-output.js" "$transcript_path" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_bash_test_output "$1"
fi
