#!/usr/bin/env bash
# Contract for the shared multi-endpoint inference credential and sudo-safe ownership.
# shellcheck disable=SC2016 # Assertions intentionally match literal shell source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT/scripts/inference/shared/inference-api-key.sh"
SWITCH="$ROOT/scripts/inference/qwen38/switch-qwen38-backend.sh"
BENCHMARK_ARM="$ROOT/benchmarks/loom-model-ab/scripts/run-arm.sh"
LAUNCHERS=(
  "$ROOT/scripts/inference/deepseek/run-ds4-infernal-invocation-r18.sh"
  "$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16.sh"
  "$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-vllm.sh"
  "$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dspark-sglang.sh"
  "$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-sglang-v2.sh"
  "$ROOT/scripts/inference/qwen38/run-qwen38-27b-bf16-dflash2-vllm-v2.sh"
  "$ROOT/scripts/inference/glm53/run-glm53-flash-nvfp4-vllm-sm120-v2.sh"
  "$ROOT/scripts/inference/muse/run-muse-glimmer-30b-bf16-dflash.sh"
)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1" text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

[[ -r "$HELPER" ]] || fail "$HELPER is not readable"
bash -n "$HELPER"
bash -n "$SWITCH"
bash -n "$BENCHMARK_ARM"
contains "$HELPER" 'SUDO_USER'
contains "$HELPER" 'getent passwd "$INFERENCE_OPERATOR_USER"'
contains "$HELPER" 'INFERENCE_DS4_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/ds4-flash/api-key"'
contains "$HELPER" 'INFERENCE_QWEN_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/qwen38/api-key"'
contains "$HELPER" 'INFERENCE_GLM_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/glm53/api-key"'
contains "$HELPER" 'INFERENCE_MUSE_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/muse-glimmer/api-key"'
contains "$HELPER" 'INFERENCE_SOPS_KEYFILE="$INFERENCE_OPERATOR_HOME/.config/sops-nix/secrets/vllm-api-key"'
contains "$HELPER" 'inference_install_private_dir "$INFERENCE_OPERATOR_HOME/.config"'

for launcher in "${LAUNCHERS[@]}"; do
  bash -n "$launcher"
  contains "$launcher" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
  contains "$launcher" 'inference_prepare_api_key'
done
contains "$SWITCH" 'source "$SCRIPT_DIR/../shared/inference-api-key.sh"'
contains "$SWITCH" 'authenticated_status'
contains "$SWITCH" 'refusing a speculative restart'
contains "$SWITCH" 'HEALTHY + AUTHENTICATED:'
contains "$SWITCH" 'curl --config -'
if grep -Eq -- 'curl .*Authorization: Bearer' "$SWITCH"; then
  fail "$SWITCH puts the API key in curl argv"
fi
contains "$BENCHMARK_ARM" 'curl --config -'
if grep -Eq -- 'curl .*Authorization: Bearer' "$BENCHMARK_ARM"; then
  fail "$BENCHMARK_ARM puts the API key in curl argv"
fi

# A pre-existing Qwen-only installation migrates to every model-specific path.
(
  export HOME="$sandbox/qwen-only"
  unset SUDO_USER VLLM_API_KEY SGLANG_API_KEY
  mkdir -p "$HOME/.config/qwen38"
  printf '%s\n' 'qwen-fixture-key-0123456789abcdef' >"$HOME/.config/qwen38/api-key"
  # shellcheck source=scripts/inference-api-key.sh
  source "$HELPER"
  inference_prepare_api_key ""
  cmp -s "$HOME/.config/qwen38/api-key" "$HOME/.config/ds4-flash/api-key" \
    || fail "Qwen-only migration did not synchronize the DeepSeek key path"
  cmp -s "$HOME/.config/qwen38/api-key" "$HOME/.config/glm53/api-key" \
    || fail "Qwen-only migration did not synchronize the GLM key path"
  cmp -s "$HOME/.config/qwen38/api-key" "$HOME/.config/muse-glimmer/api-key" \
    || fail "Qwen-only migration did not synchronize the Muse key path"
  grep -Fxq 'qwen-fixture-key-0123456789abcdef' "$HOME/.config/ds4-flash/api-key" \
    || fail "Qwen-only migration changed the key"
)

