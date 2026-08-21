#!/usr/bin/env bash
# Behavioral contracts for creative-stack rollback and dual-profile cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
DUAL="$ROOT/scripts/inference/profiles/run-qwen38-muse-glimmer-dual.sh"
VARIANTS="$ROOT/scripts/inference/muse/muse-glimmer-variant.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$VARIANTS"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_checkpoint() {
  local directory="$1" marker="$2" manifest="$3"
  local expected_sha expected_size relative
  mkdir -p "$directory"
  while read -r expected_sha expected_size relative; do
    [ -n "$relative" ] || continue
    mkdir -p "$(dirname "$directory/$relative")"
    truncate -s "$expected_size" "$directory/$relative"
    printf '%s %s\n' "$expected_sha" "$directory/$relative" >>"$MANIFEST_FACTS"
  done <<<"$manifest"
  printf '%s\n' "$marker" >"$directory/.download-complete"
}

install_sha_stub() {
  local bin="$1"
  cat >"$bin/sha256sum" <<'EOF'
#!/usr/bin/env bash
file="${*: -1}"
expected="$(awk -v file="$file" '$2 == file { print $1; exit }' "$MANIFEST_FACTS")"
[ -n "$expected" ] || { echo "missing checksum fixture: $file" >&2; exit 1; }
printf '%s  %s\n' "$expected" "$file"
EOF
  chmod +x "$bin/sha256sum"
}

prepare_muse_checkpoints() {
  local models="$1"
  MUSE_MODELS_ROOT="$models"
  muse_resolve_variant abliterated
  make_checkpoint "$MUSE_TARGET_HOST" "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" "$MUSE_TARGET_MANIFEST"
  make_checkpoint "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV" "$MUSE_DRAFT_MANIFEST"
  unset MUSE_MODELS_ROOT
}

run_creative_rollback_case() {
  local expect_incomplete="$1" sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  touch "$sandbox/state/comfy-active"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  is-active)
    if test -f "$STATE/comfy-active"; then echo active; exit 0; fi
    echo inactive
    exit 3
    ;;
  stop) rm -f "$STATE/comfy-active"; exit 0 ;;
  start) touch "$STATE/comfy-active"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  cat >"$sandbox/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
case "$command" in
  info) exit 0 ;;
  inspect)
    name="${*: -1}"
    case "$name" in
      qwen38-27b-bf16-dflash2-vllm)
        if [[ "$*" == *--format* ]]; then echo true; else echo '{}'; fi
        exit 0
        ;;
      *) echo "Error: No such object: $name" >&2; exit 1 ;;
    esac
    ;;
  stop) printf 'docker stop %s\n' "$*" >>"$STATE/events"; exit 0 ;;
  start)
    printf 'docker start %s\n' "$*" >>"$STATE/events"
    [ "${FAIL_RESTORE:-0}" -eq 0 ]
    ;;
  *) printf 'docker %s %s\n' "$command" "$*" >>"$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
# One record forces a post-stop failure and enters rollback.
echo '0, 0'
EOF
  cat >"$sandbox/bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  cat >"$sandbox/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" FAIL_RESTORE="$expect_incomplete" \
    MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  grep -Fq 'docker stop -t 30 qwen38-27b-bf16-dflash2-vllm' "$sandbox/state/events" \
    || fail "creative activation did not stop the prior Qwen container"
  grep -Fq 'docker start qwen38-27b-bf16-dflash2-vllm' "$sandbox/state/events" \
    || fail "creative rollback did not attempt to restart prior Qwen"
  grep -Fq 'systemctl start comfyui.service' "$sandbox/state/events" \
    || fail "creative rollback did not restore prior ComfyUI"

  if [ "$expect_incomplete" -eq 0 ]; then
    [ "$status" -ne 0 ] && [ "$status" -ne 70 ] \
      || fail "successful rollback must preserve the original nonzero status"
    test -f "$sandbox/state/comfy-active" \
      || fail "successful rollback left prior ComfyUI inactive"
  else
    [ "$status" -eq 70 ] \
      || fail "incomplete rollback must return status 70 (got $status)"
    grep -Fq 'rollback error: restart prior container' "$sandbox/stderr" \
      || fail "incomplete rollback was not observable"
  fi
  rm -rf "$sandbox"
}

