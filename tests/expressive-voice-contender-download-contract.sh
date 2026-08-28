#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DOWNLOADER="$ROOT/scripts/inference/voice/download-expressive-voice-contenders.sh"
LAUNCHER="$ROOT/scripts/inference/voice/start-expressive-voice-contender-downloads.sh"
STATIC_MANIFEST="$ROOT/scripts/inference/voice/expressive-voice-contenders.manifest.tsv"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ -x "$DOWNLOADER" ]] || fail 'downloader is not executable'
[[ -x "$LAUNCHER" ]] || fail 'launcher is not executable'
[[ -s "$STATIC_MANIFEST" ]] || fail 'static closure manifest is absent'

[[ "$(awk -F '\t' '$1 == "profile" { count++ } END { print count + 0 }' "$STATIC_MANIFEST")" == 9 ]] \
  || fail 'static manifest must contain nine complete model/dependency profiles'
[[ "$(awk -F '\t' '$1 == "artifact" { count++ } END { print count + 0 }' "$STATIC_MANIFEST")" == 139 ]] \
  || fail 'static manifest artifact count changed'
[[ "$(awk -F '\t' '$1 == "profile" { total += $6 } END { printf "%.0f", total }' "$STATIC_MANIFEST")" == 76149259617 ]] \
  || fail 'static manifest byte closure changed'

for expected in \
  $'voxcpm2-32279eff\topenbmb/VoxCPM2\t32279effe8c19989596f05d353d1447f51d9e915' \
  $'breeze-tts2-c1c8ca18\tBreezeBlue/Breeze-TTS-2\tc1c8ca18b70b30822735633991d9ebf4898e47d4' \
  $'dramabox-404f967f\tResembleAI/Dramabox\t404f967f653fa1170dc15a9d1ddd3fdb9a0a842d' \
  $'higgs-tts3-7556c17e\tbosonai/higgs-tts-3-4b\t7556c17e05201fccd9c8cc120bc216dcc7b5d561' \
  $'cosyvoice3-29e01c4e\tFunAudioLLM/Fun-CosyVoice3-0.5B-2512\t29e01c4e8d000f4bcd70751be16fa94bf3d85a18' \
  $'fish-s2-pro-1de9996b\tfishaudio/s2-pro\t1de9996b6be38b745688de084d87a5633f714e4e' \
  $'moss-tts-voice-acting-aabb7b60\tlaion/moss-tts-v1.5-8b-voice-acting\taabb7b609c2b56e5cfa8e8641eb1d8ce9e3d1997'; do
  awk -F '\t' '$1 == "profile" { print $2 "\t" $3 "\t" $4 }' "$STATIC_MANIFEST" | grep -Fxq "$expected" \
    || fail "missing pinned profile: $expected"
done

grep -Fq $'artifact\tvoxcpm2-32279eff\tf7f964cfa9da23653baec6e6f7750719977ad944ed9f95fe52fe3a620506891d\t4580080592\tmodel.safetensors' "$STATIC_MANIFEST" \
  || fail 'VoxCPM2 primary weight checksum changed'
grep -Fq $'artifact\tbreeze-tts2-c1c8ca18\tabf813781256e10cbe81f2dbb415f897556225d4dfa0282d67aa8ea164e114a9\t4961989890\tmodel-00001-of-00002.safetensors' "$STATIC_MANIFEST" \
  || fail 'Breeze primary weight checksum changed'
grep -Fq $'artifact\tdramabox-gemma-826e729d\t5578abd3c27241a31f21c13220f44a427b99f1c36564ac587670f3be990d4ffc\t4992269027\tmodel-00001-of-00002.safetensors' "$STATIC_MANIFEST" \
  || fail 'DramaBox Gemma dependency checksum changed'

rg -q 'EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes' "$LAUNCHER"
rg -q 'EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28' "$LAUNCHER"
rg -q 'tmux new-session -d' "$LAUNCHER"
rg -q 'tmux new-window -d' "$LAUNCHER"
rg -q 'remain-on-exit on' "$LAUNCHER"
[[ "$(awk '/^PROFILES=\(/ { inside=1; next } inside && /^\)/ { inside=0 } inside && /^  [a-z0-9-]+$/ { count++ } END { print count + 0 }' "$LAUNCHER")" == 9 ]] \
  || fail 'launcher must contain one detached lane per closure profile'
