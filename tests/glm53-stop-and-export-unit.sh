#!/usr/bin/env bash
# Unit test for scripts/inference/glm53/stop-and-export-glm53-hyperflare.sh.
# The driver's decisions are exercised against stub docker / nvidia-smi / export
# wrapper commands; nothing touches real containers or GPUs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/inference/glm53/stop-and-export-glm53-hyperflare.sh"

failures=0
cases=0
check() {
  cases=$((cases + 1))
  if ! eval "$2"; then
    failures=$((failures + 1))
    echo "FAIL $1" >&2
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- stubs ---------------------------------------------------------------------------

# docker stub: ps reads a names file, stop records its argument.
cat > "$TMP/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) [ -f "$TMP/running.txt" ] && cat "$TMP/running.txt" || true ;;
  stop) echo "stopped \${!#}" >> "$TMP/docker-actions.txt" ;;
esac
EOF
chmod +x "$TMP/docker"

# nvidia-smi stub: cats a configurable file (missing file = command failure).
cat > "$TMP/nvidia-smi" <<EOF
#!/usr/bin/env bash
cat "$TMP/gpu.txt"
EOF
chmod +x "$TMP/nvidia-smi"

write_gpu() { printf '%s\n' "$@" > "$TMP/gpu.txt"; }

# export wrapper stub: records the VARIANT it was given, then succeeds or fails.
cat > "$TMP/wrapper-ok" <<EOF
#!/usr/bin/env bash
echo "variant=\$VARIANT" >> "$TMP/wrapper-calls.txt"
echo "PACKAGE OK: glm53-cyber-hybrid-bf16@gb202-tp2-202611151234"
EOF
cat > "$TMP/wrapper-fail" <<EOF
#!/usr/bin/env bash
echo "variant=\$VARIANT" >> "$TMP/wrapper-calls.txt"
exit 7
EOF
chmod +x "$TMP/wrapper-ok" "$TMP/wrapper-fail"

source "$SCRIPT"

configure() {
  DOCKER="$TMP/docker"
  NVIDIA_SMI="$TMP/nvidia-smi"
  STATUS_FILE="$TMP/status.txt"
  LOG="$TMP/export.log"
  POLL_SECONDS=0
  IDLE_CHECKS=2
}

# --- stop_primaries ------------------------------------------------------------------

configure
: > "$TMP/running.txt"
printf '%s\n' glm53-flash-hyperflare-tp2-v16 glm53-flash-hyperflare-tp2-cyber-hybrid ds41-1017-native comfyui > "$TMP/running.txt"
STATUS_FILE="$TMP/status.txt" stop_primaries
check "both hyperflare primaries stopped" \
  '[ "$(cat "$TMP/docker-actions.txt")" = "stopped glm53-flash-hyperflare-tp2-v16
stopped glm53-flash-hyperflare-tp2-cyber-hybrid" ]'
check "foreign containers are never stopped" \
  '! grep -qE "ds41|comfyui" "$TMP/docker-actions.txt"'
check "stop phase recorded" 'grep -q "stopping glm53-flash-hyperflare-tp2-v16" "$TMP/status.txt"'

configure
rm -f "$TMP/docker-actions.txt" "$TMP/running.txt"
STATUS_FILE="$TMP/status.txt" stop_primaries
check "no primaries running is recorded, nothing stopped" \
  '[ ! -f "$TMP/docker-actions.txt" ] && grep -q "no hyperflare primaries were running" "$TMP/status.txt"'

# --- await_idle_gpus -----------------------------------------------------------------

configure
write_gpu 500 500
GPU_WAIT_SECONDS=30 await_idle_gpus
check "both GPUs idle passes" '[ $? = 0 ]'

configure
write_gpu 500 5000
GPU_WAIT_SECONDS=1 await_idle_gpus 2>/dev/null && result=0 || result=$?
check "one busy GPU fails the wait" '[ "$result" = 1 ]'
check "busy GPUs recorded with their memory" 'grep -q "gpus still busy: 500 5000" "$TMP/status.txt"'

configure
write_gpu 500 500 9000
GPU_WAIT_SECONDS=1 await_idle_gpus 2>/dev/null && result=0 || result=$?
check "a busy third GPU row fails the wait" '[ "$result" = 1 ]'

configure
rm -f "$TMP/gpu.txt"
GPU_WAIT_SECONDS=1 await_idle_gpus 2>/dev/null && result=0 || result=$?
check "a failing nvidia-smi counts as busy, not a crash" '[ "$result" = 1 ]'

# --- main ----------------------------------------------------------------------------

configure
rm -f "$TMP/running.txt" "$TMP/status.txt"
write_gpu 500 500
EXPORT_WRAPPER="$TMP/wrapper-ok" main cyber-hybrid-bf16
check "main succeeds end to end" '[ $? = 0 ]'
check "wrapper received the variant" \
  '[ "$(cat "$TMP/wrapper-calls.txt")" = "variant=cyber-hybrid-bf16" ]'
check "status records start, wait, export, done" \
  'grep -q "driver start" "$TMP/status.txt" && grep -q "waiting for idle GPUs" "$TMP/status.txt" \
   && grep -q "export starting" "$TMP/status.txt" && grep -q "done glm53-cyber-hybrid-bf16@gb202-tp2-202611151234" "$TMP/status.txt"'
check "PACKAGE line comes from the wrapper's log" \
  'grep -q "PACKAGE OK: glm53-cyber-hybrid-bf16" "$TMP/export.log"'

configure
rm -f "$TMP/running.txt" "$TMP/status.txt" "$TMP/wrapper-calls.txt"
write_gpu 500 500
EXPORT_WRAPPER="$TMP/wrapper-fail" main cyber-hybrid-bf16 2>/dev/null && result=0 || result=$?
check "a failed export fails main" '[ "$result" = 1 ]'
check "failure recorded with the exit code" 'grep -q "failed exit=7" "$TMP/status.txt"'

configure
rm -f "$TMP/status.txt" "$TMP/wrapper-calls.txt"
write_gpu 500 5000
GPU_WAIT_SECONDS=1 EXPORT_WRAPPER="$TMP/wrapper-ok" main cyber-hybrid-bf16 2>/dev/null && result=0 || result=$?
check "busy GPUs abort before the export" '[ "$result" = 1 ]'
check "the wrapper never ran on busy GPUs" '[ ! -f "$TMP/wrapper-calls.txt" ]'
check "abort recorded" 'grep -q "aborted: GPUs never went idle" "$TMP/status.txt"'

configure
rm -f "$TMP/status.txt"
main 2>/dev/null && result=0 || result=$?
check "missing VARIANT refuses with status 2" '[ "$result" = 2 ]'

if [ "$failures" -ne 0 ]; then
  echo "stop-and-export unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "stop-and-export unit: PASS ($cases checks)"
