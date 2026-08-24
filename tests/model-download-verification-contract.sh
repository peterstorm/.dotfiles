#!/usr/bin/env bash
# Executable contracts for artifact verification and Muse download completion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KREA_DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-models.sh"
KLEIN_DOWNLOAD="$ROOT/scripts/comfyui/download-krea2-flux-klein-models.sh"
MUSE_DOWNLOAD="$ROOT/scripts/inference/muse/download-muse-glimmer-30b.sh"
H3_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-h3-models.sh"
MUSIC3_DOWNLOAD="$ROOT/scripts/comfyui/download-minimax-music3-models.sh"
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

# shellcheck disable=SC2034 # Read dynamically by auxiliary_verification_manifest.
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
install_file nested/model.bin
[ ! -e "$STAGING/nested/model.bin" ] \
  || fail "same-inode staging link remained after idempotent installation"
verify_manifest "$MODELS_ROOT" "$installed_sha $installed_size nested/model.bin" \
  || fail "idempotent same-inode installation damaged the verified destination"
printf 'corrupt\n' >"$MODELS_ROOT/corrupt.bin"
if stage_verified_existing "$installed_sha" "$installed_size" corrupt.bin 2>/dev/null; then
  fail "corrupt existing artifact was reused"
fi
STAGING="$sandbox/reboot-resume-staging"
mkdir -p "$STAGING/nested"
printf 'downloaded before reboot\n' >"$STAGING/nested/resume.bin"
resume_sha="$(sha256sum "$STAGING/nested/resume.bin" | cut -d' ' -f1)"
resume_size="$(stat -c %s "$STAGING/nested/resume.bin")"
stage_verified_existing "$resume_sha" "$resume_size" nested/resume.bin \
  || fail "verified staging-only artifact was not resumed"
[ ! -e "$MODELS_ROOT/nested/resume.bin" ] \
  || fail "staging-only resume unexpectedly required an installed artifact"

# Both FLUX/Klein legal gates must reject before any downloader boundary.
mkdir -p "$sandbox/bin"
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
printf 'hf-called\n' >>"$KLEIN_EVENTS"
exit 0
EOF
chmod +x "$sandbox/bin/hf"
: >"$sandbox/klein-events"
klein_status=0
KLEIN_EVENTS="$sandbox/klein-events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/klein" bash "$KLEIN_DOWNLOAD" \
  >/dev/null 2>&1 || klein_status=$?
[ "$klein_status" -eq 2 ] || fail "FLUX Klein missing-license gate returned $klein_status"
klein_status=0
KLEIN_EVENTS="$sandbox/klein-events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/klein" \
  FLUX2_KLEIN_ACCEPT_NONCOMMERCIAL_LICENSE=yes \
  bash "$KLEIN_DOWNLOAD" >/dev/null 2>&1 || klein_status=$?
[ "$klein_status" -eq 2 ] || fail "Civitai LoRA missing-license gate returned $klein_status"
[ ! -s "$sandbox/klein-events" ] || fail "FLUX Klein called hf before license acceptance"

# shellcheck source=scripts/comfyui/download-krea2-flux-klein-models.sh
source "$KLEIN_DOWNLOAD"
printf '%s\n' 'fixture-civitai-token-1234567890' >"$sandbox/civitai-token"
chmod 0600 "$sandbox/civitai-token"
[ "$(CIVITAI_TOKEN_FILE="$sandbox/civitai-token" resolve_civitai_token)" = \
  'fixture-civitai-token-1234567890' ] || fail "private Civitai token file was not resolved"
chmod 0644 "$sandbox/civitai-token"
if CIVITAI_TOKEN_FILE="$sandbox/civitai-token" resolve_civitai_token >/dev/null 2>&1; then
  fail "group/world-readable Civitai token file was accepted"
fi
cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$CURL_EVENTS"
stat -c %a "$2" >"$CURL_CONFIG_MODE"
cp "$2" "$CURL_CONFIG_COPY"
EOF
chmod +x "$sandbox/bin/curl"
STAGING="$sandbox/klein-curl"
mkdir -p "$STAGING"
CURL_EVENTS="$sandbox/curl-events" \
CURL_CONFIG_MODE="$sandbox/curl-config-mode" \
CURL_CONFIG_COPY="$sandbox/curl-config-copy" \
PATH="$sandbox/bin:$PATH" \
  download_civitai_file 'https://example.invalid/model?fileId=1' \
    "$STAGING/model.part" 'fixture-civitai-token-1234567890'
[ "$(cat "$sandbox/curl-events")" = "--config $(cut -d' ' -f2 "$sandbox/curl-events")" ] \
  || fail "Civitai curl invocation exposed extra process arguments"
! grep -Fq 'fixture-civitai-token-1234567890' "$sandbox/curl-events" \
  || fail "Civitai token leaked through curl arguments"
