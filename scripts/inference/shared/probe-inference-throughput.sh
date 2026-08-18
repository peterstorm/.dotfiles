#!/usr/bin/env bash
# Throughput/latency probe for the :8000 inference server (vLLM or SGLang).
#
# Purpose: engine A/B evidence for the Qwen3.8-27B DSpark validation gate
# (docs/runbooks/new-desktop-install.md: "output tokens/s plus inter-token latency at
# concurrency 1 and 8 beat or match the SGLang DSpark baseline").
#
# Rounds (override with ROUNDS, space separated):
#   c1-short  1 request, short prefill, 800 max tokens
#   c8-short  8 requests (== max concurrency), short prefill, 800 max tokens
#   c4-long   4 requests, ~22K-token unique prose prefill (agent-shaped), 600 max tokens
#
# Per round it reports: tokens, TTFT p50/p95, ITL p50/p95, per-request and
# aggregate tokens/s, plus the spec-decode draft/accept counters delta (when
# the engine exposes them) so acceptance length is comparable across engines:
#   vLLM:  vllm:spec_decode_num_drafts_total / num_accepted_tokens_total
#   SGLang: spec_* gauges/counters are captured raw for manual comparison.
#
# Note: Qwen3.8 streams tokens in reasoning_content as well as content; both
# are counted. Uses bash builtins (EPOCHREALTIME) for millisecond timing — no
# python required, and no per-token forks to skew ITL.
set -euo pipefail

BASE="${BASE_URL:-http://127.0.0.1:8000}"
KEYFILE="${KEYFILE:-$HOME/.config/qwen38/api-key}"
MODEL="${MODEL:-qwen3.8-27b}"
ROUNDS="${ROUNDS:-c1-short c8-short c4-long}"
BACKEND="${BACKEND:-unlabeled}"
LONG_SENTENCES="${LONG_SENTENCES:-750}"
OUT_DIR="${OUT_DIR:-$(mktemp -d /tmp/infer-probe.XXXXXX)}"

[ -f "$KEYFILE" ] || { echo "error: key file not found: $KEYFILE" >&2; exit 2; }
KEY="$(tr -d '[:space:]' < "$KEYFILE")"

us_now() { local t="${EPOCHREALTIME/./}"; echo "$t"; }   # microseconds, builtin

short_prompt='Explain how a hash table works, then give a short Python example of a linear-probing implementation. Keep it under 300 words.'

long_prompt="$(awk -v n="$LONG_SENTENCES" 'BEGIN {
  for (i = 1; i <= n; i++)
    printf "Sentence %d: the amber kettle whispered of %d cups of quiet, while the %dth window held the afternoon light against the paper map. ", i, i % 97, i % 53
  print "Now answer briefly: what is the sum of all integers from 1 to 100, and list the primes under 30."
}')"

# Stream one chat completion; append one line per delta token: "<ms since start>".
# Raw SSE is kept in reqN.sse for later inspection (finish_reason, usage).
stream_one() { # $1=outfile  $2=prompt  $3=max_tokens
  local out="$1" prompt="$2" mt="$3" start now line
  start="$(us_now)"
  : > "$out.sse"
  local body
  body="$(jq -n --arg p "$prompt" --arg m "$MODEL" --argjson mt "$mt" \
    '{model:$m, stream:true, max_tokens:$mt, stream_options:{include_usage:true},
      messages:[{role:"user", content:$p}]}')"
  curl -fsS -N "$BASE/v1/chat/completions" \
    -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
    -d "$body" 2>>"$OUT_DIR/curl.err" |
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$out.sse"
    case "$line" in
      data:\[DONE\]*) ;;
      data:*)
        now="$(us_now)"
        if printf '%s' "$line" | grep -qE '"(reasoning|reasoning_content|content)":"[^"]'; then
          printf '%s\n' "$(( (now - start) / 1000 ))" >> "$out"
        fi
        ;;
    esac
  done
}

# Snapshot spec-decode related metrics; vLLM counters are summed exactly.
spec_snap() { # $1=outfile
  curl -fsS "$BASE/metrics" > "$1" 2>/dev/null || true
  {
    grep -E '^vllm:spec_decode_(num_drafts_total|num_accepted_tokens_total)( |\{)' "$1" \
      | awk '{s[$1]+=$2} END {for (k in s) print k, s[k]}' || true
    grep -Ei '^sglang:(spec_|num_)' "$1" | awk '{s[$1]+=$2} END {for (k in s) print k, s[k]}' || true
  } | sort > "$1.spec"
}

