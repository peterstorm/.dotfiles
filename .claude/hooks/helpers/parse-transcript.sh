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
TS_UTILS_DIR="$SCRIPT_DIR/../ts-utils/dist"

parse_transcript() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  if ! command -v node &>/dev/null; then
    echo "ERROR: node not found - required for parse-transcript" >&2
    return 1
  fi

  node "$TS_UTILS_DIR/parse-transcript.js" "$transcript_path" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_transcript "$1"
fi