# If old paths diverged, the same DeepSeek-first order used by Pi wins.
(
  export HOME="$sandbox/diverged"
  unset SUDO_USER VLLM_API_KEY SGLANG_API_KEY
  mkdir -p "$HOME/.config/ds4-flash" "$HOME/.config/qwen38"
  printf '%s\n' 'canonical-ds4-key-0123456789abcdef' >"$HOME/.config/ds4-flash/api-key"
  printf '%s\n' 'stale-qwen-key-0123456789abcdef00' >"$HOME/.config/qwen38/api-key"
  # shellcheck source=scripts/inference-api-key.sh
  source "$HELPER"
  inference_prepare_api_key ""
  grep -Fxq 'canonical-ds4-key-0123456789abcdef' "$HOME/.config/qwen38/api-key" \
    || fail "diverged paths did not converge on Pi's DeepSeek-first key"
  grep -Fxq 'canonical-ds4-key-0123456789abcdef' "$HOME/.config/glm53/api-key" \
    || fail "GLM path did not converge on Pi's DeepSeek-first key"
  grep -Fxq 'canonical-ds4-key-0123456789abcdef' "$HOME/.config/muse-glimmer/api-key" \
    || fail "Muse path did not converge on Pi's DeepSeek-first key"
)

# A host with only the Pi sops fallback migrates it into both writable paths.
(
  export HOME="$sandbox/sops-only"
  unset SUDO_USER VLLM_API_KEY SGLANG_API_KEY
  mkdir -p "$HOME/.config/sops-nix/secrets"
  printf '%s\n' 'sops-fixture-key-0123456789abcdef0' >"$HOME/.config/sops-nix/secrets/vllm-api-key"
  # shellcheck source=scripts/inference-api-key.sh
  source "$HELPER"
  inference_prepare_api_key ""
  grep -Fxq 'sops-fixture-key-0123456789abcdef0' "$HOME/.config/ds4-flash/api-key" \
    || fail "sops-only migration did not seed the writable endpoint key"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/qwen38/api-key" \
    || fail "sops-only migration did not synchronize the Qwen key path"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/glm53/api-key" \
    || fail "sops-only migration did not synchronize the GLM key path"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/muse-glimmer/api-key" \
    || fail "sops-only migration did not synchronize the Muse key path"
)

# A fresh install always generates a validation-safe fixed-length key.
(
  export HOME="$sandbox/generated"
  unset SUDO_USER VLLM_API_KEY SGLANG_API_KEY
  # shellcheck source=scripts/inference-api-key.sh
  source "$HELPER"
  inference_prepare_api_key ""
  generated_key="$(<"$HOME/.config/ds4-flash/api-key")"
  [[ "${#generated_key}" -eq 32 ]] || fail "generated API key is not exactly 32 characters"
  inference_validate_api_key "$generated_key" || fail "generated API key fails its own validator"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/qwen38/api-key" \
    || fail "generated key was not synchronized to Qwen"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/glm53/api-key" \
    || fail "generated key was not synchronized to GLM"
  cmp -s "$HOME/.config/ds4-flash/api-key" "$HOME/.config/muse-glimmer/api-key" \
    || fail "generated key was not synchronized to Muse"
)

# An explicit rotation is persisted atomically to every path with private modes.
(
  export HOME="$sandbox/explicit"
  unset SUDO_USER VLLM_API_KEY SGLANG_API_KEY
  # shellcheck source=scripts/inference-api-key.sh
  source "$HELPER"
  inference_prepare_api_key 'rotated-fixture-key-0123456789abcdef'
  if inference_validate_api_key 'too-short' 2>/dev/null; then
    fail "weak API key passed validation"
  fi
  if inference_validate_api_key 'invalid key with spaces 0123456789abcdef' 2>/dev/null; then
    fail "API key with unsafe characters passed validation"
  fi
  for keyfile in "$HOME/.config/ds4-flash/api-key" "$HOME/.config/qwen38/api-key" "$HOME/.config/glm53/api-key" "$HOME/.config/muse-glimmer/api-key"; do
    grep -Fxq 'rotated-fixture-key-0123456789abcdef' "$keyfile" || fail "explicit key was not persisted to $keyfile"
    [[ "$(stat -c '%a' "$keyfile")" = 600 ]] || fail "$keyfile is not mode 0600"
  done
  for directory in "$HOME/.config" "$HOME/.config/ds4-flash" "$HOME/.config/qwen38" "$HOME/.config/glm53" "$HOME/.config/muse-glimmer"; do
    [[ "$(stat -c '%a' "$directory")" = 700 ]] || fail "$directory is not mode 0700"
  done
  inference_write_private_file "$HOME/.config/qwen38/test.env" <<EOF
VLLM_API_KEY=$INFERENCE_API_KEY
EOF
  [[ "$(stat -c '%a' "$HOME/.config/qwen38/test.env")" = 600 ]] \
    || fail "env file is not mode 0600"
)

