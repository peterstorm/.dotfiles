#!/usr/bin/env bash
# Behavioral contract for idle-only GPU1 creative model-family ownership.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/comfyui/creative-model-phase.sh"
H3_ADAPTER="$ROOT/scripts/comfyui/h3-model-phase.sh"
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
export CREATIVE_MODEL_PHASE_STATE_DIR="$TEMP/state"
export COMFYUI_URL="http://127.0.0.1:8188"
printf '{"queue_running":[],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"

status="$($SCRIPT status)"
[[ "$status" == 'CREATIVE_MODEL_PHASE_STATUS family=none running=0 pending=0' ]]
[[ ! -e "$FAKE_FREE_LOG" ]]

for family in krea h3-fl2va h3-ref2va music3; do
  prepared="$($SCRIPT prepare "$family")"
  [[ "$prepared" == "CREATIVE_MODEL_PHASE_READY family=$family; queue only the matching workflow" ]]
  [[ "$(cat "$CREATIVE_MODEL_PHASE_STATE_DIR/active-family")" == "$family" ]]
done
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 4 ]]

printf '{"queue_running":[["active"]],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"
if "$SCRIPT" prepare krea >"$TEMP/busy.out" 2>"$TEMP/busy.err"; then
  echo "prepare must fail while a prompt is running" >&2
  exit 1
fi
grep -Fq 'refusing model release while ComfyUI is busy' "$TEMP/busy.err"
[[ "$(cat "$CREATIVE_MODEL_PHASE_STATE_DIR/active-family")" == music3 ]]
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 4 ]]

printf '{"queue_running":[],"queue_pending":[]}\n' >"$FAKE_QUEUE_RESPONSE"
export CREATIVE_MODEL_PHASE_BIN="$SCRIPT"
"$H3_ADAPTER" prepare fl2va | grep -Fxq \
  'CREATIVE_MODEL_PHASE_READY family=h3-fl2va; queue only the matching workflow'
[[ "$(cat "$CREATIVE_MODEL_PHASE_STATE_DIR/active-family")" == h3-fl2va ]]
"$H3_ADAPTER" prepare ref2va | grep -Fxq \
  'CREATIVE_MODEL_PHASE_READY family=h3-ref2va; queue only the matching workflow'
[[ "$(cat "$CREATIVE_MODEL_PHASE_STATE_DIR/active-family")" == h3-ref2va ]]

released="$($SCRIPT release)"
[[ "$released" == 'CREATIVE_MODEL_PHASE_RELEASED family=none' ]]
[[ ! -e "$CREATIVE_MODEL_PHASE_STATE_DIR/active-family" ]]
[[ "$(wc -l <"$FAKE_FREE_LOG")" -eq 7 ]]

if "$SCRIPT" prepare invalid >"$TEMP/invalid.out" 2>"$TEMP/invalid.err"; then
  echo "invalid family must fail" >&2
  exit 1
fi
grep -Fq 'family must be krea, h3-fl2va, h3-ref2va, or music3' "$TEMP/invalid.err"

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

echo 'PASS: creative model phases serialize Krea, both H3 families, and Music 3 on an idle loopback queue'
