#!/usr/bin/env bash
# Unit test for scripts/inference/glm53/stop-and-export-glm53-hyperflare.sh.
# The driver's decisions are exercised against stub docker / nvidia-smi / export
# wrapper commands; nothing touches real containers or GPUs.
# shellcheck disable=SC2034 # configure's settings are read by the sourced driver; result/want/want_last inside check's eval strings
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

# docker stub: ps reads a names file, stop and start record their argument; start
# fails while $TMP/start-fails exists, stop for a name listed in $TMP/stop-fails.
cat > "$TMP/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
  ps) [ -f "$TMP/running.txt" ] && cat "$TMP/running.txt" || true ;;
  stop) grep -qx "\${!#}" "$TMP/stop-fails" 2>/dev/null && exit 1
        echo "stopped \${!#}" >> "$TMP/docker-actions.txt" ;;
  start) [ -f "$TMP/start-fails" ] && exit 1
         echo "started \${!#}" >> "$TMP/docker-actions.txt" ;;
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
echo "root=\$ROOT_HOST" > "$TMP/wrapper-env.txt"
echo "PACKAGE OK: glm53-uncensored@gb202-tp2-202611151234"
EOF
cat > "$TMP/wrapper-fail" <<EOF
#!/usr/bin/env bash
echo "variant=\$VARIANT" >> "$TMP/wrapper-calls.txt"
exit 7
EOF
chmod +x "$TMP/wrapper-ok" "$TMP/wrapper-fail"

# shellcheck source=scripts/inference/glm53/stop-and-export-glm53-hyperflare.sh
source "$SCRIPT"

GiB=$((1024 * 1024 * 1024))

# The real variant table, a checkpoint store with the uncensored checkpoint in it, and
# a disk that is two numbers the test sets (the measurements are the I/O seam).
mkdir -p "$TMP/models/glm53-uncensored"
echo '{}' > "$TMP/models/glm53-uncensored/config.json"
checkpoint_bytes() { echo "$CKPT_BYTES"; }
avail_bytes() { echo "$AVAIL_BYTES"; }

configure() {
  DOCKER="$TMP/docker"
  ROOT_HOST="$TMP/models"
  VARIANTS_LIB="$ROOT/scripts/inference/glm53/hyperflare-variants.sh"
  CKPT_BYTES=$((167 * GiB))
  AVAIL_BYTES=$((400 * GiB))
  NVIDIA_SMI="$TMP/nvidia-smi"
  STATUS_FILE="$TMP/status.txt"
  LOG="$TMP/export.log"
  POLL_SECONDS=0
  IDLE_CHECKS=2
  STOPPED=()
  rm -f "$TMP/start-fails" "$TMP/stop-fails"
}

# The last status line: what a poller reads as the outcome.
last_status() { tail -1 "$TMP/status.txt"; }

# --- stop_primaries ------------------------------------------------------------------

configure
: > "$TMP/running.txt"
printf '%s\n' glm53-flash-hyperflare-tp2-v16 glm53-flash-hyperflare-tp2-uncensored ds41-1017-native comfyui > "$TMP/running.txt"
STATUS_FILE="$TMP/status.txt" stop_primaries
check "both hyperflare primaries stopped" \
  '[ "$(cat "$TMP/docker-actions.txt")" = "stopped glm53-flash-hyperflare-tp2-v16
stopped glm53-flash-hyperflare-tp2-uncensored" ]'
check "foreign containers are never stopped" \
  '! grep -qE "ds41|comfyui" "$TMP/docker-actions.txt"'
check "stop phase recorded" 'grep -q "stopping glm53-flash-hyperflare-tp2-v16" "$TMP/status.txt"'
check "the stopped primaries are remembered for the restore" \
  '[ "${STOPPED[*]}" = "glm53-flash-hyperflare-tp2-v16 glm53-flash-hyperflare-tp2-uncensored" ]'

configure
rm -f "$TMP/docker-actions.txt"
printf '%s\n' glm53-flash-hyperflare-tp2-uncensored-export glm53-flash-hyperflare-tp2-v16 > "$TMP/running.txt"
STATUS_FILE="$TMP/status.txt" stop_primaries
check "a leftover export container is stopped but never restored" \
  'grep -q "stopped glm53-flash-hyperflare-tp2-uncensored-export" "$TMP/docker-actions.txt" \
   && [ "${STOPPED[*]}" = "glm53-flash-hyperflare-tp2-v16" ]'

configure
rm -f "$TMP/docker-actions.txt"
STOPPED=(glm53-flash-hyperflare-tp2-v16)
STATUS_FILE="$TMP/status.txt" restore_primaries
check "restore starts what was stopped and records it" \
  '[ "$(cat "$TMP/docker-actions.txt")" = "started glm53-flash-hyperflare-tp2-v16" ] \
   && grep -q "restarted glm53-flash-hyperflare-tp2-v16" "$TMP/status.txt"'