# Exercise the switcher's stale-key repair and its fail-closed indeterminate path
# with Docker/curl/ss boundary stubs. No model or daemon is touched.
switch_fixture="$sandbox/switch-fixture"
mkdir -p "$switch_fixture/scripts/qwen38" "$switch_fixture/scripts/shared" "$switch_fixture/bin" "$switch_fixture/home/.config/ds4-flash"
cp "$SWITCH" "$switch_fixture/scripts/qwen38/"
cp "$HELPER" "$switch_fixture/scripts/shared/"
printf '%s\n' 'switch-fixture-key-0123456789abcdef' >"$switch_fixture/home/.config/ds4-flash/api-key"
cat >"$switch_fixture/scripts/qwen38/run-qwen38-27b-bf16-dspark-vllm.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
inference_prepare_api_key ""
printf '%s\n' "$INFERENCE_API_KEY" >"$TEST_SWITCH_STATE"
SH
cat >"$switch_fixture/scripts/qwen38/run-qwen38-27b-bf16-dspark-sglang.sh" <<'SH'
#!/usr/bin/env bash
exit 99
SH
cat >"$switch_fixture/bin/docker" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  inspect)
    case "${*: -1}" in
      qwen38-27b-bf16-dspark-vllm) printf '%s\n' true ;;
      *) exit 1 ;;
    esac
    ;;
  stop) exit 0 ;;
  logs) printf '%s\n' 'fixture log' ;;
  *) exit 0 ;;
esac
SH
cat >"$switch_fixture/bin/curl" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *' --config - '*)
    config="$(cat)"
    if grep -Fq '/health' <<<"$config"; then
      printf '%s' 200
    elif [ "$(cat "$TEST_SWITCH_STATE")" != old ] \
      && cmp -s "$TEST_SWITCH_STATE" "$HOME/.config/ds4-flash/api-key"; then
      printf '%s' 200
    else
      printf '%s' "$TEST_INITIAL_AUTH_STATUS"
    fi
    ;;
  *'/health'*) exit 0 ;;
  *'/metrics'*) exit 0 ;;
  *) exit 1 ;;
esac
SH
cat >"$switch_fixture/bin/ss" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$switch_fixture/scripts/qwen38/"*.sh "$switch_fixture/bin/"*

printf '%s\n' old >"$switch_fixture/state"
switch_output="$(
  HOME="$switch_fixture/home" \
  PATH="$switch_fixture/bin:$PATH" \
  TEST_SWITCH_STATE="$switch_fixture/state" \
  TEST_INITIAL_AUTH_STATUS=401 \
  bash "$switch_fixture/scripts/qwen38/switch-qwen38-backend.sh" vllm
)"
grep -Fq 'restarting with the synchronized key' <<<"$switch_output" \
  || fail "switcher did not restart a healthy target with a rejected key"
grep -Fq 'HEALTHY + AUTHENTICATED:' <<<"$switch_output" \
  || fail "switcher did not authenticate the replacement backend"
cmp -s "$switch_fixture/state" "$switch_fixture/home/.config/ds4-flash/api-key" \
  || fail "replacement launcher did not supply Pi's synchronized key"

printf '%s\n' old >"$switch_fixture/state"
switch_status=0
switch_output="$(
  HOME="$switch_fixture/home" \
  PATH="$switch_fixture/bin:$PATH" \
  TEST_SWITCH_STATE="$switch_fixture/state" \
  TEST_INITIAL_AUTH_STATUS=500 \
  bash "$switch_fixture/scripts/qwen38/switch-qwen38-backend.sh" vllm 2>&1
)" || switch_status=$?
[[ "$switch_status" -eq 1 ]] || fail "switcher did not fail closed for indeterminate authentication"
grep -Fq 'refusing a speculative restart' <<<"$switch_output" \
  || fail "switcher misclassified indeterminate authentication"
[[ "$(cat "$switch_fixture/state")" = old ]] || fail "switcher restarted on an indeterminate API failure"

printf 'PASS: inference API key remains synchronized, private, and sudo-operator aware\n'