rg -q '>>%q 2>&1' "$LAUNCHER"
rg -q 'exec \{lock_fd\}>' "$DOWNLOADER"
rg -q -- '--continue-at - --output "\$partial"' "$DOWNLOADER"
rg -q 'resolve/\$revision/\$relative' "$DOWNLOADER"
! rg -q 'hf download' "$DOWNLOADER" || fail 'non-resumable randomized Xet adapter remains'
! rg -q '\.expressive-voice-contenders\.lock' "$DOWNLOADER" \
  || fail 'global lock still serializes independent model profiles'

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin"
printf 'first immutable artifact\n' >"$sandbox/first.bin"
printf 'second immutable artifact\n' >"$sandbox/second.bin"
first_sha="$(sha256sum "$sandbox/first.bin" | cut -d' ' -f1)"
first_size="$(stat -c %s "$sandbox/first.bin")"
second_sha="$(sha256sum "$sandbox/second.bin" | cut -d' ' -f1)"
second_size="$(stat -c %s "$sandbox/second.bin")"
{
  printf '# schema=expressive-voice-contender-closures-v1\n'
  printf 'profile\tfixture-restricted\tfixture/repository\t1111111111111111111111111111111111111111\tresearch-noncommercial-development-only\t%s\n' "$((first_size + second_size))"
  printf 'artifact\tfixture-restricted\t%s\t%s\tmodel.bin\n' "$first_sha" "$first_size"
  printf 'artifact\tfixture-restricted\t%s\t%s\tnested/tokenizer.json\n' "$second_sha" "$second_size"
} >"$sandbox/fixture.tsv"
cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'curl %s\n' "$*" >>"$CURL_EVENTS"
while (( $# > 0 )); do
  case "$1" in
    --output) target="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
[[ -n "${target:-}" && -n "${url:-}" ]]
case "$url" in
  */model.bin) cp "$CURL_FIRST" "$target" ;;
  */nested/tokenizer.json) cp "$CURL_SECOND" "$target" ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$sandbox/bin/curl"
: >"$sandbox/curl-events"

run_downloader() {
  EXPRESSIVE_VOICE_MANIFEST="$sandbox/fixture.tsv" \
  VOICE_MODELS_ROOT="$sandbox/models" \
  EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28 \
  EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES="${1:-}" \
  CURL_EVENTS="$sandbox/curl-events" \
  CURL_FIRST="$sandbox/first.bin" \
  CURL_SECOND="$sandbox/second.bin" \
  PATH="$sandbox/bin:$PATH" \
    "$DOWNLOADER" fixture-restricted
}

license_status=0
run_downloader >/dev/null 2>&1 || license_status=$?
[[ "$license_status" != 0 ]] || fail 'restricted model downloaded without explicit acceptance'
[[ ! -s "$sandbox/curl-events" ]] || fail 'network boundary was crossed before license acceptance'

run_downloader yes >/dev/null
ready="$sandbox/models/expressive-contenders/fixture-restricted"
[[ -f "$ready/download-receipt.json" ]] || fail 'download receipt was not published'
[[ -f "$ready/ARTIFACTS.sha256" ]] || fail 'artifact ledger was not published'
[[ ! -e "$ready/.cache" ]] || fail 'resumable cache leaked into immutable closure'
[[ -f "$sandbox/models/expressive-contenders/.fixture-restricted.complete" ]] || fail 'completion marker was not published'
jq -e '.gpuRuntimeStarted == false and .productionAuthority == false' "$ready/download-receipt.json" >/dev/null \
  || fail 'receipt crossed the GPU or Production boundary'
[[ "$(wc -l <"$sandbox/curl-events")" == 2 ]] || fail 'fixture did not download each artifact exactly once'

run_downloader yes >/dev/null
[[ "$(wc -l <"$sandbox/curl-events")" == 2 ]] || fail 'verified rerun was not idempotent'

printf 'corrupt\n' >"$ready/model.bin"
corruption_status=0
run_downloader yes >/dev/null 2>&1 || corruption_status=$?
[[ "$corruption_status" != 0 ]] || fail 'corrupt immutable destination was accepted or overwritten'
[[ "$(wc -l <"$sandbox/curl-events")" == 2 ]] || fail 'corruption triggered an implicit overwrite download'

printf 'EXPRESSIVE_VOICE_CONTENDER_DOWNLOAD_CONTRACT_PASS\n'