configure
touch "$TMP/start-fails"
STOPPED=(glm53-flash-hyperflare-tp2-v16)
STATUS_FILE="$TMP/status.txt" restore_primaries && result=0 || result=$?
check "a primary that will not start fails the restore, recorded" \
  '[ "$result" = 1 ] && grep -q "failed to restart glm53-flash-hyperflare-tp2-v16" "$TMP/status.txt"'
configure
rm -f "$TMP/docker-actions.txt"
STATUS_FILE="$TMP/status.txt" restore_primaries
check "nothing stopped, nothing started" '[ ! -f "$TMP/docker-actions.txt" ]'

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
EXPORT_WRAPPER="$TMP/wrapper-ok" main uncensored
check "main succeeds end to end" '[ $? = 0 ]'
check "wrapper received the variant" \
  '[ "$(cat "$TMP/wrapper-calls.txt")" = "variant=uncensored" ]'
check "status records start, wait, export, done" \
  'grep -q "driver start" "$TMP/status.txt" && grep -q "waiting for idle GPUs" "$TMP/status.txt" \
   && grep -q "export starting" "$TMP/status.txt" && grep -q "done glm53-uncensored@gb202-tp2-202611151234" "$TMP/status.txt"'
check "PACKAGE line comes from the wrapper's log" \
  'grep -q "PACKAGE OK: glm53-uncensored" "$TMP/export.log"'
check "preflight verdict recorded before any stop" \
  '[ "$(grep -n "preflight ok" "$TMP/status.txt" | cut -d: -f1)" -lt "$(grep -n "no hyperflare primaries" "$TMP/status.txt" | cut -d: -f1)" ]'
check "the wrapper exports from the same state root the preflight checked" \
  '[ "$(cat "$TMP/wrapper-env.txt")" = "root=$TMP/models" ]'

# Regression, 2026-11-15: a wrapper without its exec bit (exit 126) still runs.
configure
rm -f "$TMP/status.txt" "$TMP/wrapper-calls.txt"
write_gpu 500 500
cp "$TMP/wrapper-ok" "$TMP/wrapper-noexec"
chmod -x "$TMP/wrapper-noexec"
EXPORT_WRAPPER="$TMP/wrapper-noexec" main uncensored 2>/dev/null && result=0 || result=$?
check "a wrapper without its exec bit still runs" \
  '[ "$result" = 0 ] && [ "$(cat "$TMP/wrapper-calls.txt")" = "variant=uncensored" ]'

configure
rm -f "$TMP/running.txt" "$TMP/status.txt" "$TMP/wrapper-calls.txt"
write_gpu 500 500
EXPORT_WRAPPER="$TMP/wrapper-fail" main uncensored 2>/dev/null && result=0 || result=$?
check "a failed export fails main" '[ "$result" = 1 ]'
check "failure recorded with the exit code" 'grep -q "failed exit=7" "$TMP/status.txt"'

configure
rm -f "$TMP/status.txt" "$TMP/wrapper-calls.txt"
write_gpu 500 5000
GPU_WAIT_SECONDS=1 EXPORT_WRAPPER="$TMP/wrapper-ok" main uncensored 2>/dev/null && result=0 || result=$?
check "busy GPUs abort before the export" '[ "$result" = 1 ]'
check "the wrapper never ran on busy GPUs" '[ ! -f "$TMP/wrapper-calls.txt" ]'
check "abort recorded" 'grep -q "aborted: GPUs never went idle" "$TMP/status.txt"'

# Regression, 2026-11-15: a refused export left v16 stopped and the endpoint dark.
# Every outcome after the stop starts the primary again before the terminal line.
for outcome in "done:$TMP/wrapper-ok:500:0:done glm53-uncensored@" \
               "failed:$TMP/wrapper-fail:500:1:failed exit=7" \
               "busy:$TMP/wrapper-ok:30000:1:aborted: GPUs never went idle"; do
  IFS=: read -r label wrapper gpu want_status want_last <<<"$outcome"
  configure
  rm -f "$TMP/status.txt" "$TMP/docker-actions.txt"
  echo glm53-flash-hyperflare-tp2-v16 > "$TMP/running.txt"
  write_gpu "$gpu" "$gpu"
  GPU_WAIT_SECONDS=1 EXPORT_WRAPPER="$wrapper" main uncensored 2>/dev/null && result=0 || result=$?
  check "$label: main exits $want_status" '[ "$result" = "$want_status" ]'
  check "$label: v16 stopped, then started again" \
    '[ "$(cat "$TMP/docker-actions.txt")" = "stopped glm53-flash-hyperflare-tp2-v16
started glm53-flash-hyperflare-tp2-v16" ]'
  check "$label: the restart is recorded before the terminal line" \
    '[ "$(tail -2 "$TMP/status.txt" | head -1 | cut -d" " -f2-)" = "restarted glm53-flash-hyperflare-tp2-v16" ] \
     && [[ "$(last_status)" == *"$want_last"* ]]'
done

