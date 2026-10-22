#!/usr/bin/env bash
# A/B the tensor split (--tp 2) against the layer split (--tp 1) on identical
# cold prompts, then leave the winner serving.
#
#   tp 2: one group of both cards - every expert is sharded, so the group's
#         budget is its *tightest* member's and GPU 1 idles ~11 GB.
#   tp 1: each card is its own group - it packs experts to its own ceiling
#         (about +1,180 more in VRAM), and every layer has one member, which is
#         the gate v1.1.19's ~1.5x prompt skip needs. The cost is one
#         inter-GPU hop per layer boundary in decode.
#
# Both runs see the same payloads, prefixed with a nonce so neither can reuse a
# parked conversation or a KV prefix - a fair cold read, same token count.
# TRY_EXTRA adds flags to the try variant and is removed again on rollback:
#   TRY_EXTRA="--threads on" - the layer split serialises the prompt path (par is
#   only on for --threads or tp > 1), so this asks for a thread a GPU.
# Keep the try variant if it does not lose prefill (>5%) and wins decode (>=10%):
# a prompt is read once per conversation, a decode runs for every token after it.
# slot folder (a conversation saved by one geometry is not safe to resume in
# the other) and that folder is removed on rollback. Receipt:
# ~/.local/state/ds41-maya/tp-ab-latest.txt
set -uo pipefail

RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-ds41-1017-maya-exl35.sh"
KEYFILE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" && pwd)/inference-api-key.sh"
CONFIG=/models/ds41/project-maya/maya-ds4.json
LOG_FILE=/models/ds41/project-maya/maya-ds4.log
QUANT_DIR=/models/ds41/DeepSeek-V4.1-Flash-1017-3.5bpw
NAME=ds41-1017-maya-exl35
BASE_TP="${BASE_TP:-2}"
TRY_TP="${TRY_TP:-1}"
TRY_EXTRA="${TRY_EXTRA:-}"
TRY_TAG="${TRY_TAG:-tp$TRY_TP${TRY_EXTRA:+$(echo "$TRY_EXTRA" | tr -d ' -' | tr ' ' '_')}}"
DELAY="${1:-0}"
STATE="$HOME/.local/state/ds41-maya"
mkdir -p "$STATE"
LOG="$STATE/tp-ab-$(date +%Y%m%d-%H%M%S).log"
RESULT="$STATE/tp-ab-latest.txt"
exec >>"$LOG" 2>&1
say() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

# --- the payloads, built once so every run reads the same bytes ---------------
build() {
  [ -f "$STATE/ab-24k.txt" ] && [ -f "$STATE/ab-70k.txt" ] && return 0
  python3 - "$STATE" <<'PY'
import sys
d = sys.argv[1]
line = ("The archive holds quarterly ledgers, shipping manifests and field notes that the team "
        "reviewed before the season turned, and every page of it stayed in the room for a year. ")
for name, target in (("ab-24k.txt", 108_000), ("ab-70k.txt", 318_000)):
    body = ""
    while len(body) < target:
        body += line
    open(f"{d}/{name}", "w").write(body)
PY
  say "payloads built"
}

set_arg() {  # name, value ("" removes the pair)
  local n=$1 v=$2
  jq --arg n "$n" --arg v "$v" '.args |= ((index($n)) as $i
      | if $v == "" then (if $i == null then . else .[:$i] + .[$i + 2:] end)
        elif $i == null then . + [$n, $v] else .[:$i + 1] + [$v] + .[$i + 2:] end)' \
    "$CONFIG" >"$STATE/config.json" || { say "ERROR: could not read $CONFIG"; return 1; }
  cp "$STATE/config.json" "$CONFIG" || { say "ERROR: could not write $CONFIG"; return 1; }
  jq -e --arg n "$n" --arg v "$v" '.args | (index($n)) as $i
      | if $v == "" then $i == null else (.[$i + 1] == $v) end' "$CONFIG" >/dev/null \
    || { say "ERROR: $CONFIG still has $n=$v"; return 1; }
  say "config $n ${v:-removed}"
}

