#!/usr/bin/env bash
# Behavioral contracts for creative-stack activation and rollback.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
AUTHOR_NAME="qwen38-27b-blackfrost-abliterated-bf16-vllm"
AUTHOR_PIN="Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@9d85770e5eb602322b4bceef55beda357e0bd0ca"
PRIOR_NAME="qwen38-27b-bf16-dflash2-vllm"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Activation checks checkpoint identity, not content — the downloader already
# proved every artifact against the pinned manifest.
prepare_author_checkpoint() {
  local directory="$1"
  mkdir -p "$directory"
  printf '%s\n' "$AUTHOR_PIN" >"$directory/.download-complete"
}

write_common_stubs() {
  local bin="$1"
  cat >"$bin/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
  cat >"$bin/ss" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$bin/journalctl" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
}

run_creative_rollback_case() {
  local expect_incomplete="$1" sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  touch "$sandbox/state/comfy-active"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  prepare_author_checkpoint "$sandbox/models/author"

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
  cat >"$sandbox/bin/docker" <<EOF
#!/usr/bin/env bash
command="\$1"; shift
case "\$command" in
  info) exit 0 ;;
  inspect)
    name="\${*: -1}"
    case "\$name" in
      $PRIOR_NAME)
        if [[ "\$*" == *--format* ]]; then echo true; else echo '{}'; fi
        exit 0
        ;;
      *) echo "Error: No such object: \$name" >&2; exit 1 ;;
    esac
    ;;
  stop) printf 'docker stop %s\n' "\$*" >>"\$STATE/events"; exit 0 ;;
  start)
    printf 'docker start %s\n' "\$*" >>"\$STATE/events"
    [ "\${FAIL_RESTORE:-0}" -eq 0 ]
    ;;
  *) printf 'docker %s %s\n' "\$command" "\$*" >>"\$STATE/events"; exit 0 ;;
esac
EOF
  cat >"$sandbox/bin/nvidia-smi" <<'EOF'
#!/usr/bin/env bash
# One record forces a post-stop failure and enters rollback.
echo '0, 0'
EOF
  cat >"$sandbox/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  write_common_stubs "$sandbox/bin"
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" FAIL_RESTORE="$expect_incomplete" \
    AUTHOR_MODEL_HOST="$sandbox/models/author" \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  grep -Fq "docker stop -t 30 $PRIOR_NAME" "$sandbox/state/events" \
    || fail "creative activation did not stop the prior Qwen container"
  grep -Fq "docker start $PRIOR_NAME" "$sandbox/state/events" \
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

run_missing_checkpoint_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models/author" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  # Present but pinned to a different revision.
  printf '%s\n' "Blackfrost-AI/Qwen3.8-27B-ABLITERATED-BF16@0000000000000000000000000000000000000000" \
    >"$sandbox/models/author/.download-complete"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  *) echo inactive; exit 3 ;;
esac
EOF
  cat >"$sandbox/bin/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >>"$STATE/events"
exit 0
EOF
  write_common_stubs "$sandbox/bin"
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" \
    AUTHOR_MODEL_HOST="$sandbox/models/author" \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] || fail "activation accepted a checkpoint pinned to the wrong revision"
  grep -Fq 'lacks the pinned revision marker' "$sandbox/stderr" \
    || fail "revision mismatch was not reported"
  test ! -s "$sandbox/state/events" \
    || fail "activation mutated containers before proving the checkpoint"
  rm -rf "$sandbox"
}

run_existing_author_mismatch_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  prepare_author_checkpoint "$sandbox/models/author"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  *) echo inactive; exit 3 ;;
esac
EOF
  cat >"$sandbox/bin/docker" <<EOF
#!/usr/bin/env bash
command="\$1"; shift
case "\$command" in
  info) exit 0 ;;
  inspect)
    name="\${*: -1}"
    if [ "\$name" = $AUTHOR_NAME ]; then
      if [[ "\$*" == *State.Running* ]]; then echo true; else echo wrong-profile; fi
      exit 0
    fi
    echo "Error: No such object: \$name" >&2
    exit 1
    ;;
  *) printf 'docker %s %s\n' "\$command" "\$*" >>"\$STATE/events"; exit 0 ;;
esac
EOF
  write_common_stubs "$sandbox/bin"
  chmod +x "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" \
    AUTHOR_MODEL_HOST="$sandbox/models/author" \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] || fail "mislabeled existing prompt-author container was accepted"
  grep -Fq "label 'io.peterstorm.inference.profile'" "$sandbox/stderr" \
    || fail "existing prompt-author label mismatch was not reported"
  if grep -Eq 'docker (stop|start|rm)' "$sandbox/state/events"; then
    fail "creative activation mutated containers after existing author mismatch"
  fi
  rm -rf "$sandbox"
}

run_creative_post_launch_failure_case() {
  local sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models" "$sandbox/home/.config/ds4-flash"
  printf '%032d\n' 0 >"$sandbox/home/.config/ds4-flash/api-key"
  touch "$sandbox/state/$PRIOR_NAME"
  prepare_author_checkpoint "$sandbox/models/author"

  cat >"$sandbox/author-launcher" <<EOF
#!/usr/bin/env bash
touch "\$STATE/$AUTHOR_NAME"
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
  write_common_stubs "$sandbox/bin"
  chmod +x "$sandbox/author-launcher" "$sandbox/bin"/*

  HOME="$sandbox/home" STATE="$sandbox/state" HEALTH_TIMEOUT_SECONDS=1 \
    AUTHOR_LAUNCHER="$sandbox/author-launcher" \
    AUTHOR_MODEL_HOST="$sandbox/models/author" \
    PATH="$sandbox/bin:$PATH" bash "$ACTIVATE" \
    >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?

  [ "$status" -ne 0 ] && [ "$status" -ne 70 ] \
    || fail "post-launch failure with complete rollback must preserve original status"
  grep -Fq "docker stop -t 30 $AUTHOR_NAME" "$sandbox/state/events" \
    || fail "rollback did not stop the newly launched prompt author"
  grep -Fq "docker start $PRIOR_NAME" "$sandbox/state/events" \
    || fail "rollback did not restore prior Qwen after author health failure"
  test ! -e "$sandbox/state/$AUTHOR_NAME" \
    || fail "new prompt-author container remained after failed activation"
  rm -rf "$sandbox"
}

run_creative_rollback_case 0
run_creative_rollback_case 1
run_missing_checkpoint_case
run_existing_author_mismatch_case
run_creative_post_launch_failure_case
printf 'PASS: creative profile transitions activate and roll back behaviorally\n'