configure
rm -f "$TMP/status.txt" "$TMP/docker-actions.txt"
echo glm53-flash-hyperflare-tp2-v16 > "$TMP/running.txt"
write_gpu 500 500
touch "$TMP/start-fails"
EXPORT_WRAPPER="$TMP/wrapper-ok" main uncensored 2>/dev/null && result=0 || result=$?
check "an export that succeeded but whose primary will not restart exits 1" \
  '[ "$result" = 1 ] && grep -q "failed to restart glm53-flash-hyperflare-tp2-v16" "$TMP/status.txt"'
# Regression (review, 2026-11-15): the terminal line said "done" while the endpoint was down.
check "its terminal line is a failure naming the package, never done" \
  '[[ "$(last_status | cut -d" " -f2-)" == "failed: exported glm53-uncensored@gb202-tp2-202611151234, but a stopped primary did not restart"* ]] \
   && ! grep -q " done " "$TMP/status.txt"'

configure
rm -f "$TMP/status.txt" "$TMP/docker-actions.txt" "$TMP/wrapper-calls.txt"
printf '%s\n' glm53-flash-hyperflare-tp2-v16 glm53-flash-hyperflare-tp2-uncensored > "$TMP/running.txt"
echo glm53-flash-hyperflare-tp2-uncensored > "$TMP/stop-fails"
write_gpu 500 500
EXPORT_WRAPPER="$TMP/wrapper-ok" main uncensored 2>/dev/null && result=0 || result=$?
check "a primary that will not stop aborts, restores what did stop, never exports" \
  '[ "$result" = 1 ] && [ ! -f "$TMP/wrapper-calls.txt" ] \
   && grep -q "started glm53-flash-hyperflare-tp2-v16" "$TMP/docker-actions.txt" \
   && [[ "$(last_status)" == *"aborted: a primary would not stop"* ]]'

configure
rm -f "$TMP/status.txt"
main 2>/dev/null && result=0 || result=$?
check "missing VARIANT refuses with status 2" '[ "$result" = 2 ]'

# --- export_fits (pure) --------------------------------------------------------------

check "fits exactly at checkpoint + margin" 'export_fits $((100 * GiB)) $((110 * GiB)) 10'
check "one byte short does not fit" '! export_fits $((100 * GiB)) $((110 * GiB - 1)) 10'
check "the 2026-11-15 disk (167 GiB checkpoint, 142 GiB free) does not fit" \
  '! export_fits $((167 * GiB)) $((142 * GiB)) 10'
check "zero margin needs just the checkpoint" 'export_fits $((100 * GiB)) $((100 * GiB)) 0'

# --- preflight refusals: each leaves the primary running ------------------------------

# refuses NAME VARIANT EXPECTED_STATUS_FRAGMENT: main refuses, records the reason as
# an abort-before-stop, never stops the running v16 and never runs the wrapper.
refuses() {
  local want="$3" # check evals in its own frame; bash locals are visible to callees
  rm -f "$TMP/status.txt" "$TMP/wrapper-calls.txt" "$TMP/docker-actions.txt"
  echo glm53-flash-hyperflare-tp2-v16 > "$TMP/running.txt"
  write_gpu 30000 30000 # v16 is serving; a driver without preflight fails fast, not hangs
  GPU_WAIT_SECONDS=1 EXPORT_WRAPPER="${EXPORT_WRAPPER_UNDER_TEST:-$TMP/wrapper-ok}" main "$2" 2>/dev/null && result=0 || result=$?
  check "$1: refused" '[ "$result" = 1 ]'
  check "$1: reason recorded" 'grep -q "aborted before stopping anything: .*$want" "$TMP/status.txt"'
  check "$1: v16 left running" '[ ! -f "$TMP/docker-actions.txt" ]'
  check "$1: wrapper never ran" '[ ! -f "$TMP/wrapper-calls.txt" ]'
}

configure
refuses "unknown (retired) variant" cyber-hybrid-bf16 "unknown variant 'cyber-hybrid-bf16'"

configure
VARIANTS_LIB="$TMP/nowhere/hyperflare-variants.sh"
refuses "lone copy without the variant table" uncensored "variant table .* is missing"

configure
refuses "checkpoint not built" v16 "no checkpoint at $TMP/models/glm53-fp4-local"

configure
AVAIL_BYTES=$((142 * GiB))
refuses "package does not fit on disk" uncensored "disk: the package needs ~167 GiB + 10%, .* has 142 GiB free"

configure
EXPORT_WRAPPER_UNDER_TEST="$TMP/no-such-wrapper" refuses "wrapper missing" uncensored "export wrapper .* is missing"

# The table beside the wrapper is the one checked, not one beside the driver.
configure
unset VARIANTS_LIB
mkdir -p "$TMP/lone"
cp "$TMP/wrapper-ok" "$TMP/lone/export.sh"
EXPORT_WRAPPER_UNDER_TEST="$TMP/lone/export.sh" refuses "wrapper dir without its table" uncensored "variant table $TMP/lone/hyperflare-variants.sh is missing"

if [ "$failures" -ne 0 ]; then
  echo "stop-and-export unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "stop-and-export unit: PASS ($cases checks)"
