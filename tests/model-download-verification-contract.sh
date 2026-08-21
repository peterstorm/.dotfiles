#!/usr/bin/env bash
# Executable contracts for artifact verification and Muse download completion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KREA_DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-models.sh"
MUSE_DOWNLOAD="$ROOT/scripts/inference/muse/download-muse-glimmer-30b.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox" /tmp/muse-glimmer-abliterated-dl.sh /tmp/muse-glimmer-abliterated.sha256' EXIT
mkdir -p "$sandbox/root"
printf 'verified artifact\n' >"$sandbox/root/artifact.bin"
expected_sha="$(sha256sum "$sandbox/root/artifact.bin" | cut -d' ' -f1)"
expected_size="$(stat -c %s "$sandbox/root/artifact.bin")"

# shellcheck source=scripts/comfyui/download-krea2-models.sh
source "$KREA_DOWNLOAD"
fixture_manifest="$expected_sha $expected_size artifact.bin"
verify_manifest "$sandbox/root" "$fixture_manifest" \
  || fail "valid artifact did not verify"
if verify_manifest "$sandbox/root" "$expected_sha $((expected_size + 1)) artifact.bin" 2>/dev/null; then
  fail "size corruption passed verification"
fi
if verify_manifest "$sandbox/root" "$(printf '0%.0s' {1..64}) $expected_size artifact.bin" 2>/dev/null; then
  fail "checksum corruption passed verification"
fi
if verify_manifest "$sandbox/root" "$fixture_manifest"$'\n'"$expected_sha $expected_size missing.bin" 2>/dev/null; then
  fail "missing artifact passed verification"
fi

AUXILIARY_MANIFEST="$expected_sha $expected_size repo revision source.bin artifact.bin"
[ "$(auxiliary_verification_manifest)" = "$fixture_manifest" ] \
  || fail "auxiliary manifest did not normalize to the shared verification shape"

MODELS_ROOT="$sandbox/install-root"
STAGING="$sandbox/staging"
mkdir -p "$STAGING/nested"
printf 'install me\n' >"$STAGING/nested/model.bin"
install_file nested/model.bin
[ "$(stat -c %a "$MODELS_ROOT/nested/model.bin")" = 640 ] \
  || fail "installed artifact mode is not 0640"

mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/muse-models"
cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
printf 'docker %s %s\n' "$command" "$*" >>"$DOCKER_EVENTS"
case "$command" in
  rm|run) echo container-id; exit 0 ;;
  wait) echo "${DOCKER_WAIT_STATUS:-0}"; exit 0 ;;
  logs) echo 'container log evidence'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
cat >"$sandbox/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x "$sandbox/bin"/*

run_muse_download() {
  local detach="$1" wait_status="$2" output="$3" status=0
  : >"$sandbox/docker-events"
  HOME="$sandbox/home" PATH="$sandbox/bin:$PATH" \
    DOCKER_EVENTS="$sandbox/docker-events" DOCKER_WAIT_STATUS="$wait_status" \
    MUSE_MODELS_ROOT="$sandbox/muse-models" MUSE_VARIANT=abliterated \
    MUSE_DOWNLOAD_DETACH="$detach" bash "$MUSE_DOWNLOAD" \
    >"$output" 2>&1 || status=$?
  printf '%s' "$status"
}

status="$(run_muse_download no 7 "$sandbox/wait-failure.log")"
[ "$status" -eq 1 ] || fail "Muse downloader did not propagate container failure"
grep -Fq 'docker wait muse-glimmer-abliterated-model-dl' "$sandbox/docker-events" \
  || fail "blocking Muse downloader did not wait for its container"
grep -Fq 'container log evidence' "$sandbox/wait-failure.log" \
  || fail "Muse downloader failure omitted container logs"
grep -Fq 'sha256sum --check --strict /target.sha256' /tmp/muse-glimmer-abliterated-dl.sh \
  || fail "Muse verifier does not consume the mounted manifest as data"
if grep -Fq 'cd53270fef03dac41' /tmp/muse-glimmer-abliterated-dl.sh; then
  fail "Muse generated script interpolated checksum data into shell source"
fi
grep -Fq 'cd53270fef03dac41' /tmp/muse-glimmer-abliterated.sha256 \
  || fail "Muse checksum manifest was not materialized separately"
grep -Fq -- '-v /tmp/muse-glimmer-abliterated.sha256:/target.sha256:ro' "$sandbox/docker-events" \
  || fail "Muse checksum manifest was not mounted read-only"

status="$(run_muse_download no 0 "$sandbox/wait-success.log")"
[ "$status" -eq 0 ] || fail "successful blocking Muse download returned $status"
grep -Fq 'DOWNLOAD_COMPLETE:' "$sandbox/wait-success.log" \
  || fail "blocking Muse success omitted completion evidence"

status="$(run_muse_download yes 7 "$sandbox/detached.log")"
[ "$status" -eq 0 ] || fail "explicit detached Muse start returned $status"
if grep -Fq 'docker wait' "$sandbox/docker-events"; then
  fail "explicit detached Muse start unexpectedly waited"
fi
grep -Fq 'DOWNLOAD_STARTED:' "$sandbox/detached.log" \
  || fail "detached Muse mode did not distinguish start from completion"

printf 'PASS: model downloads verify corruption and propagate completion state\n'