[ "$(cat "$sandbox/curl-config-mode")" = 600 ] \
  || fail "Civitai curl config was not private"
grep -Fq 'fixture-civitai-token-1234567890' "$sandbox/curl-config-copy" \
  || fail "Civitai curl config did not receive the token"

# Exercise the complete FLUX/Klein transaction with tiny file adapters.
MODELS_ROOT="$sandbox/klein-root"
PROFILE_REV="fixture-klein-profile"
STAGING="$MODELS_ROOT/.staging-$PROFILE_REV"
MARKER="$MODELS_ROOT/.$PROFILE_REV.complete"
LOCK="$MODELS_ROOT/.$PROFILE_REV.lock"
mkdir -p "$MODELS_ROOT/dependencies"
printf 'Krea dependency\n' >"$MODELS_ROOT/dependencies/krea.bin"
krea_sha="$(sha256sum "$MODELS_ROOT/dependencies/krea.bin" | cut -d' ' -f1)"
krea_size="$(stat -c %s "$MODELS_ROOT/dependencies/krea.bin")"
KREA_DEPENDENCY_MANIFEST="$krea_sha $krea_size dependencies/krea.bin"
hf_payload='HF fixture artifact'
civitai_payload='Civitai fixture artifact'
hf_sha="$(printf '%s\n' "$hf_payload" | sha256sum | cut -d' ' -f1)"
hf_size="$(printf '%s\n' "$hf_payload" | wc -c)"
civitai_sha="$(printf '%s\n' "$civitai_payload" | sha256sum | cut -d' ' -f1)"
civitai_size="$(printf '%s\n' "$civitai_payload" | wc -c)"
HF_MANIFEST="$hf_sha $hf_size fixture/repo fixture-revision source.bin diffusion_models/hf.bin"
CIVITAI_MANIFEST="$civitai_sha $civitai_size https://example.invalid/model?fileId=1 loras/civitai.bin"
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KLEIN_EVENTS"
mkdir -p "$7/$(dirname "$3")"
printf '%s\n' "$HF_PAYLOAD" >"$7/$3"
EOF
cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$KLEIN_EVENTS"
config="$2"
output="$(awk -F'"' '$1 ~ /^output = / { print $2 }' "$config")"
mkdir -p "$(dirname "$output")"
printf '%s\n' "$CIVITAI_PAYLOAD" >"$output"
EOF
chmod +x "$sandbox/bin/hf" "$sandbox/bin/curl" "$sandbox/civitai-token"
chmod 0600 "$sandbox/civitai-token"
: >"$sandbox/klein-events"
KLEIN_EVENTS="$sandbox/klein-events" \
HF_PAYLOAD="$hf_payload" CIVITAI_PAYLOAD="$civitai_payload" \
CIVITAI_TOKEN_FILE="$sandbox/civitai-token" PATH="$sandbox/bin:$PATH" \
FLUX2_KLEIN_ACCEPT_NONCOMMERCIAL_LICENSE=yes \
KREA2_FLUX_LORA_ACCEPT_LICENSES=yes main >/dev/null
verify_manifest "$MODELS_ROOT" "$(verification_manifest)" \
  || fail "completed FLUX/Klein fixture profile did not verify"
grep -Fxq "$PROFILE_REV" "$MARKER" \
  || fail "FLUX/Klein completion marker was not published"
[ "$(stat -c %a "$MODELS_ROOT/diffusion_models/hf.bin")" = 640 ] \
  || fail "FLUX/Klein Hugging Face artifact mode is not 0640"
[ "$(stat -c %a "$MODELS_ROOT/loras/civitai.bin")" = 640 ] \
  || fail "FLUX/Klein Civitai artifact mode is not 0640"
! grep -Fq 'fixture-civitai-token-1234567890' "$sandbox/klein-events" \
  || fail "FLUX/Klein transaction leaked the Civitai token through argv"

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

# Music 3's community-license gate must also reject before the hf boundary.
cat >"$sandbox/bin/hf" <<'EOF'
#!/usr/bin/env bash
printf 'hf-called\n' >>"$MUSIC3_EVENTS"
exit 0
EOF
chmod +x "$sandbox/bin/hf"
: >"$sandbox/music3-events"
music3_status=0
MUSIC3_EVENTS="$sandbox/music3-events" PATH="$sandbox/bin:$PATH" \
  COMFYUI_MODELS_ROOT="$sandbox/music3" bash "$MUSIC3_DOWNLOAD" \
  >/dev/null 2>&1 || music3_status=$?
[ "$music3_status" -eq 2 ] || fail "Music 3 missing-license gate returned $music3_status"
[ ! -s "$sandbox/music3-events" ] || fail "Music 3 called hf before license acceptance"

printf 'PASS: model downloads verify corruption, legal gates, and completion state\n'
