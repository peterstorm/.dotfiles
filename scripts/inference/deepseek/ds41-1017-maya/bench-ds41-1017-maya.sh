#!/usr/bin/env bash
# Decode / prefill measurement for the Maya DeepSeek profile on :8000.
#
# Three greedy 512-token answers to a short prompt (decode), then one prompt
# per BENCH_PREFILL_WORDS entry (default "6000 20000": ~6K and ~21K tokens)
# answered in 1 token, so its wall time is the prefill. The filler is seeded
# per run: Maya keeps the last conversation's KV, and a prompt repeated from an
# earlier run would be served from it. For each request: tokens, wall time,
# tok/s and the NVMe bytes read meanwhile (the number that told the SSD-bound
# Q8 run apart). Run it on the desktop as a system unit - the user
# has no linger, so an ssh-started job dies at logout:
#   sudo systemd-run --unit ds41-maya-bench --collect --uid "$(id -u)" --gid "$(id -g)" \
#     -E HOME="$HOME" -E PATH="$PATH" ./bench-ds41-1017-maya.sh <outfile>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../../shared/inference-api-key.sh"

MODEL="deepseek-v4.1-flash"
DISK="${BENCH_DISK:-nvme0n1}"
PREFILL_WORDS="${BENCH_PREFILL_WORDS:-6000 20000}"
SEED="$(od -An -N4 -tu4 /dev/urandom | tr -d ' ')"
OUT="${1:-/dev/stdout}"

inference_resolve_client_keyfile || { echo "error: no synchronized API key" >&2; exit 1; }
KEY="$(<"$INFERENCE_CLIENT_KEYFILE")"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

disk_read_bytes() { awk -v d="$DISK" '$3 == d {print $6 * 512}' /proc/diskstats; }

request() { # label prompt-file max-tokens
  local label="$1" prompt="$2" max="$3" b0 b1 t0 t1 body
  b0="$(disk_read_bytes)"; t0="$(date +%s.%N)"
  body="$(jq -n --rawfile p "$prompt" --arg m "$MODEL" --argjson n "$max" \
    '{model: $m, messages: [{role: "user", content: $p}], max_tokens: $n, temperature: 0, reasoning_effort: "none"}' \
    | curl -sS --max-time 1800 http://127.0.0.1:8000/v1/chat/completions \
        -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' --data-binary @-)"
  t1="$(date +%s.%N)"; b1="$(disk_read_bytes)"
  jq -r --arg l "$label" --arg t0 "$t0" --arg t1 "$t1" --argjson b "$((b1 - b0))" '
    (($t1 | tonumber) - ($t0 | tonumber)) as $w
    | if .usage then
        "\($l): prompt=\(.usage.prompt_tokens) cached=\(.usage.prompt_tokens_details.cached_tokens // 0)"
        + " completion=\(.usage.completion_tokens) wall=\($w * 10 | round / 10)s"
        + (if $l | startswith("prefill") then " prefill=\(.usage.prompt_tokens / $w | round) tok/s"
           else " e2e=\(.usage.completion_tokens / $w * 100 | round / 100) tok/s" end)
        + " nvme=\($b / 1e9 * 10 | round / 10) GB"
      else "\($l): ERROR \(.error // . | tostring)" end' <<<"$body"
}

echo "Write a detailed, long technical essay on the history of compilers, from Fortran to modern LLVM, covering parsing, optimization passes, register allocation and JIT compilation. ($SEED)" >"$WORK/short"
filler() { # words seed -> a prompt of about 1.06 tokens a word
  awk -v n="$1" -v s="$2" 'BEGIN { srand(s); split("system memory kernel expert routing token cache latency throughput tensor gradient layer", w, " ");
    printf "Summarize the following log in three sentences.\n"; for (i = 0; i < n; i++) printf "%s ", w[int(rand() * 12) + 1] }'
}

{
  echo "# $(date -Is) $MODEL on :8000 (seed $SEED)"
  for i in 1 2 3; do request "decode$i" "$WORK/short" 512; done
  for words in $PREFILL_WORDS; do
    filler "$words" "$((SEED + words))" >"$WORK/long-$words"
    request "prefill-${words}w" "$WORK/long-$words" 1
  done
} | tee "$OUT"
