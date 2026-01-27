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

parse_transcript() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && return 0

  TRANSCRIPT_PATH="$transcript_path" python3 -c "
import os, sys, json
texts = []
path = os.environ['TRANSCRIPT_PATH']
with open(path) as f:
    for line_num, line in enumerate(f, 1):
        try:
            d = json.loads(line)
            msg = d.get('message', {})
            content = msg.get('content', '')
            if isinstance(content, str):
                texts.append(content)
            elif isinstance(content, list):
                for block in content:
                    if isinstance(block, dict):
                        if block.get('type') == 'text':
                            texts.append(block.get('text', ''))
                        elif block.get('type') == 'tool_result':
                            c = block.get('content', '')
                            if isinstance(c, str):
                                texts.append(c)
                            elif isinstance(c, list):
                                for sub in c:
                                    if isinstance(sub, dict) and sub.get('type') == 'text':
                                        texts.append(sub.get('text', ''))
        except json.JSONDecodeError:
            print(f'WARNING: parse-transcript: invalid JSON on line {line_num}', file=sys.stderr)
        except Exception as e:
            print(f'WARNING: parse-transcript: error on line {line_num}: {e}', file=sys.stderr)
print('\n'.join(texts))
" 2>/dev/null
}

# Allow standalone usage
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  parse_transcript "$1"
fi