run_dual_cleanup_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/qwen"
  printf '{}\n' >"$sandbox/qwen/config.json"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"

  cat >"$sandbox/qwen-run" <<'EOF'
#!/usr/bin/env bash
touch "$STATE/qwen38-27b-bf16"
EOF
  cat >"$sandbox/muse-run" <<'EOF'
#!/usr/bin/env bash
touch "$STATE/muse-glimmer-30b-abliterated-bf16-dflash"
exit 1
EOF
  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
# display-manager must be explicitly inactive.
echo inactive
exit 3
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
case "$command" in
  info) exit 0 ;;
  inspect)
    name="${*: -1}"
    if [ -f "$STATE/$name" ]; then
      [[ "$*" == *--format* ]] && echo true || echo '{}'
      exit 0
    fi
    echo "Error: No such object: $name" >&2
    exit 1
    ;;
  stop) printf 'docker stop %s\n' "$*" >>"$STATE/events"; exit 0 ;;
  rm)
    name="${*: -1}"
    printf 'docker rm %s\n' "$*" >>"$STATE/events"
    rm -f "$STATE/$name"
    exit 0
    ;;
  *) printf 'docker %s %s\n' "$command" "$*" >>"$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *power.limit* ]]; then
  printf '0, 350\n1, 350\n'
else
  printf '0, 0\n1, 0\n'
