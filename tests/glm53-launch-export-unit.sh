#!/usr/bin/env bash
# Unit test for scripts/inference/glm53/launch-glm53-export.sh. The launcher runs
# from a throwaway git repository holding a copy of the glm53 directory; ssh is a
# stub that runs the remote command locally with stub setsid/pgrep first on PATH,
# so nothing reaches desktop and no driver really starts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM53="scripts/inference/glm53"

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

# --- a repository with the three files the launch path needs -------------------------

REPO="$TMP/repo"
mkdir -p "$REPO/$GLM53"
cp "$ROOT/$GLM53/launch-glm53-export.sh" "$ROOT/$GLM53/hyperflare-variants.sh" \
   "$ROOT/$GLM53/stop-and-export-glm53-hyperflare.sh" "$REPO/$GLM53/"
git -C "$REPO" init -q
git -C "$REPO" -c user.name=t -c user.email=t@t add -A
git -C "$REPO" -c user.name=t -c user.email=t@t commit -qm snapshot
SHA="$(git -C "$REPO" rev-parse --short=12 HEAD)"
LAUNCH="$REPO/$GLM53/launch-glm53-export.sh"

# --- stubs ---------------------------------------------------------------------------

REMOTE="$TMP/remote"   # desktop's REMOTE_BASE
STUBS="$TMP/stubs"
mkdir -p "$REMOTE" "$STUBS"

# ssh: log the call, run the last argument (the remote command) locally.
cat > "$TMP/ssh" <<EOF
#!/usr/bin/env bash
echo call >> "$TMP/ssh-calls.txt"
PATH="$STUBS:\$PATH" exec bash -c "\${!#}"
EOF
chmod +x "$TMP/ssh"

# pgrep: exits with the code in pgrep-rc.txt (0 = a driver is running).
cat > "$STUBS/pgrep" <<EOF
#!/usr/bin/env bash
rc="\$(cat "$TMP/pgrep-rc.txt")"
[ "\$rc" = 0 ] && echo "4242 bash /tmp/glm53-export-x/stop-and-export-glm53-hyperflare.sh v16"
exit "\$rc"
EOF
# setsid: records what it would start and writes the driver's verdict, if any.
cat > "$STUBS/setsid" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$TMP/started.txt"
[ -s "$TMP/verdict.txt" ] && cat "$TMP/verdict.txt" > "\$STATUS_FILE"
exit 0
EOF
chmod +x "$STUBS/pgrep" "$STUBS/setsid"

# launch VARIANT: run the launcher against the stubs; sets $result and $out.
launch() {
  rm -f "$TMP/ssh-calls.txt" "$TMP/started.txt"
  out="$(SSH="$TMP/ssh" REMOTE_BASE="$REMOTE" PREFLIGHT_WAIT_SECONDS=3 bash "$LAUNCH" "$@" 2>&1)" \
    && result=0 || result=$?
}
fresh() {
  echo 1 > "$TMP/pgrep-rc.txt"
  echo "2026-11-15T10:00:00Z preflight ok: /models/glm53-hyperflare/glm53-cyber-hybrid-bf16 (167 GiB), 300 GiB free" > "$TMP/verdict.txt"
}
SNAP="$REMOTE/glm53-export-$SHA"

# --- refusals before desktop is touched ----------------------------------------------

fresh
launch
check "no variant: usage, status 2" '[ "$result" = 2 ] && grep -q "usage:" <<<"$out"'

fresh
launch cyber-hybrid-fp8
check "unknown variant: status 2, names the known ones" \
  '[ "$result" = 2 ] && grep -q "known: v16 cyber-hybrid cyber-hybrid-bf16" <<<"$out"'
check "unknown variant: desktop never contacted" '[ ! -f "$TMP/ssh-calls.txt" ]'

fresh
echo "# local edit" >> "$REPO/$GLM53/hyperflare-variants.sh"
launch cyber-hybrid-bf16
check "uncommitted changes: refused" '[ "$result" = 1 ] && grep -q "uncommitted changes" <<<"$out"'
check "uncommitted changes: desktop never contacted" '[ ! -f "$TMP/ssh-calls.txt" ]'
git -C "$REPO" checkout -q -- "$GLM53/hyperflare-variants.sh"

# --- refusals on desktop -------------------------------------------------------------

fresh
echo 0 > "$TMP/pgrep-rc.txt"
launch cyber-hybrid-bf16
check "a running driver: refused, shown" '[ "$result" = 1 ] && grep -q "already running" <<<"$out" && grep -q 4242 <<<"$out"'
check "a running driver: nothing shipped or started" '[ ! -d "$SNAP" ] && [ ! -f "$TMP/started.txt" ]'

fresh
echo 255 > "$TMP/pgrep-rc.txt"
launch cyber-hybrid-bf16
check "no answer from desktop: refused, not assumed idle" \
  '[ "$result" = 1 ] && grep -q "could not ask" <<<"$out" && [ ! -f "$TMP/started.txt" ]'

# --- the launch ----------------------------------------------------------------------

fresh
launch cyber-hybrid-bf16
check "launch succeeds on a preflight ok" '[ "$result" = 0 ] && grep -q "preflight ok" <<<"$out"'
check "the snapshot is HEAD's glm53 directory, whole (variant table beside the driver)" \
  'diff -r "$SNAP/$GLM53" "$REPO/$GLM53" >/dev/null && [ -r "$SNAP/$GLM53/hyperflare-variants.sh" ]'
check "the driver starts from the snapshot with the variant" \
  '[ "$(cat "$TMP/started.txt")" = "nohup bash $SNAP/$GLM53/stop-and-export-glm53-hyperflare.sh cyber-hybrid-bf16" ]'
check "no half-extracted snapshot is left" '[ -z "$(find "$REMOTE" -maxdepth 1 -name "glm53-export-$SHA.*")" ]'

touch "$SNAP/marker"
fresh
launch cyber-hybrid-bf16
check "a relaunch at the same commit reuses the snapshot" '[ "$result" = 0 ] && [ -f "$SNAP/marker" ]'

fresh
echo "2026-11-15T10:00:00Z aborted before stopping anything: disk: the package needs ~167 GiB + 10%, /models/glm53-hyperflare has 142 GiB free" > "$TMP/verdict.txt"
launch cyber-hybrid-bf16
check "a refused preflight fails the launch with its reason" \
  '[ "$result" = 1 ] && grep -q "has 142 GiB free" <<<"$out" && grep -q "refused before stopping anything" <<<"$out"'

# The driver never writes a verdict, and a previous run's "preflight ok" is still
# on disk: the launcher must not report that as this run's success.
fresh
: > "$TMP/verdict.txt"
echo "2026-11-14T09:00:00Z preflight ok: stale, from the last run" > "$REMOTE/glm-export-cyber-hybrid-bf16.status"
launch cyber-hybrid-bf16
check "no verdict in time fails the launch, pointing at the driver log" \
  '[ "$result" = 1 ] && grep -q "no preflight verdict" <<<"$out" && grep -q "glm-export-cyber-hybrid-bf16.driver.log" <<<"$out"'
check "a previous run's status is never read as this run's verdict" '! grep -q stale <<<"$out"'

if [ "$failures" -ne 0 ]; then
  echo "launch-export unit: $failures of $cases checks FAILED" >&2
  exit 1
fi
echo "launch-export unit: PASS ($cases checks)"