stop_engine() {
  docker stop -t 45 "$NAME" >/dev/null 2>&1
  local i
  for i in $(seq 1 30); do
    ss -H -ltn | awk '{print $4}' | grep -Eq '(^|:)8000$' || { say "port 8000 free"; return 0; }
    sleep 2
  done
  say "WARN: port 8000 is still listening"
  return 1
}

# The invariant is "the engine emitted tokens": a reasoning model puts them in
# reasoning_content and leaves content null.
gate() {
  local deadline=$((SECONDS + $1)) key body
  # shellcheck disable=SC1090
  source "$KEYFILE_HELPER"
  while ((SECONDS < deadline)); do
    if curl -fsS --connect-timeout 2 --max-time 5 http://127.0.0.1:8000/health 2>/dev/null \
         | jq -e '.status == "ok" and .unloaded == false' >/dev/null 2>&1; then
      inference_resolve_client_keyfile || { say "ERROR: no client key"; return 1; }
      key="$(<"$INFERENCE_CLIENT_KEYFILE")"
      body="$(curl -fsS --connect-timeout 5 --max-time 180 -H "Authorization: Bearer $key" \
        -H 'Content-Type: application/json' \
        -d '{"model":"deepseek-v4.1-flash","messages":[{"role":"user","content":"Reply with the single word: ok"}],"max_tokens":24,"temperature":0}' \
        http://127.0.0.1:8000/v1/chat/completions 2>/dev/null)"
      if jq -e '.choices[0].message | ((.content // "") + (.reasoning_content // "")) | length > 0' \
           <<<"$body" >/dev/null 2>&1; then
        say "HEALTHY"
        return 0
      fi
    fi
    sleep 5
  done
  say "ERROR: no working model within ${1}s"
  return 1
}

launch() {  # tp, slot dir
  local before
  before="$(wc -l <"$LOG_FILE" 2>/dev/null || echo 0)"
  SLOT_DIR="$2" CONTEXT=262144 "$RUN" --launch || { say "ERROR: launch at tp $1 failed"; return 1; }
  docker update --restart=unless-stopped "$NAME" >/dev/null 2>&1 \
    || say "WARN: restart policy not promoted"
  tail -n +$((before + 1)) "$LOG_FILE" | grep -E "^ds4: CUDA[01] " | tail -2 | sed 's/^/    /'
  say "launched at tp $1 (slots $2)"
}

request() {  # tag, base, max_tokens
  local tag=$1 base=$2 mt=$3 key nonce
  # shellcheck disable=SC1090
  source "$KEYFILE_HELPER"
  inference_resolve_client_keyfile || { say "ERROR: no client key"; return 1; }
  key="$(<"$INFERENCE_CLIENT_KEYFILE")"
  nonce="Measurement $tag $(od -An -N4 -tx1 /dev/urandom | tr -d ' \n'). "
  jq -Rs --arg n "$nonce" --argjson m "$mt" \
    '{model:"deepseek-v4.1-flash", max_tokens:$m, temperature:0,
      messages:[{role:"user", content:($n + .)}]}' "$base" >"$STATE/ab-$tag.json"
  curl -fsS --max-time 1800 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d @"$STATE/ab-$tag.json" http://127.0.0.1:8000/v1/chat/completions >"$STATE/ab-$tag.out" 2>&1 \
    || { say "ERROR: request $tag failed: $(head -c 200 "$STATE/ab-$tag.out")"; return 1; }
}

