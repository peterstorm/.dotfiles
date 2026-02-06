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

parse_bash_test_output() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  TRANSCRIPT_PATH="$transcript_path" python3 -c "
import os, sys, json

path = os.environ['TRANSCRIPT_PATH']

# Test runner command patterns (anchored to common invocations)
TEST_PATTERNS = [
    'mvn test', 'mvn verify', 'mvn -pl', 'mvnw test', 'mvnw verify',
    './gradlew test', './gradlew check', 'gradle test', 'gradle check',
    'npm test', 'npm run test', 'npx vitest', 'npx jest',
    'yarn test', 'pnpm test', 'bun test',
    'pytest', 'python -m pytest', 'python3 -m pytest',
    'cargo test', 'go test', 'dotnet test', 'mix test',
    'make test', 'make check',
]

def is_test_command(cmd):
    cmd_lower = cmd.lower().strip()
    return any(p in cmd_lower for p in TEST_PATTERNS)

# Parse JSONL: find Bash tool_use with test commands, collect their tool_result
# Claude Code transcript format: each line is a JSON object with 'message'
# tool_use blocks have type='tool_use', name='Bash', input.command
# tool_result blocks have type='tool_result', content (text)

pending_tool_ids = set()  # tool_use IDs for test commands
results = []

with open(path) as f:
    for line in f:
        try:
            d = json.loads(line)
            msg = d.get('message', {})
            content = msg.get('content', '')
            if not isinstance(content, list):
                continue
            for block in content:
                if not isinstance(block, dict):
                    continue
                btype = block.get('type', '')

                # Detect Bash tool_use with test command
                if btype == 'tool_use' and block.get('name') == 'Bash':
                    inp = block.get('input', {})
                    cmd = inp.get('command', '')
                    if is_test_command(cmd):
                        tid = block.get('id', '')
                        if tid:
                            pending_tool_ids.add(tid)

                # Collect tool_result for matched tool_use IDs
                if btype == 'tool_result':
                    tid = block.get('tool_use_id', '')
                    if tid in pending_tool_ids:
                        c = block.get('content', '')
                        if isinstance(c, str):
                            results.append(c)
                        elif isinstance(c, list):
                            for sub in c:
                                if isinstance(sub, dict) and sub.get('type') == 'text':
                                    results.append(sub.get('text', ''))
        except (json.JSONDecodeError, Exception):
            continue

print('\n'.join(results))
" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_bash_test_output "$1"
fi
