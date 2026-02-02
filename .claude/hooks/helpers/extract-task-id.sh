#!/bin/bash
# Extract task ID from prompt text with flexible pattern matching
# Accepts any reasonable format - prioritizes explicit over implicit
#
# Usage: source this file, then call extract_task_id "$PROMPT"
# Returns: task ID (e.g., "T1") or empty string
#
# Patterns matched (in order of preference):
#   1. **Task ID:** T1    (canonical - markdown bold)
#   2. Task ID: T1        (plain)
#   3. Task: T1           (colon variant)
#   4. Task T1            (no colon/ID)
#   5. "T1 -" or "T1:"    (ID at description start)
#   6. implement/fix/etc T1 (verb + task)
#   7. Standalone T1      (bare task ID anywhere)

extract_task_id() {
  local prompt="$1"
  local task_id=""

  # Pattern 1: Canonical **Task ID:** T1 or **Task ID: T1**
  task_id=$(echo "$prompt" | grep -oE '\*\*Task ID:\*\* ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 2: Plain Task ID: T1 (case insensitive)
  task_id=$(echo "$prompt" | grep -oiE 'Task ID:? ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 3: Task: T1 (missing "ID")
  task_id=$(echo "$prompt" | grep -oiE 'Task:? ?T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 4: Description starting with "T1 -" or "T1:" (common description format)
  task_id=$(echo "$prompt" | grep -oE '^T[0-9]+[: -]' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 5: Verb + T1 (implement T1, fix T1, complete T1, etc)
  task_id=$(echo "$prompt" | grep -oiE '(implement|fix|complete|execute|run|start|do|work on|working on) T[0-9]+' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 6: T1 followed by descriptive text (e.g., "T3 Create new component")
  task_id=$(echo "$prompt" | grep -oE 'T[0-9]+ [A-Z]' | head -1 | grep -oE 'T[0-9]+')
  [[ -n "$task_id" ]] && { echo "$task_id"; return 0; }

  # Pattern 7: Standalone T1 anywhere (last resort - matches first T# found)
  task_id=$(echo "$prompt" | grep -oE '\bT[0-9]+\b' | head -1)
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
