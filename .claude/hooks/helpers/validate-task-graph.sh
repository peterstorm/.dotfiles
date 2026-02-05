#!/bin/bash
# Validate task graph JSON schema before creating state file
# Usage: validate-task-graph.sh <json_file_or_stdin>
#
# Exit 0 = valid, Exit 1 = invalid (errors on stderr)

INPUT_FILE="$1"
if [[ -z "$INPUT_FILE" || "$INPUT_FILE" == "-" ]]; then
  JSON=$(cat)
else
  [[ ! -f "$INPUT_FILE" ]] && { echo "File not found: $INPUT_FILE" >&2; exit 1; }
  JSON=$(cat "$INPUT_FILE")
fi

ERRORS=()

# Check valid JSON
if ! echo "$JSON" | jq empty 2>/dev/null; then
  echo "ERROR: Invalid JSON" >&2
  exit 1
fi

# Known agent types
KNOWN_AGENTS='["code-implementer-agent","architecture-agent","java-test-agent","ts-test-agent","security-agent","dotfiles-agent","k8s-agent","keycloak-agent","frontend-agent","general-purpose","brainstorm-agent","specify-agent","clarify-agent","decompose-agent"]'

# Required top-level fields
for field in plan_title plan_file spec_file tasks; do
  VAL=$(echo "$JSON" | jq -r ".$field // empty")
  if [[ -z "$VAL" ]]; then
    ERRORS+=("Missing required field: $field")
  fi
done

# tasks must be array
IS_ARRAY=$(echo "$JSON" | jq -r '.tasks | type' 2>/dev/null)
if [[ "$IS_ARRAY" != "array" ]]; then
  ERRORS+=("'tasks' must be an array")
  # Can't validate tasks further
  for err in "${ERRORS[@]}"; do echo "ERROR: $err" >&2; done
  exit 1
fi

TASK_COUNT=$(echo "$JSON" | jq '.tasks | length')
if [[ "$TASK_COUNT" -eq 0 ]]; then
  ERRORS+=("'tasks' array is empty")
fi

# Collect all task IDs for dependency validation
ALL_IDS=$(echo "$JSON" | jq -r '.tasks[].id' 2>/dev/null)

# Validate each task
for i in $(seq 0 $(( TASK_COUNT - 1 ))); do
  TASK=$(echo "$JSON" | jq ".tasks[$i]")
  TID=$(echo "$TASK" | jq -r '.id // empty')

  # Required per-task fields
  if [[ -z "$TID" ]]; then
    ERRORS+=("Task [$i]: missing 'id'")
    continue
  fi

  # ID format: T followed by digits
  if ! [[ "$TID" =~ ^T[0-9]+$ ]]; then
    ERRORS+=("Task $TID: id must match T\\d+ (got '$TID')")
  fi

  DESC=$(echo "$TASK" | jq -r '.description // empty')
  [[ -z "$DESC" ]] && ERRORS+=("Task $TID: missing 'description'")

  AGENT=$(echo "$TASK" | jq -r '.agent // empty')
  [[ -z "$AGENT" ]] && ERRORS+=("Task $TID: missing 'agent'")

  # Agent must be recognized
  if [[ -n "$AGENT" ]]; then
    IS_KNOWN=$(echo "$KNOWN_AGENTS" | jq --arg a "$AGENT" 'index($a) != null')
    if [[ "$IS_KNOWN" != "true" ]]; then
      ERRORS+=("Task $TID: unknown agent '$AGENT'")
    fi
  fi

  WAVE=$(echo "$TASK" | jq -r '.wave // empty')
  if [[ -z "$WAVE" ]]; then
    ERRORS+=("Task $TID: missing 'wave'")
  elif ! [[ "$WAVE" =~ ^[0-9]+$ ]] || [[ "$WAVE" -lt 1 ]]; then
    ERRORS+=("Task $TID: wave must be integer >= 1 (got '$WAVE')")
  fi

  # depends_on must be array
  DEPS_TYPE=$(echo "$TASK" | jq -r '.depends_on | type' 2>/dev/null)
  if [[ "$DEPS_TYPE" != "array" && "$DEPS_TYPE" != "null" ]]; then
    ERRORS+=("Task $TID: 'depends_on' must be array")
  fi

  # Validate dependencies
  if [[ "$DEPS_TYPE" == "array" ]]; then
    DEPS=$(echo "$TASK" | jq -r '.depends_on[]' 2>/dev/null)
    for dep in $DEPS; do
      # No self-deps
      if [[ "$dep" == "$TID" ]]; then
        ERRORS+=("Task $TID: self-dependency")
        continue
      fi
      # Dep must exist
      if ! echo "$ALL_IDS" | grep -qx "$dep"; then
        ERRORS+=("Task $TID: depends on non-existent '$dep'")
        continue
      fi
      # Dep must be in earlier wave
      if [[ -n "$WAVE" ]]; then
        DEP_WAVE=$(echo "$JSON" | jq -r ".tasks[] | select(.id==\"$dep\") | .wave")
        if [[ -n "$DEP_WAVE" && "$DEP_WAVE" -ge "$WAVE" ]]; then
          ERRORS+=("Task $TID (wave $WAVE): depends on '$dep' (wave $DEP_WAVE) — deps must be in earlier wave")
        fi
      fi
    done
  fi

  # Optional field type checks
  SA_TYPE=$(echo "$TASK" | jq -r '.spec_anchors | type' 2>/dev/null)
  if [[ "$SA_TYPE" != "null" && "$SA_TYPE" != "array" ]]; then
    ERRORS+=("Task $TID: 'spec_anchors' must be array if present")
  fi

  NTR=$(echo "$TASK" | jq -r '.new_tests_required // empty')
  if [[ -n "$NTR" && "$NTR" != "true" && "$NTR" != "false" ]]; then
    ERRORS+=("Task $TID: 'new_tests_required' must be boolean if present")
  fi
done

# Report
if [[ ${#ERRORS[@]} -gt 0 ]]; then
  echo "Task graph validation FAILED (${#ERRORS[@]} errors):" >&2
  for err in "${ERRORS[@]}"; do
    echo "  - $err" >&2
  done
  exit 1
fi

echo "Task graph valid: $TASK_COUNT tasks"
exit 0