fi
EOF
  chmod +x "$sandbox/qwen-run" "$sandbox/muse-run" "$sandbox/bin"/*

  STATE="$sandbox/state" MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    QWEN_MODEL_ROOT="$sandbox/qwen" QWEN_RUN="$sandbox/qwen-run" MUSE_RUN="$sandbox/muse-run" \
    PATH="$sandbox/bin:$PATH" bash "$DUAL" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] && [ "$status" -ne 70 ] \
    || fail "complete dual cleanup must preserve the launch failure status"
  grep -Fq 'docker rm -f qwen38-27b-bf16' "$sandbox/state/events" \
    || fail "dual cleanup did not remove newly launched Qwen"
  grep -Fq 'docker rm -f muse-glimmer-30b-abliterated-bf16-dflash' "$sandbox/state/events" \
    || fail "dual cleanup did not remove newly launched Muse"
  test ! -e "$sandbox/state/qwen38-27b-bf16" \
    || fail "dual cleanup left Qwen state behind"
  test ! -e "$sandbox/state/muse-glimmer-30b-abliterated-bf16-dflash" \
    || fail "dual cleanup left Muse state behind"
  rm -rf "$sandbox"
}

run_creative_inspect_failure_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  *) echo inactive; exit 3 ;;
esac
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
case "$command" in
  info) exit 0 ;;
  inspect)
    name="${*: -1}"
    if [ "$name" = ds4-0731-r31 ]; then
      echo 'permission denied opening Docker socket' >&2
      exit 125
    fi
    echo "Error: No such object: $name" >&2
    exit 1
    ;;
  *) printf 'docker %s %s\n' "$command" "$*" >>"$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" \
    MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -eq 2 ] || fail "Docker inspect failure must propagate status 2 (got $status)"
  grep -Fq 'could not inspect running state' "$sandbox/stderr" \
    || fail "Docker inspect failure was not reported"
  if grep -Eq 'docker (stop|start|rm)' "$sandbox/state/events"; then
    fail "creative activation mutated containers after inspect failure"
  fi
  rm -rf "$sandbox"
}

run_existing_muse_mismatch_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  *) echo inactive; exit 3 ;;
esac
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
case "$command" in
  info) exit 0 ;;
  inspect)
    name="${*: -1}"
    if [ "$name" = muse-glimmer-30b-abliterated-bf16-dflash ]; then
      if [[ "$*" == *State.Running* ]]; then echo true; else echo wrong-profile; fi
      exit 0
    fi
    echo "Error: No such object: $name" >&2
    exit 1
    ;;
  *) printf 'docker %s %s\n' "$command" "$*" >>"$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" \
    MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] || fail "mislabeled existing Muse container was accepted"
  grep -Fq "label 'io.peterstorm.inference.profile'" "$sandbox/stderr" \
    || fail "existing Muse label mismatch was not reported"
  if grep -Eq 'docker (stop|start|rm)' "$sandbox/state/events"; then
    fail "creative activation mutated containers after existing Muse mismatch"
  fi
  rm -rf "$sandbox"
}

run_dual_display_failure_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/qwen"
  printf '{}\n' >"$sandbox/qwen/config.json"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"
  cat >"$sandbox/qwen-run" <<'EOF'
#!/usr/bin/env bash
touch "$STATE/qwen-launched"
EOF
  cp "$sandbox/qwen-run" "$sandbox/muse-run"
  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo 'Failed to connect to bus' >&2
exit 1
EOF
  chmod +x "$sandbox/qwen-run" "$sandbox/muse-run" "$sandbox/bin"/*

  STATE="$sandbox/state" MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    QWEN_MODEL_ROOT="$sandbox/qwen" QWEN_RUN="$sandbox/qwen-run" MUSE_RUN="$sandbox/muse-run" \
    PATH="$sandbox/bin:$PATH" bash "$DUAL" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -eq 3 ] || fail "display-manager query failure must return status 3 (got $status)"
  grep -Fq 'could not prove display-manager is inactive' "$sandbox/stderr" \
    || fail "display-manager query failure was not reported"
  test ! -e "$sandbox/state/qwen-launched" \
    || fail "dual profile launched after display-manager query failure"
  rm -rf "$sandbox"
}

run_creative_post_launch_failure_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  touch "$sandbox/state/qwen38-27b-bf16-dflash2-vllm"
  MANIFEST_FACTS="$sandbox/manifest-facts"
  export MANIFEST_FACTS
  : >"$MANIFEST_FACTS"
  prepare_muse_checkpoints "$sandbox/models"
  install_sha_stub "$sandbox/bin"

  cat >"$sandbox/muse-launcher" <<'EOF'
#!/usr/bin/env bash
touch "$STATE/muse-glimmer-30b-abliterated-bf16-dflash"
EOF
  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  is-active)
    if test -f "$STATE/comfy-active"; then echo active; exit 0; fi
    echo inactive
    exit 3
    ;;
  stop) rm -f "$STATE/comfy-active"; exit 0 ;;
  start) touch "$STATE/comfy-active"; exit 0 ;;
  *) exit 1 ;;
esac
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
command="$1"; shift
case "$command" in
  info) exit 0 ;;
  inspect)
    name="${*: -1}"
    if [ -f "$STATE/$name" ]; then
      [[ "$*" == *--format* ]] && echo true || echo '{}'
      exit 0
    fi
    echo "Error: No such object: $name" >&2
    exit 1
    ;;
  stop)
    name="${*: -1}"
    printf 'docker stop %s\n' "$*" >>"$STATE/events"
    rm -f "$STATE/$name"
    exit 0
    ;;
  start)
    name="${*: -1}"
    printf 'docker start %s\n' "$*" >>"$STATE/events"
    touch "$STATE/$name"
    exit 0
    ;;
  logs) exit 0 ;;
  *) printf 'docker %s %s\n' "$command" "$*" >>"$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
printf '0, 0\n1, 0\n'
EOF
  cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *--config* ]]; then exit 1; fi
exit 0
EOF
  cat >"$sandbox/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat >"$sandbox/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$sandbox/muse-launcher" "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" HEALTH_TIMEOUT_SECONDS=1 \
    MUSE_LAUNCHER="$sandbox/muse-launcher" \
    MUSE_MODELS_ROOT="$sandbox/models" MUSE_VARIANT=abliterated \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] && [ "$status" -ne 70 ] \
    || fail "post-launch failure with complete rollback must preserve original status"
  grep -Fq 'docker stop -t 30 muse-glimmer-30b-abliterated-bf16-dflash' "$sandbox/state/events" \
    || fail "rollback did not stop newly launched Muse"
  grep -Fq 'docker start qwen38-27b-bf16-dflash2-vllm' "$sandbox/state/events" \
    || fail "rollback did not restore prior Qwen after Muse health failure"
  test ! -e "$sandbox/state/muse-glimmer-30b-abliterated-bf16-dflash" \
    || fail "new Muse container remained after failed activation"
  rm -rf "$sandbox"
}

run_creative_rollback_case 0
run_creative_rollback_case 1
run_creative_inspect_failure_case
run_existing_muse_mismatch_case
run_dual_display_failure_case
run_creative_post_launch_failure_case
run_dual_cleanup_case
printf 'PASS: creative profile transitions rollback and clean up behaviorally\n'
