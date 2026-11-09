#!/usr/bin/env bash
# Build the graded interview record from a run's Pi transcript.
#
#   bash scripts/extract-interview.sh <run-dir> [> interview-clean.md]
#
# Every AskUserQuestion a phase child asked, with its options, and the answer the
# operator gave — read from the structured tool calls and results in
# session.jsonl, not scraped from the terminal. The operator's own
# interview.md log is a by-hand cross-check; this is the record to grade.
#
# Questions and results are paired by order within each child: the relay
# answers one AskUserQuestion batch at a time, and each result lists
# "Header: answer" lines in question order. A call the tool rejected at
# validation never reached the operator; it is reported as such, because a
# malformed question is itself evidence about the model.
set -euo pipefail

RUN="${1:?usage: $0 <run-dir>}"
SESSION="$RUN/session.jsonl"
[[ -r "$SESSION" ]] || { echo "missing $SESSION" >&2; exit 1; }

jq -rs '
  def rejected($result): $result | startswith("Validation failed");
  [ .[] | select(.type == "message" and .message.toolName == "loom_interactive_subagent")
        | .message.details.results[] ] as $children
  | "# Interview transcript\n\nPhase children that interviewed the operator: \($children | map(.agent) | join(", "))\n",
    ( $children[] as $child
      | $child.agent as $agent
      | [ $child.messages[] | select(.role == "assistant")
          | .content[]? | select(.type == "toolCall" and .name == "AskUserQuestion") ] as $calls
      | [ $child.messages[] | select(.role == "toolResult" and .toolName == "AskUserQuestion")
          | (.content | map(select(.type == "text") | .text) | join("\n")) ] as $results
      | range(0; $calls | length) as $batch
      | ($results[$batch] // "") as $result
      | if rejected($result) then
          "\n## \($agent) — batch \($batch + 1)\n\n_Malformed AskUserQuestion call rejected by tool validation; it never reached the operator._ Validation message: \($result | split("\n")[1] // $result | ltrimstr("  - "))\n"
        else
          $calls[$batch].arguments.questions as $questions
          | "\n## \($agent) — batch \($batch + 1)\n",
            ( range(0; $questions | length) as $i
              | $questions[$i] as $q
              | ( [ ($result | split("\n"))[] | select(startswith($q.header + ": ")) ] | first // "(no recorded answer)" ) as $answer
              | "### \($q.header)\n\($q.question)\n\(if $q.multiSelect then "(multi-select)\n" else "" end)"
                + ( [ $q.options[]? | "- \(.label) — \(.description)" ] | join("\n") )
                + "\n\n**Operator answer:** \($answer | ltrimstr($q.header + ": "))\n" )
        end )
' "$SESSION"
