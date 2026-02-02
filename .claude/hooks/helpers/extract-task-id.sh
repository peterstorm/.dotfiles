#!/bin/bash
# Extract task ID from prompt text with flexible pattern matching
# Supports multiple formats but prefers canonical: **Task ID:** T1
#
# Usage: source this file, then call extract_task_id "$PROMPT"
# Returns: task ID (e.g., "T1") or empty string
#
# Patterns matched (in order of preference):
#   1. **Task ID:** T1    (canonical - markdown bold)
#   2. Task ID: T1        (plain)
#   3. TASK ID: T1        (uppercase)
#   4. Task: T1           (missing "ID")
#   5. TASK: T1           (uppercase, missing "ID")
#   6. Task ID T1         (missing colon)
#   7. T1 (standalone)    (task ID at line start)

extract_task_id() {
  local prompt="$1"
  local task_id=""
  local format_used=""

  # Pattern 1: Canonical **Task ID:** T1 or **Task ID: T1**
  task_id=$(echo "$prompt" | grep -oE '\*\*Task ID:\*\* ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 2: Plain Task ID: T1
  task_id=$(echo "$prompt" | grep -oE 'Task ID: ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 3: TASK ID: T1 (uppercase)
  task_id=$(echo "$prompt" | grep -oiE 'TASK ID: ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 4: Task: T1 (missing "ID")
  task_id=$(echo "$prompt" | grep -oE 'Task: ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 5: TASK: T1 (uppercase, missing "ID")
  task_id=$(echo "$prompt" | grep -oiE 'TASK: ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 6: Task ID T1 (missing colon)
  task_id=$(echo "$prompt" | grep -oiE 'Task ID ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # No match
  echo ""
  return 1
}

# Validate that prompt uses canonical format
# Returns 0 if canonical, 1 if non-canonical (but valid), 2 if no task ID found
validate_task_id_format() {
  local prompt="$1"

  # Check for canonical format: **Task ID:** T1
  if echo "$prompt" | grep -qE '\*\*Task ID:\*\* ?T[0-9]+'; then
    return 0  # Canonical
  fi

  # Check for any valid format
  if extract_task_id "$prompt" >/dev/null 2>&1; then
    local found_id=$(extract_task_id "$prompt")
    if [[ -n "$found_id" ]]; then
      return 1  # Non-canonical but valid
    fi
  fi

  return 2  # No task ID found
}

# Get the expected canonical format for a task ID
canonical_format() {
  local task_id="$1"
  echo "**Task ID:** $task_id"
}
