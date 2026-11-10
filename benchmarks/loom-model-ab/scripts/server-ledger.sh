#!/usr/bin/env bash
# Evidence of other tenants on a Maya endpoint during a benchmark run.
#
#   bash scripts/server-ledger.sh snapshot <out.json>
#   bash scripts/server-ledger.sh idle [timeout_s] [quiet_s]
#   bash scripts/server-ledger.sh delta <start.json> <end.json> [session.jsonl]
#
# `snapshot` records Maya's cumulative request counters (authenticated
# /metrics). `delta` subtracts two snapshots and, given the run's Pi transcript,
# compares the server's request count with the assistant turns the run itself
# made: a surplus means requests from somebody else shared the queue.
# `idle` waits until nothing is active or queued for a sustained quiet period.
#
# Needs INFERENCE_URL (default http://127.0.0.1:8000, the local forwarder).
set -euo pipefail

URL="${INFERENCE_URL:-http://127.0.0.1:8000}"

api_key() {
  local candidate
  for candidate in ~/.config/ds4-flash/api-key ~/.config/qwen38/api-key \
                   ~/.config/glm53/api-key ~/.config/sops-nix/secrets/vllm-api-key; do
    [[ -r "$candidate" ]] && { cat "$candidate"; return 0; }
  done
  echo "pi-ledger: no readable inference api-key" >&2
  return 1
}

metrics() {
  local key
  key="$(api_key)"
  # The credential travels over curl's stdin config, never argv.
  printf 'header = "Authorization: Bearer %s"\n' "$key" | curl --config - -fsS -m 30 "$URL/metrics"
}

case "${1:-}" in
  snapshot)
    out="${2:?usage: $0 snapshot <out.json>}"
    metrics | jq '{
      taken_at: (now | todate),
      model: .engine.model,
      active: .live.active,
      queued: .live.queued,
      requests: .totals.requests,
      prompt_tokens: .totals.prompt_tokens,
      reused_tokens: .totals.reused,
      output_tokens: .totals.output_tokens
    }' > "$out"
    cat "$out"
    ;;

  idle)
    timeout_s="${2:-3600}"
    quiet_s="${3:-120}"
    deadline=$((SECONDS + timeout_s))
    quiet_since=-1
    while ((SECONDS < deadline)); do
      busy="$(metrics | jq -r '(.live.active + .live.queued)')" || busy=error
      if [[ "$busy" == 0 ]]; then
        ((quiet_since >= 0)) || quiet_since=$SECONDS
        if ((SECONDS - quiet_since >= quiet_s)); then
          echo "idle for ${quiet_s}s"
          exit 0
        fi
      else
        quiet_since=-1
      fi
      sleep 10
    done
    echo "server stayed busy for ${timeout_s}s" >&2
    exit 1
    ;;

  delta)
    start="${2:?usage: $0 delta <start.json> <end.json> [session.jsonl]}"
    end="${3:?usage: $0 delta <start.json> <end.json> [session.jsonl]}"
    session="${4:-}"
    own=null
    if [[ -n "$session" ]]; then
      own="$(jq -s '[.[] | select(.type == "message" and .message.role == "assistant")] | length' "$session")"
    fi
    jq -n --slurpfile a "$start" --slurpfile b "$end" --argjson own "$own" '
      ($b[0].requests - $a[0].requests) as $server
      | {
          server_requests: $server,
          prompt_tokens: ($b[0].prompt_tokens - $a[0].prompt_tokens),
          reused_tokens: ($b[0].reused_tokens - $a[0].reused_tokens),
          output_tokens: ($b[0].output_tokens - $a[0].output_tokens),
          own_assistant_turns_in_parent_session: $own,
          server_requests_per_parent_turn: (if ($own // 0) > 0 then ($server / $own) else null end)
        }'
    ;;

  *)
    echo "usage: $0 {snapshot <out>|idle [timeout_s] [quiet_s]|delta <start> <end> [session]}" >&2
    exit 2
    ;;
esac
