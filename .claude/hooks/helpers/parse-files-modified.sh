#!/bin/bash
# Extract Write/Edit file paths from a Claude Code JSONL transcript
# Returns newline-separated list of absolute file paths modified by agent
#
# Usage:
#   source ~/.claude/hooks/helpers/parse-files-modified.sh
#   FILES=$(parse_files_modified "/path/to/transcript.jsonl")
#
# Or standalone:
#   bash ~/.claude/hooks/helpers/parse-files-modified.sh "/path/to/transcript.jsonl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_UTILS_DIR="$SCRIPT_DIR/../ts-utils/dist"

parse_files_modified() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  if ! command -v node &>/dev/null; then
    echo "ERROR: node not found - required for parse-files-modified" >&2
    return 1
  fi

  node "$TS_UTILS_DIR/parse-files-modified.js" "$transcript_path" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_files_modified "$1"
fi
