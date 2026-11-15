#!/usr/bin/env bash
# Unit test for report_boot_receipt in switch-glm53-hyperflare-tp2-v16.sh: the
# switcher calls it with errexit suppressed, so every failing step must return
# non-zero with a named error, print no "BOOT RECEIPT:" line, leave no temporary
# file and keep any previous receipt; the success path writes the receipt. Also
# the generation acceptance (generation_verdict, require_generation): a model that
# answers health and /v1/models but cannot decode a token, or decodes tokens that
# are not the asked-for word, must fail acceptance.
# docker, mktemp, chmod, mv and curl are stubbed; no container or GPU is touched.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWITCH="$ROOT/scripts/inference/glm53/switch-glm53-hyperflare-tp2-v16.sh"

# Sourcing must never run main, whatever $0 is (see tests/switch-primary-unit.sh):
# a stub docker first on PATH records any call the start/stop dispatch would make.
guard_bin="$(mktemp -d)"
printf '#!/usr/bin/env bash\necho "docker $*" >>"%s/calls"\n' "$guard_bin" >"$guard_bin/docker"
chmod +x "$guard_bin/docker"
PATH="$guard_bin:$PATH" bash -c 'source "$0" stop' "$SWITCH" >/dev/null 2>&1 || true
if [ -e "$guard_bin/calls" ]; then
  echo "FAIL: sourcing $SWITCH ran its dispatch: $(cat "$guard_bin/calls")" >&2
  exit 1
fi
rm -rf "$guard_bin"

# shellcheck source=scripts/inference/glm53/switch-glm53-hyperflare-tp2-v16.sh
source "$SWITCH"

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT
BOOT_RECEIPT="$sandbox/state/receipt.txt"
failures=0
cases=0

fail_step=""
docker() {
  case "$1 ${4:-}" in
    "logs "*) [ "$fail_step" != logs ] || return 1
      printf '%s\n' 'Plan cache. per GPU: 86.56 GiB loaded' 'Allocate cache. 15.4 GiB · 2231808 KV tokens' ;;
    "inspect {{.Image}}") [ "$fail_step" != image ] || return 1; echo sha256:feed ;;
    "inspect {{.State.StartedAt}}") [ "$fail_step" != started ] || return 1; echo 2026-11-14T20:00:00Z ;;
    "inspect "*) [ "$fail_step" != package ] || return 1; echo glm53-fp4-local@gb202-tp2-202611141415 ;;
    *) echo "unexpected docker $*" >&2; return 9 ;;
  esac
}
mktemp() { [ "$fail_step" != mktemp ] || return 1; command mktemp "$@"; }
chmod() { [ "$fail_step" != chmod ] || return 1; command chmod "$@"; }
mv() { [ "$fail_step" != mv ] || return 1; command mv "$@"; }

# expect_failure STEP MESSAGE: a failing STEP returns 1 with MESSAGE, no
# success line, no temporary file, and the previous receipt untouched.
expect_failure() {
  local step="$1" message="$2" status=0 out
  cases=$((cases + 1))
  mkdir -p "$(dirname "$BOOT_RECEIPT")"
  printf 'previous\n' >"$BOOT_RECEIPT"
  fail_step="$step"
  out="$( (report_boot_receipt) 2>&1)" || status=$?
  fail_step=""
  if [ "$status" -ne 1 ] || [[ "$out" != *"error: boot receipt: $message"* ]] || [[ "$out" == *"BOOT RECEIPT:"* ]] \
    || compgen -G "$(dirname "$BOOT_RECEIPT")/.v16-boot-receipt.*" >/dev/null \
    || [ "$(cat "$BOOT_RECEIPT")" != previous ]; then
    failures=$((failures + 1))
    echo "FAIL $step: status=$status out=$out" >&2
  fi
}

expect_failure logs "docker logs $TARGET failed"
expect_failure image "docker inspect (image) failed"
expect_failure started "docker inspect (start time) failed"
expect_failure package "docker inspect (package label) failed"
expect_failure mktemp "cannot create a temporary file in"
expect_failure chmod "cannot chmod"
expect_failure mv "cannot move the receipt to $BOOT_RECEIPT"

# Success: the receipt names the container, model, package and capacity lines.
cases=$((cases + 1))
rm -rf "$sandbox/state"
status=0
out="$( (report_boot_receipt) 2>&1)" || status=$?
expected_line="BOOT RECEIPT: $BOOT_RECEIPT (model=$EXPECTED_MODEL, package=glm53-fp4-local@gb202-tp2-202611141415)"
if [ "$status" -ne 0 ] || [ "$out" != "$expected_line" ] \
  || ! grep -Fxq "container=$TARGET" "$BOOT_RECEIPT" \
  || ! grep -Fxq 'image=sha256:feed' "$BOOT_RECEIPT" \
  || ! grep -Fq 'Allocate cache. 15.4 GiB' "$BOOT_RECEIPT" \
  || [ "$(stat -c %a "$BOOT_RECEIPT")" != 600 ] \
  || compgen -G "$sandbox/state/.v16-boot-receipt.*" >/dev/null; then
  failures=$((failures + 1))
  echo "FAIL success: status=$status out=$out" >&2
fi

