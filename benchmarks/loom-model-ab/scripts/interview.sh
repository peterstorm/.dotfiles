#!/usr/bin/env bash
# Answer and audit a run's interview from its protocol's answer key.
#
#   bash scripts/interview.sh <run-dir> topics
#   bash scripts/interview.sh <run-dir> suggest '<question as shown>'
#   ANSWER="$(bash scripts/interview.sh <run-dir> log '<question>' <topic-number|judgement>)"
#   bash scripts/interview.sh <run-dir> check
#
# The protocol comes from the run's own run.json, so the key cannot be the
# wrong one. `log` appends the numbered exchange to interview.md and prints
# the exact answer to send; it refuses the judgement line for a question
# whose parenthetical names an answer-key topic. `check` fails on any
# improvised answer or ignored tagged topic, and lists the questions a human
# must still confirm (see operator-tmux.md §5). Logic lives in interview.mjs.
set -euo pipefail

BENCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=benchmarks/loom-model-ab/scripts/arms.sh
source "$BENCH_DIR/scripts/arms.sh"

(($# >= 2)) || { sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
RUN_DIR="$(cd "$1" && pwd)"
COMMAND="$2"
shift 2
[[ -r "$RUN_DIR/run.json" ]] || { echo "missing benchmark run receipt: $RUN_DIR/run.json" >&2; exit 1; }
VERSION="$(benchmark_protocol_version "$(jq -r '.protocol_version // "v1"' "$RUN_DIR/run.json")")"
KEY="$BENCH_DIR/$(benchmark_protocol_path "$VERSION" frozen/answer-key.md)"
TOPICS="$BENCH_DIR/scripts/interview-topics.json"
CORE=(node "$BENCH_DIR/scripts/interview.mjs" "$KEY" "$TOPICS")

case "$COMMAND" in
  topics|answer|suggest) exec "${CORE[@]}" "$COMMAND" "$@" ;;
  log|check) exec "${CORE[@]}" "$COMMAND" "$RUN_DIR/interview.md" "$@" ;;
  *) echo "unknown command: $COMMAND (expected topics, suggest, answer, log, check)" >&2; exit 2 ;;
esac
