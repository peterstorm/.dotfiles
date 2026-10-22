#!/usr/bin/env bash
# Raise the served context of ds41-1017-maya-exl35 to TARGET, prove the window
# is really open by retrieving facts buried deep in a long prompt, and go back
# to FALLBACK if the engine will not serve — never leave the desktop dark.
#
#   raise-context-ds41-1017-maya-exl35.sh [delay_seconds]
#   TARGET=524288 ./raise-context… 120
#
# The window is two numbers that must move together: CONTEXT in the run script
# and --max-context in the pack's maya-ds4.json. --launch refuses a pair that
# disagrees, so this script writes the config first, then launches with the same
# TARGET; a config it cannot rewrite leaves the running engine untouched.
#
# The needle is filler prose with facts at 15% and 80% depth, asked for from the
# end of the prompt, so a server that truncates or ignores the tail cannot pass.
# Receipt: ~/.local/state/ds41-maya/context-raise-latest.txt
set -uo pipefail

RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/run-ds41-1017-maya-exl35.sh"
KEYFILE_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../shared" && pwd)/inference-api-key.sh"
CONFIG=/models/ds41/project-maya/maya-ds4.json
LOG_FILE=/models/ds41/project-maya/maya-ds4.log
NAME=ds41-1017-maya-exl35
STATE="$HOME/.local/state/ds41-maya"
TARGET="${TARGET:-262144}"
FALLBACK="${FALLBACK:-131072}"
DELAY="${1:-0}"
mkdir -p "$STATE"
LOG="$STATE/context-raise-$(date +%Y%m%d-%H%M%S).log"
OUT="$STATE/context-raise-latest.txt"
exec >>"$LOG" 2>&1
say() { printf "[%s] %s\n" "$(date +%H:%M:%S)" "$*"; }

# The config is gitignored, but a temp file left inside the checkout would make
# the next --preflight fail as a dirty tree: write beside it in $STATE.
set_context() {
  jq --arg c "$1" '.args |= ((index("--max-context")) as $i
      | if $i == null then . + ["--max-context", $c] else .[:$i + 1] + [$c] + .[$i + 2:] end)' \
    "$CONFIG" >"$STATE/config.json" \
    || { say "ERROR: could not read $CONFIG"; return 1; }
  cp "$STATE/config.json" "$CONFIG" || { say "ERROR: could not write $CONFIG"; return 1; }
  jq -e --arg c "$1" '.args | (index("--max-context")) as $i | .[$i + 1] == $c' "$CONFIG" >/dev/null \
    || { say "ERROR: $CONFIG is still not at $1"; return 1; }
  say "config --max-context=$1"
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

# The invariant is "the engine emitted tokens", not "the answer was pretty":
# reasoning models put them in reasoning_content and leave content null.
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

launch() {
  CONTEXT="$1" "$RUN" --launch || { say "ERROR: launch at $1 failed"; return 1; }
  docker update --restart=unless-stopped "$NAME" >/dev/null 2>&1 \
    || say "WARN: restart policy not promoted"
  say "launched $NAME at context $1"
}