measure() {  # tag
  local tag=$1 key body
  request "$tag-24k" "$STATE/ab-24k.txt" 1 || return 1
  request "$tag-70k"  "$STATE/ab-70k.txt" 128 || return 1
  request "$tag-70k2" "$STATE/ab-70k.txt" 128 || return 1
  key="$(cat "$HOME/.config/ds4-flash/api-key" 2>/dev/null)"
  body="$(curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:8000/metrics 2>/dev/null)"
  # decode is sampled twice: one 128-token run spreads ~13% on this engine, so a
  # single sample cannot tell a real gain from noise.
  printf '%s prefill_tok=%s prefill=%s decode_tok=%s decode=%s decode_b=%s vram_hit=%s slots=%s cpu_experts=%s free=%s\n' \
    "$tag" \
    "$(jq -r '.usage.prompt_tokens' "$STATE/ab-$tag-24k.out")" \
    "$(jq -r '.timings.prompt_per_second | floor' "$STATE/ab-$tag-24k.out")" \
    "$(jq -r '.usage.prompt_tokens' "$STATE/ab-$tag-70k.out")" \
    "$(jq -r '.timings.predicted_per_second | floor' "$STATE/ab-$tag-70k.out")" \
    "$(jq -r '.timings.predicted_per_second | floor' "$STATE/ab-$tag-70k2.out")" \
    "$(jq -r '.tiers.now.vram_hit' <<<"$body")" \
    "$(jq -r '.engine.expert_slots' <<<"$body")" \
    "$(jq -r '.engine.cpu_experts' <<<"$body")" \
    "$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | tr -d ' ' | paste -sd/)" \
    | tee -a "$RESULT"
}

field() { awk -v t="$1" -v f="$2" '$1 == t { for (i = 2; i <= NF; i++) { split($i, kv, "="); if (kv[1] == f) print kv[2] } }' "$RESULT" | tail -1; }

# apply (1) or remove (0) TRY_EXTRA's flag pairs
set_tp() { set_arg --tp "$1"; }
try_args() {
  [ -n "$TRY_EXTRA" ] || return 0
  local -a pairs=()
  read -r -a pairs <<<"$TRY_EXTRA"
  local i
  for ((i = 0; i + 1 < ${#pairs[@]}; i += 2)); do
    set_arg "${pairs[i]}" "$([ "$1" = 1 ] && echo "${pairs[i + 1]}" || echo "")" || return 1
  done
}

say "TP A/B: base tp $BASE_TP, trying tp $TRY_TP ${TRY_EXTRA:-}, delay ${DELAY}s"
sleep "$DELAY"
: >"$RESULT"
build || exit 1
measure "tp$BASE_TP" || say "WARN: baseline measurement incomplete"
if set_tp "$TRY_TP" && try_args 1 && stop_engine && \
   launch "$TRY_TP" "$QUANT_DIR/maya-ds4/slots-tp$TRY_TP" && gate 2400 && measure "$TRY_TAG"; then
  p0=$(field "tp$BASE_TP" prefill); d0=$(field "tp$BASE_TP" decode); d0b=$(field "tp$BASE_TP" decode_b)
  p1=$(field "$TRY_TAG" prefill); d1=$(field "$TRY_TAG" decode); d1b=$(field "$TRY_TAG" decode_b)
  keep=$(awk -v p0="$p0" -v d0="$d0" -v d0b="$d0b" -v p1="$p1" -v d1="$d1" -v d1b="$d1b" \
    'BEGIN { b = (d0 + d0b) / 2; t = (d1 + d1b) / 2;
             print (p0 > 0 && b > 0 && p1 >= p0 * 0.95 && t >= b * 1.10) ? "yes" : "no" }')
  say "A/B: prefill $p0 -> $p1 tok/s, decode $d0/$d0b -> $d1/$d1b tok/s, keep $TRY_TAG: $keep"
  if [ "$keep" = yes ]; then
    { echo "outcome=$TRY_TAG KEPT"; cat "$RESULT"; } >"$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
    say "TP A/B DONE: $TRY_TAG stays"
    exit 0
  fi
  say "$TRY_TAG did not win; back to tp $BASE_TP"
fi
set_tp "$BASE_TP" && try_args 0 && stop_engine && \
  launch "$BASE_TP" "$QUANT_DIR/maya-ds4/slots" && gate 2400 && measure "tp$BASE_TP-restored"
rm -rf "$QUANT_DIR/maya-ds4/slots-tp$TRY_TP"
{ echo "outcome=TENSOR SPLIT KEPT (tp $BASE_TP)"; cat "$RESULT"; } >"$RESULT.tmp" && mv "$RESULT.tmp" "$RESULT"
say "TP A/B DONE: tp $BASE_TP stays; log: $LOG"
