#!/bin/bash
# Validate task graph JSON schema
# Usage: validate-task-graph.sh [--minimal] [--fix] [<json_file_or_stdin>]
#
#   --minimal   Validate initial phase-tracking graph (no tasks)
#   --fix       Output corrected JSON to stdout (adds missing fields w/ defaults)
#   -           Read from stdin
#
# Exit 0 = valid, Exit 1 = invalid (errors on stderr)

MODE="full"
FIX=false
INPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --minimal) MODE="minimal"; shift ;;
    --fix) FIX=true; shift ;;
    *) INPUT_FILE="$1"; shift ;;
  esac
done

if [[ -z "$INPUT_FILE" || "$INPUT_FILE" == "-" ]]; then
  JSON=$(cat)
else
  [[ ! -f "$INPUT_FILE" ]] && { echo "File not found: $INPUT_FILE" >&2; exit 1; }
  JSON=$(cat "$INPUT_FILE")
fi

ERRORS=()

# Check valid JSON
if ! echo "$JSON" | jq empty 2>/dev/null; then
  if $FIX && [[ "$MODE" == "minimal" ]]; then
    # Can't fix invalid JSON — emit canonical template
    cat << 'TMPL'
{
  "current_phase": "init",
  "phase_artifacts": {},
  "skipped_phases": [],
  "spec_file": null,
  "plan_file": null
}
TMPL
    exit 0
  fi
  echo "ERROR: Invalid JSON" >&2
  exit 1
fi

# ===== MINIMAL MODE: phase-tracking graph =====
if [[ "$MODE" == "minimal" ]]; then
  VALID_PHASES='["init","brainstorm","specify","clarify","architecture","decompose","execute"]'

  # current_phase
  CP=$(echo "$JSON" | jq -r '.current_phase // empty')
  if [[ -z "$CP" ]]; then
    ERRORS+=("Missing required field: current_phase")
  else
    IS_VALID=$(echo "$VALID_PHASES" | jq --arg p "$CP" 'index($p) != null')
    [[ "$IS_VALID" != "true" ]] && ERRORS+=("current_phase '$CP' not a valid phase")
  fi

  # phase_artifacts must be object
  PA_TYPE=$(echo "$JSON" | jq -r '.phase_artifacts | type' 2>/dev/null)
  [[ "$PA_TYPE" != "object" ]] && ERRORS+=("phase_artifacts must be object (got $PA_TYPE)")

  # skipped_phases must be array
  SP_TYPE=$(echo "$JSON" | jq -r '.skipped_phases | type' 2>/dev/null)
  [[ "$SP_TYPE" != "array" ]] && ERRORS+=("skipped_phases must be array (got $SP_TYPE)")

  # spec_file and plan_file must exist as keys (null is fine)
  HAS_SPEC=$(echo "$JSON" | jq 'has("spec_file")')
  HAS_PLAN=$(echo "$JSON" | jq 'has("plan_file")')
  [[ "$HAS_SPEC" != "true" ]] && ERRORS+=("Missing required field: spec_file")
  [[ "$HAS_PLAN" != "true" ]] && ERRORS+=("Missing required field: plan_file")

  if $FIX; then
    # Emit corrected minimal graph, preserving valid fields
    FIXED=$(echo "$JSON" | jq '
      {
        current_phase: (
          if (.current_phase as $p | ["init","brainstorm","specify","clarify","architecture","decompose","execute"] | index($p)) != null
          then .current_phase else "init" end
        ),
        phase_artifacts: (if (.phase_artifacts | type) == "object" then .phase_artifacts else {} end),
        skipped_phases: (if (.skipped_phases | type) == "array" then .skipped_phases else [] end),
        spec_file: (if has("spec_file") then .spec_file else null end),
        plan_file: (if has("plan_file") then .plan_file else null end)
      }
    ')
    echo "$FIXED"
    if [[ ${#ERRORS[@]} -gt 0 ]]; then
      echo "Fixed ${#ERRORS[@]} issues in minimal graph" >&2
    fi
    exit 0
  fi

  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Minimal graph validation FAILED (${#ERRORS[@]} errors):" >&2
    for err in "${ERRORS[@]}"; do echo "  - $err" >&2; done
    exit 1
  fi

  echo "Minimal graph valid"
  exit 0
fi

# ===== FULL MODE: decompose task graph =====

# Known agent types
# Impl agents only — phase agents (brainstorm/specify/clarify/architecture/decompose) should not appear in task graph
KNOWN_AGENTS='["code-implementer-agent","java-test-agent","ts-test-agent","security-agent","dotfiles-agent","k8s-agent","keycloak-agent","frontend-agent","general-purpose"]'

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
  if $FIX; then
    echo "$JSON" | jq '. + {tasks: []}' 2>/dev/null || echo "$JSON"
    echo "Fixed: tasks field added as empty array (needs manual population)" >&2
  else
    for err in "${ERRORS[@]}"; do echo "ERROR: $err" >&2; done
  fi
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

  # Validate new_tests_required=false against description keywords
  # Flags suspicious test-skip: if description doesn't match known no-test patterns, warn
  # Note: NTR from jq `// empty` is "" for false, so check raw value
  NTR_RAW=$(echo "$TASK" | jq -r '.new_tests_required | tostring')
  if [[ "$NTR_RAW" == "false" && -n "$DESC" ]]; then
    DESC_LOWER=$(echo "$DESC" | tr '[:upper:]' '[:lower:]')
    NO_TEST_KEYWORDS="migration|config|schema|rename|bump|version|refactor|cleanup|typo|docs|interface|documentation|changelog|readme|ci|cd|pipeline|deploy|→|->|styling|css|formatting"
    if ! echo "$DESC_LOWER" | grep -qE "$NO_TEST_KEYWORDS"; then
      echo "WARNING: Task $TID has new_tests_required=false but description doesn't match no-test patterns" >&2
      echo "  Description: $DESC" >&2
      echo "  Expected keywords: migration, config, schema, rename, refactor, docs, etc." >&2
    fi
  fi
done

# --fix: emit corrected JSON with missing per-task defaults
if $FIX; then
  FIXED=$(echo "$JSON" | jq '
    .tasks = [.tasks[] | . + {
      depends_on: (if (.depends_on | type) == "array" then .depends_on else [] end),
      status: (.status // "pending"),
      review_status: (.review_status // "pending"),
      critical_findings: (if (.critical_findings | type) == "array" then .critical_findings else [] end),
      advisory_findings: (if (.advisory_findings | type) == "array" then .advisory_findings else [] end)
    }]
  ')
  echo "$FIXED"
  if [[ ${#ERRORS[@]} -gt 0 ]]; then
    echo "Fixed structural defaults; ${#ERRORS[@]} issues remain (may need manual fix):" >&2
    for err in "${ERRORS[@]}"; do echo "  - $err" >&2; done
    exit 1
  fi
  exit 0
fi

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