needle() {
  local key answer code
  # shellcheck disable=SC1090
  source "$KEYFILE_HELPER"
  inference_resolve_client_keyfile || { say "ERROR: no client key"; return 1; }
  key="$(<"$INFERENCE_CLIENT_KEYFILE")"
  # Sized by characters, never by a line count: this engine tokenises English at
  # ~4.85 chars a token (measured: 800,256 chars -> 164,843 tokens), so 995,000
  # chars lands near 205K — under TARGET and far past the old 131,072 wall.
  python3 - "$STATE" <<'PY'
import json, sys
d = sys.argv[1]
line = ("Alpha {i}: the archive holds quarterly ledgers, shipping manifests and field notes that the "
        "team reviewed before the season turned, and every page of it stayed in the room. ")
filler, i = "", 0
while len(filler) < 995_000:
    i += 1
    filler += line.format(i=i)
low, high = "The vault code is 7-3-9-Q-P-4.\n", "The dock number is K-4-8-1.\n"
a, b = len(filler) * 15 // 100, len(filler) * 80 // 100
body = filler[:a] + low + filler[a:b] + high + filler[b:]
body += "\n\nQuestion: what is the vault code and what is the dock number? Answer with both codes only."
json.dump({"model": "deepseek-v4.1-flash", "max_tokens": 128, "temperature": 0,
           "messages": [{"role": "user", "content": body}]}, open(f"{d}/needle.json", "w"))
print(f"needle built: {len(body)} chars")
PY
  curl -fsS --max-time 1800 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d @"$STATE/needle.json" http://127.0.0.1:8000/v1/chat/completions >"$STATE/needle.out" 2>&1
  answer="$(jq -r '[.choices[0].message | (.reasoning_content // ""), (.content // "")] | join(" ")' \
    "$STATE/needle.out" 2>/dev/null)"
  code="$(printf '%s' "$answer" | tr -cd 'A-Za-z0-9' | tr '[:lower:]' '[:upper:]')"
  say "needle: prompt=$(jq -r '.usage.prompt_tokens' "$STATE/needle.out" 2>/dev/null) tokens, \
prefill=$(jq -r '.timings.prompt_per_second | floor' "$STATE/needle.out" 2>/dev/null) tok/s, \
decode=$(jq -r '.timings.predicted_per_second | floor' "$STATE/needle.out" 2>/dev/null) tok/s"
  case "$code" in
    *739QP4*K481*) say "needle: BOTH FOUND"; return 0 ;;
    *) say "needle: MISSED (${answer:0:80})"; return 1 ;;
  esac
}

receipt() {
  local key
  key="$(cat "$HOME/.config/ds4-flash/api-key" 2>/dev/null)"
  {
    echo "outcome=$1"
    echo "time=$(date -Is)"
    echo "config_args=$(jq -c '.args' "$CONFIG")"
    echo "health=$(curl -fsS http://127.0.0.1:8000/health | jq -c '{max_context, unloaded, model}')"
    echo "engine=$(curl -fsS -H "Authorization: Bearer $key" http://127.0.0.1:8000/metrics 2>/dev/null \
      | jq -c '.engine | {context, kv, kv_resident, expert_slots, cpu_experts, ram_experts}')"
    echo "needle=$(jq -r '"prompt=\(.usage.prompt_tokens) prefill=\(.timings.prompt_per_second|floor) tok/s decode=\(.timings.predicted_per_second|floor) tok/s"' "$STATE/needle.out" 2>/dev/null)"
    echo "--- boot placement"
    grep -E "^ds4: CUDA[01] " "$LOG_FILE" | tail -2
    echo "--- gpus"
    nvidia-smi --query-gpu=index,memory.used,memory.total --format=csv,noheader | tr '\n' ' '; echo
    echo "--- host ram"
    free -g | sed -n 2p
  } >"$OUT" 2>&1
  say "receipt: $OUT"
}

say "context raise scheduled: target=$TARGET fallback=$FALLBACK delay=${DELAY}s"
sleep "$DELAY"
say "raising context to $TARGET"
set_context "$TARGET" || { say "aborted before touching the engine"; exit 1; }
stop_engine
if launch "$TARGET" && gate 2400 && needle; then
  receipt "RAISED to $TARGET (needle retrieved at two depths)"
  say "CONTEXT RAISE DONE"
else
  say "$TARGET did not serve or missed the needle; back to $FALLBACK"
  set_context "$FALLBACK"
  stop_engine
  if launch "$FALLBACK" && gate 2400; then
    receipt "FALLBACK: back at $FALLBACK, serving"
  else
    receipt "BROKEN: nothing serves - needs a human"
  fi
fi
say "context raise finished; log: $LOG"
