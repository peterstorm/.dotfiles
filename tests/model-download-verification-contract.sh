#!/usr/bin/env bash
# Executable contracts for artifact verification and Muse download completion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KREA_DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-models.sh"
MUSE_DOWNLOAD="$ROOT/scripts/inference/muse/download-muse-glimmer-30b.sh"
H3_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-models.sh"
PROFILE_CATALOG="$ROOT/scripts/inference/shared/inference-profile-catalog.sh"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
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
installed_sha="$(sha256sum "$MODELS_ROOT/nested/model.bin" | cut -d' ' -f1)"
installed_size="$(stat -c %s "$MODELS_ROOT/nested/model.bin")"
STAGING="$sandbox/restaging"
stage_verified_existing "$installed_sha" "$installed_size" nested/model.bin \
  || fail "verified existing artifact was not reused"
[ "$(stat -c %i "$MODELS_ROOT/nested/model.bin")" = "$(stat -c %i "$STAGING/nested/model.bin")" ] \
  || fail "verified existing artifact was not staged as a same-filesystem hard link"
printf 'corrupt\n' >"$MODELS_ROOT/corrupt.bin"
if stage_verified_existing "$installed_sha" "$installed_size" corrupt.bin 2>/dev/null; then
  fail "corrupt existing artifact was reused"
fi

# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$PROFILE_CATALOG"
shared_root="$sandbox/shared-checkpoint"
mkdir -p "$shared_root"
printf 'shared artifact\n' >"$shared_root/model.bin"
shared_sha="$(sha256sum "$shared_root/model.bin" | cut -d' ' -f1)"
shared_size="$(stat -c %s "$shared_root/model.bin")"
shared_manifest="$shared_sha $shared_size model.bin"
inference_verify_checkpoint_manifest "$shared_root" "$shared_manifest" \
  || fail "shared checkpoint verifier rejected a valid artifact"
printf 'corrupt\n' >"$shared_root/model.bin"
if inference_verify_checkpoint_manifest "$shared_root" "$shared_manifest" 2>/dev/null; then
  fail "shared checkpoint verifier accepted corruption"
fi

# Source the Muse downloader and exercise its checkpoint boundary with a fake hf
# adapter and a tiny immutable manifest.
# shellcheck source=scripts/inference/muse/download-muse-glimmer-30b.sh
source "$MUSE_DOWNLOAD"
mkdir -p "$sandbox/bin" "$sandbox/muse-target"
printf 'muse artifact\n' >"$sandbox/muse-target/model.bin"
muse_sha="$(sha256sum "$sandbox/muse-target/model.bin" | cut -d' ' -f1)"
muse_size="$(stat -c %s "$sandbox/muse-target/model.bin")"
muse_manifest="$muse_sha $muse_size model.bin"
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
exit "${HF_FAKE_STATUS:-0}"
EOF
chmod +x "$sandbox/bin/hf"
PATH="$sandbox/bin:$PATH" download_checkpoint \
  fixture/repo fixture-revision "$sandbox/muse-target" "$muse_manifest"
grep -Fxq 'fixture/repo@fixture-revision' "$sandbox/muse-target/.download-complete" \
  || fail "Muse checkpoint completion marker was not written after verification"
rm -f "$sandbox/muse-target/.download-complete"
export HF_FAKE_STATUS=7
if PATH="$sandbox/bin:$PATH" \
  download_checkpoint fixture/repo fixture-revision "$sandbox/muse-target" "$muse_manifest" \
  >/dev/null 2>&1; then
  fail "Muse checkpoint download failure was not propagated"
fi
unset HF_FAKE_STATUS
test ! -e "$sandbox/muse-target/.download-complete" \
  || fail "Muse marker was written after download failure"

cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$DOCKER_EVENTS"
if [ "$1" = update ]; then exit "${DOCKER_UPDATE_STATUS:-0}"; fi
if [ "$1" = stop ]; then exit "${DOCKER_STOP_STATUS:-0}"; fi
exit 0
EOF
chmod +x "$sandbox/bin/docker"
: >"$sandbox/docker-events"
DOCKER_EVENTS="$sandbox/docker-events"
export DOCKER_EVENTS
PATH="$sandbox/bin:$PATH" inference_quiesce_failed_container muse-fixture
export DOCKER_UPDATE_STATUS=1
cleanup_status=0
PATH="$sandbox/bin:$PATH" \
  inference_quiesce_failed_container muse-fixture >/dev/null 2>&1 || cleanup_status=$?
unset DOCKER_UPDATE_STATUS
[ "$cleanup_status" -eq 70 ] \
  || fail "incomplete failed-start cleanup must return status 70"
grep -Fq 'docker stop -t 30 muse-fixture' "$sandbox/docker-events" \
  || fail "failed-start cleanup did not attempt container stop after update failure"

# Both MiniMax legal gates must reject before the hf boundary is reached.
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
printf 'hf-called\n' >>"$H3_EVENTS"
exit 0
EOF
chmod +x "$sandbox/bin/hf"
: >"$sandbox/h3-events"
h3_status=0
H3_EVENTS="$sandbox/h3-events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/h3" bash "$H3_DOWNLOAD" \
  >/dev/null 2>&1 || h3_status=$?
[ "$h3_status" -eq 2 ] || fail "MiniMax missing-license gate returned $h3_status"
[ ! -s "$sandbox/h3-events" ] || fail "MiniMax called hf before license acceptance"

h3_status=0
H3_EVENTS="$sandbox/h3-events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/h3" MINIMAX_H3_ACCEPT_LICENSE=yes \
  bash "$H3_DOWNLOAD" >/dev/null 2>&1 || h3_status=$?
[ "$h3_status" -eq 2 ] || fail "MiniMax missing-authorization gate returned $h3_status"
[ ! -s "$sandbox/h3-events" ] || fail "MiniMax called hf before authorization attestation"

printf 'PASS: model downloads verify corruption, legal gates, and completion state\n'
