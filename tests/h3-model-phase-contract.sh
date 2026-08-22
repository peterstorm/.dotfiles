#!/usr/bin/env bash
# Behavioral contract for idle-only H3 model-family phase control.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/comfyui/h3-model-phase.sh"
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT

mkdir -p "$TEMP/bin" "$TEMP/state"
cat >"$TEMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for argument in "$@"; do
  case "$argument" in
    */queue)
      cat "$FAKE_QUEUE_RESPONSE"
      exit 0
      ;;
    */free)
      printf 'free\n' >>"$FAKE_FREE_LOG"
      printf '{}\n'
      exit 0
      ;;
  esac
done
echo "unexpected curl invocation" >&2
exit 1
EOF
chmod +x "$TEMP/bin/curl"

export PATH="$TEMP/bin:$PATH"
export FAKE_QUEUE_RESPONSE="$TEMP/queue.json"
export FAKE_FREE_LOG="$TEMP/free.log"
export H3_PHASE_STATE_DIR="$TEMP/state"
export COMFYUI_URL="http://127.0.0.1:8188"
printf '{"queue_running":[],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"

status="$($SCRIPT status)"
[[ "$status" == 'H3_PHASE_STATUS family=none running=0 pending=0' ]]
[[ ! -e "$FAKE_FREE_LOG" ]]

prepared="$($SCRIPT prepare fl2va)"
[[ "$prepared" == 'H3_PHASE_READY family=fl2va; queue only the matching BF16 workflow' ]]
[[ "$(cat "$H3_PHASE_STATE_DIR/active-family")" == fl2va ]]
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 1 ]]

printf '{"queue_running":[["active"]],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"
if "$SCRIPT" prepare ref2va >"$TEMP/busy.out" 2>"$TEMP/busy.err"; then
  echo "prepare must fail while a prompt is running" >&2
  exit 1
fi
grep -Fq 'refusing model release while ComfyUI is busy' "$TEMP/busy.err"
[[ "$(cat "$H3_PHASE_STATE_DIR/active-family")" == fl2va ]]
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 1 ]]

printf '{"queue_running":[],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"
released="$($SCRIPT release)"
[[ "$released" == 'H3_PHASE_RELEASED family=none' ]]
[[ ! -e "$H3_PHASE_STATE_DIR/active-family" ]]
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 2 ]]

if "$SCRIPT" prepare invalid >"$TEMP/invalid.out" 2>"$TEMP/invalid.err"; then
  echo "invalid H3 family must fail" >&2
  exit 1
fi
grep -Fq 'family must be fl2va or ref2va' "$TEMP/invalid.err"

if COMFYUI_URL="http://desktop:8188" "$SCRIPT" status >"$TEMP/remote.out" 2>"$TEMP/remote.err"; then
  echo "non-loopback ComfyUI URL must fail" >&2
  exit 1
fi
grep -Fq 'COMFYUI_URL must use loopback HTTP' "$TEMP/remote.err"

for unsafe_url in 'http://127.0.0.1:8188@evil.example' 'http://localhost:70000'; do
  if COMFYUI_URL="$unsafe_url" "$SCRIPT" status >"$TEMP/unsafe.out" 2>"$TEMP/unsafe.err"; then
    echo "unsafe ComfyUI URL must fail: $unsafe_url" >&2
    exit 1
  fi
done

echo 'PASS: H3 model phases prepare and release only with an idle loopback queue'
