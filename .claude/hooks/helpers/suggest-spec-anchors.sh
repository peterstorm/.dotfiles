#!/bin/bash
# Suggest spec anchors for a task description
# Fuzzy-matches task keywords to FR-xxx, SC-xxx, US-x entries in spec
#
# Usage: suggest-spec-anchors.sh "task description" [spec_file]
#   spec_file defaults to most recent .claude/specs/*/spec.md
#
# Output: JSON array of suggested anchors with confidence scores
#
# Example:
#   suggest-spec-anchors.sh "Implement email validation"
#   [{"anchor":"FR-003","score":0.85,"text":"System MUST validate email format"},...]

set -e

TASK_DESC="$1"
SPEC_FILE="$2"

if [[ -z "$TASK_DESC" ]]; then
  echo "Usage: suggest-spec-anchors.sh \"task description\" [spec_file]" >&2
  exit 1
fi

# Find spec file if not provided
if [[ -z "$SPEC_FILE" ]]; then
  SPEC_FILE=$(ls -t .claude/specs/*/spec.md 2>/dev/null | head -1)
  if [[ -z "$SPEC_FILE" ]]; then
    echo "[]"  # No spec found
    exit 0
  fi
fi

if [[ ! -f "$SPEC_FILE" ]]; then
  echo "[]"
  exit 0
fi

# Extract keywords from task description (lowercase, remove common words)
STOPWORDS="the|a|an|to|for|in|on|with|and|or|of|is|it|this|that|be|as|at|by"
KEYWORDS=$(echo "$TASK_DESC" | tr '[:upper:]' '[:lower:]' | \
  tr -cs '[:alnum:]' '\n' | \
  grep -vE "^($STOPWORDS)$" | \
  grep -E '.{3,}' | \
  sort -u)

if [[ -z "$KEYWORDS" ]]; then
  echo "[]"
  exit 0
fi

# Parse spec for requirements and scenarios
# FR-xxx: Functional Requirements
# SC-xxx: Success Criteria
# US-x or ### US: User Scenarios

RESULTS="[]"

# Extract FR entries: "- FR-001: description" or "- FR-001 description"
while IFS= read -r line; do
  ANCHOR=$(echo "$line" | grep -oE 'FR-[0-9]+' | head -1)
  TEXT=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^FR-[0-9]*[[:space:]]*:*[[:space:]]*//')

  if [[ -n "$ANCHOR" && -n "$TEXT" ]]; then
    # Score by keyword matches
    SCORE=0
    MATCHES=0
    TOTAL_KW=$(echo "$KEYWORDS" | wc -l | tr -d ' ')

    for kw in $KEYWORDS; do
      if echo "$TEXT" | tr '[:upper:]' '[:lower:]' | grep -qw "$kw"; then
        MATCHES=$((MATCHES + 1))
      fi
    done

    if [[ "$TOTAL_KW" -gt 0 && "$MATCHES" -gt 0 ]]; then
      # Score = matches / total keywords, scaled 0-1
      SCORE=$(echo "scale=2; $MATCHES / $TOTAL_KW" | bc)
      # Escape text for JSON
      TEXT_ESCAPED=$(echo "$TEXT" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
      RESULTS=$(echo "$RESULTS" | jq --arg a "$ANCHOR" --arg s "$SCORE" --arg t "$TEXT_ESCAPED" \
        '. + [{"anchor": $a, "score": ($s | tonumber), "text": $t}]')
    fi
  fi
done < <(grep -E '^\s*-\s*FR-[0-9]+' "$SPEC_FILE")

# Extract SC entries: "- SC-001: description"
while IFS= read -r line; do
  ANCHOR=$(echo "$line" | grep -oE 'SC-[0-9]+' | head -1)
  TEXT=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//' | sed 's/^SC-[0-9]*[[:space:]]*:*[[:space:]]*//')

  if [[ -n "$ANCHOR" && -n "$TEXT" ]]; then
    SCORE=0
    MATCHES=0
    TOTAL_KW=$(echo "$KEYWORDS" | wc -l | tr -d ' ')

    for kw in $KEYWORDS; do
      if echo "$TEXT" | tr '[:upper:]' '[:lower:]' | grep -qw "$kw"; then
        MATCHES=$((MATCHES + 1))
      fi
    done

    if [[ "$TOTAL_KW" -gt 0 && "$MATCHES" -gt 0 ]]; then
      SCORE=$(echo "scale=2; $MATCHES / $TOTAL_KW" | bc)
      TEXT_ESCAPED=$(echo "$TEXT" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
      RESULTS=$(echo "$RESULTS" | jq --arg a "$ANCHOR" --arg s "$SCORE" --arg t "$TEXT_ESCAPED" \
        '. + [{"anchor": $a, "score": ($s | tonumber), "text": $t}]')
    fi
  fi
done < <(grep -E '^\s*-\s*SC-[0-9]+' "$SPEC_FILE")

# Extract US acceptance scenarios: "- Given X, When Y, Then Z"
US_NUM=""
while IFS= read -r line; do
  # Track current user scenario number
  if echo "$line" | grep -qE '^###\s*US[0-9]+|^###.*\[P[123]\]'; then
    US_NUM=$(echo "$line" | grep -oE 'US[0-9]+' | head -1)
    if [[ -z "$US_NUM" ]]; then
      # Extract from pattern like "### [P1] Account Creation"
      US_NUM="US$((${US_NUM:-0} + 1))"
    fi
  fi

  # Match acceptance scenarios
  if echo "$line" | grep -qiE 'given.*when.*then'; then
    if [[ -n "$US_NUM" ]]; then
      ANCHOR="${US_NUM}.acceptance"
      TEXT=$(echo "$line" | sed 's/^[[:space:]]*-[[:space:]]*//')

      SCORE=0
      MATCHES=0
      TOTAL_KW=$(echo "$KEYWORDS" | wc -l | tr -d ' ')

      for kw in $KEYWORDS; do
        if echo "$TEXT" | tr '[:upper:]' '[:lower:]' | grep -qw "$kw"; then
          MATCHES=$((MATCHES + 1))
        fi
      done

      if [[ "$TOTAL_KW" -gt 0 && "$MATCHES" -gt 0 ]]; then
        SCORE=$(echo "scale=2; $MATCHES / $TOTAL_KW" | bc)
        TEXT_ESCAPED=$(echo "$TEXT" | sed 's/"/\\"/g' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        RESULTS=$(echo "$RESULTS" | jq --arg a "$ANCHOR" --arg s "$SCORE" --arg t "$TEXT_ESCAPED" \
          '. + [{"anchor": $a, "score": ($s | tonumber), "text": $t}]')
      fi
    fi
  fi
done < "$SPEC_FILE"

# Sort by score descending, take top 5
echo "$RESULTS" | jq 'sort_by(-.score) | .[0:5]'
