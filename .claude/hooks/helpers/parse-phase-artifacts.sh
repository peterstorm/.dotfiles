#!/bin/bash
# Parse spec_file and plan_file paths from phase agent transcripts
# Wrapper for parse-phase-artifacts.ts
#
# Usage: source parse-phase-artifacts.sh
#        ARTIFACTS=$(parse_phase_artifacts "$TRANSCRIPT_PATH")
#        SPEC_FILE=$(echo "$ARTIFACTS" | jq -r '.spec_file // empty')

parse_phase_artifacts() {
  local transcript_path="$1"
  [[ -z "$transcript_path" || ! -f "$transcript_path" ]] && echo '{}' && return

  if ! command -v bun &>/dev/null; then
    echo "ERROR: bun not found — required for loom hooks. Install: curl -fsSL https://bun.sh/install | bash" >&2
    echo '{}'
    return 1
  fi

  local script_dir
  script_dir="$(dirname "${BASH_SOURCE[0]}")/../ts-utils/src"

  bun "$script_dir/parse-phase-artifacts.ts" "$transcript_path" 2>/dev/null || echo '{}'
}
