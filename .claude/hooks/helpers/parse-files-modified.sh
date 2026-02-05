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

parse_files_modified() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  TRANSCRIPT_PATH="$transcript_path" python3 -c "
import os, json
files = set()
with open(os.environ['TRANSCRIPT_PATH']) as f:
    for line in f:
        try:
            d = json.loads(line)
            msg = d.get('message', {})
            content = msg.get('content', [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get('type') == 'tool_use':
                        name = block.get('name', '')
                        inp = block.get('input', {})
                        if name in ('Write', 'Edit') and 'file_path' in inp:
                            files.add(inp['file_path'])
                        elif name == 'MultiEdit' and 'file_path' in inp:
                            files.add(inp['file_path'])
        except:
            pass
for f in sorted(files):
    print(f)
" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_files_modified "$1"
fi