# --- generation acceptance ---------------------------------------------------
# generation_verdict is pure; require_generation runs it on a stubbed curl. The
# 500 body is the one the first cyber-hybrid-bf16 package answered every request with;
# the token salad is what the second one decoded.
expect_verdict() {
  local label="$1" code="$2" body="$3" expected="$4" got
  cases=$((cases + 1))
  got="$(generation_verdict "$code" "$body")"
  if [ "$got" != "$expected" ]; then
    failures=$((failures + 1))
    echo "FAIL verdict $label: got '$got', expected '$expected'" >&2
  fi
}
device_error='{"error":{"type":"server_error","message":"prepared model reported device error 1","param":null,"code":"server_error"}}'
expect_verdict "content" 200 '{"choices":[{"message":{"content":"ready"}}],"usage":{"completion_tokens":5}}' "ok:5"
expect_verdict "v16's real answer" 200 \
  '{"choices":[{"message":{"content":"ready","reasoning_content":"The user wants a single word."}}],"usage":{"completion_tokens":10}}' "ok:10"
expect_verdict "capitalised, punctuated" 200 '{"choices":[{"message":{"content":"Ready."}}],"usage":{"completion_tokens":3}}' "ok:3"
expect_verdict "reasoning only (GLM thinks first)" 200 \
  '{"choices":[{"message":{"content":null,"reasoning_content":"The user wants me to reply with ready"}}],"usage":{"completion_tokens":64}}' "ok:64"
# The round-1 cyber-hybrid-bf16 package's actual output: tokens decoded, no sense.
expect_verdict "token salad" 200 \
  '{"choices":[{"message":{"content":null,"reasoning_content":"Simple informed  towing advisors competence气球分发rå exemption"}}],"usage":{"completion_tokens":64}}' \
  "error:the reply is not the asked-for word (incoherent decode?): Simple informed towing advisors competence气球分发rå exemption"
expect_verdict "cut off before the word" 200 \
  '{"choices":[{"message":{"content":null,"reasoning_content":"The user"}}],"usage":{"completion_tokens":64}}' \
  "error:the reply is not the asked-for word (incoherent decode?): The user"
expect_verdict "a word that only contains it" 200 '{"choices":[{"message":{"content":"already"}}],"usage":{"completion_tokens":2}}' \
  "error:the reply is not the asked-for word (incoherent decode?): already"
expect_verdict "device error" 500 "$device_error" "error:HTTP 500: prepared model reported device error 1"
expect_verdict "zero tokens" 200 '{"choices":[{"message":{"content":""}}],"usage":{"completion_tokens":0}}' \
  "error:the reply carries no generated tokens"
expect_verdict "tokens counted but no text" 200 '{"choices":[{"message":{}}],"usage":{"completion_tokens":3}}' \
  "error:the reply carries no generated tokens"
expect_verdict "not JSON" 200 'upstream connect error' "error:the reply carries no generated tokens"
expect_verdict "no answer body" 502 '' "error:HTTP 502: "

keyfile="$sandbox/key"
printf 'k3y"secret\\x' >"$keyfile"
inference_resolve_client_keyfile() { INFERENCE_CLIENT_KEYFILE="$keyfile"; }
curl_body="" curl_code="" curl_rc=0
curl() {
  printf '%s\n' "$@" >"$sandbox/curl-argv"
  cat >"$sandbox/curl-config"
  [ "$curl_rc" = 0 ] || return "$curl_rc"
  printf '%s\n%s' "$curl_body" "$curl_code"
}
expect_generation() {
  local label="$1" expected_status="$2" expected_text="$3" status=0 out
  cases=$((cases + 1))
  out="$( (require_generation) 2>&1)" || status=$?
  if [ "$status" != "$expected_status" ] || [[ "$out" != *"$expected_text"* ]]; then
    failures=$((failures + 1))
    echo "FAIL generation $label: status=$status out=$out" >&2
  fi
}
curl_body='{"choices":[{"message":{"content":"ready"}}],"usage":{"completion_tokens":2}}' curl_code=200
expect_generation "a decoding model passes" 0 "GENERATES: $EXPECTED_MODEL decoded 2 token(s)"
cases=$((cases + 1))
if grep -Fq 'secret' "$sandbox/curl-argv" || ! grep -Fq 'Bearer k3y\"secret\\x' "$sandbox/curl-config" \
   || ! grep -Fq "\"model\":\"$EXPECTED_MODEL\"" "$sandbox/curl-argv" \
   || ! grep -Fq '"max_tokens":64' "$sandbox/curl-argv" || ! grep -Fq 'single word: ready' "$sandbox/curl-argv"; then
  failures=$((failures + 1))
  echo "FAIL generation: the key must travel in curl's config (escaped), the exact served id and the ready prompt in the request" >&2
fi
curl_body='{"choices":[{"message":{"content":"気球 towing"}}],"usage":{"completion_tokens":4}}' curl_code=200
expect_generation "an incoherent model fails acceptance" 1 "does not generate: the reply is not the asked-for word"
curl_body="$device_error" curl_code=500
expect_generation "the device-error package fails acceptance" 1 "does not generate: HTTP 500: prepared model reported device error 1"
curl_rc=7
expect_generation "an unreachable endpoint fails acceptance" 1 "could not reach :8000"
curl_rc=0
inference_resolve_client_keyfile() { return 1; }
expect_generation "no key fails acceptance" 1 "no synchronized API key"

if [ "$failures" -ne 0 ]; then
  echo "switch-glm53 boot receipt unit: $failures of $cases cases FAILED" >&2
  exit 1
fi
echo "switch-glm53 boot receipt unit: PASS ($cases cases)"
