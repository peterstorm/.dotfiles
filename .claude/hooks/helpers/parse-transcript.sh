#!/bin/bash
# Extract plain text from a Claude Code JSONL transcript file
# Parses assistant messages, tool results, and nested content blocks
#
# Usage:
#   source ~/.claude/hooks/helpers/parse-transcript.sh
#   TEXT=$(parse_transcript "/path/to/transcript.jsonl")
#
# Or standalone:
#   bash ~/.claude/hooks/helpers/parse-transcript.sh "/path/to/transcript.jsonl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_UTILS_DIR="$SCRIPT_DIR/../ts-utils/src"

parse_transcript() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  if ! command -v bun &>/dev/null; then
    echo "ERROR: bun not found — required for loom hooks. Install: curl -fsSL https://bun.sh/install | bash" >&2
    return 1
  fi

  bun "$TS_UTILS_DIR/parse-transcript.ts" "$transcript_path" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_transcript "$1"
fi