run_round() { # $1=name  $2=concurrency  $3=prompt  $4=max_tokens
  local name="$1" conc="$2" prompt="$3" mt="$4"
  local rdir="$OUT_DIR/$name"
  rm -rf "$rdir"; mkdir -p "$rdir"
  local wall_start wall_end
  wall_start="$(us_now)"
  spec_snap "$rdir/metrics.before"
  local i pids=()
  for i in $(seq 1 "$conc"); do
    stream_one "$rdir/req$i.tok" "$prompt" "$mt" &
    pids+=("$!")
  done
  local rc=0
  for pid in "${pids[@]}"; do wait "$pid" || rc=1; done
  wall_end="$(us_now)"
  spec_snap "$rdir/metrics.after"

  # Per-request stats + aggregate
  local total=0 last=0
  local per_req=""
  for f in "$rdir"/req*.tok; do
    [ -e "$f" ] || continue
    local stats
    stats="$(awk '{ts[NR]=$1} END {
      if (NR==0) {print "0 - - - - -"; exit}
      n=0; for (i=2;i<=NR;i++){d[i-1]=ts[i]-ts[i-1]; n++}
      m=asort(d);
      p50 = (n>0) ? d[int(n/2 + 0.5)] : -1
      p95 = (n>0) ? d[int(n*95/100 + 0.5)] : -1
      print NR, ts[1], p50, p95, ts[NR]
    }' "$f")"
    set -- $stats
    local toks=$1 ttft=$2 itl50=$3 itl95=$4 endt=$5
    local tps=$(awk -v t="$toks" -v e="$endt" 'BEGIN{printf "%.1f", (e>0)? t/(e/1000): 0}')
    local finish usage
    finish=$(grep -oE '"finish_reason":"[a-z_]+"' "$f.sse" | tail -1 | cut -d'"' -f4)
    usage=$(grep -oE '"usage":\{[^}]*\}' "$f.sse" | tail -1)
    local tps_decode
    tps_decode=$(awk -v t="$toks" -v s="$ttft" -v e="$endt" 'BEGIN{printf "%.1f", (e>s)? t/((e-s)/1000): 0}')
    total=$((total + toks))
    [ "$endt" -gt "$last" ] && last=$endt
    per_req="${per_req}    req(toks=${toks} finish=${finish:-?} ttft=${ttft}ms decode_itl50=${itl50}ms itl95=${itl95}ms)=${tps} tok/s overall, ${tps_decode} tok/s decode-only${usage:+ usage:${usage}}
"
  done
  local wall_ms=$(( (wall_end - wall_start) / 1000 ))
  local agg_tps=$(awk -v t="$total" -v w="$wall_ms" 'BEGIN{printf "%.1f", (w>0)? t/(w/1000): 0}')
  {
    echo "== round: $name (backend=$BACKEND concurrency=$conc max_tokens=$mt) =="
    echo "$per_req"
    echo "   aggregate: ${total} tokens in ${wall_ms}ms -> ${agg_tps} tok/s"
  }
  if [ "$rc" -ne 0 ]; then echo "   WARNING: one or more requests failed; see $rdir/../curl.err" >&2; fi

  # Spec-decode delta for this round
  echo "   spec-delta:"
  awk '
    FNR == NR { b[$1] = $2; next }
    { a[$1] = $2 }
    END {
      found = 0
      for (k in a) if (k in b) {
        d = a[k] - b[k]; found = 1
        if (k ~ /num_drafts_total/) { drafts = d }
        if (k ~ /num_accepted_tokens_total/) { acc = d }
        printf "     %-60s %s\n", k, d
      }
      if (drafts > 0)
        printf "     mean acceptance length (incl bonus) = %.2f\n", (acc + drafts) / drafts
      if (!found) print "     (no spec metrics exposed or unchanged)"
    }' "$rdir/metrics.before.spec" "$rdir/metrics.after.spec"
  echo
}

echo "Probe target: $BASE (model: $MODEL)"
echo "Backend label: $BACKEND"
echo "Key file: $KEYFILE"
echo "Output dir: $OUT_DIR"
echo "long prompt ~$(printf '%s' "$long_prompt" | wc -w) words"
echo

for r in $ROUNDS; do
  case "$r" in
    c1-short) run_round "$r" 1 "$short_prompt" 800 ;;
    c8-short) run_round "$r" 8 "$short_prompt" 800 ;;
    c4-long)  run_round "$r" 4 "$long_prompt" 600 ;;
    *) echo "unknown round: $r (expected c1-short c8-short c4-long)" >&2; exit 2 ;;
  esac
done

echo "Raw per-token timestamps under: $OUT_DIR/<round>/reqN.tok"
