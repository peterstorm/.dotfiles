#!/usr/bin/env bash
# Behavioral contracts for creative-stack rollback and dual-profile cleanup.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="$ROOT/scripts/comfyui/activate-creative-stack.sh"
DUAL="$ROOT/scripts/inference/profiles/run-qwen38-muse-glimmer-dual.sh"
TARGET_REV="daf5fab76a0351a583714a92d88ebdb6eb48af35"
DRAFT_REV="e8192f3a8f617f74be2ce220360c89ef4789f39f"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_checkpoint() {
  local directory="$1" marker="$2"
  mkdir -p "$directory"
  printf '{}\n' >"$directory/config.json"
  printf '%s\n' "$marker" >"$directory/.download-complete"
}

run_creative_rollback_case() {
  local expect_incomplete="$1" sandbox status=0
  sandbox="$(mktemp -d)"
  mkdir -p "$sandbox/bin" "$sandbox/state" "$sandbox/models"
  touch "$sandbox/state/comfy-active"
  make_checkpoint \
    "$sandbox/models/Muse-Glimmer-30B-Abliterated-BF16" \
    "mlasli/Muse-Glimmer-30B-Abliterated-BF16@$TARGET_REV"
  make_checkpoint \
    "$sandbox/models/Muse-Glimmer-30B-assistant" \
    "meta-models/Muse-Glimmer-30B-assistant@$DRAFT_REV"

  cat >"$sandbox/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'systemctl %s\n' "$*" >>"$STATE/events"
case "$1" in
  cat) exit 0 ;;
  show) echo 'CUDA_VISIBLE_DEVICES=1'; exit 0 ;;
  is-active) test -f "$STATE/comfy-active" ;;
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

  STATE="$sandbox/state" FAIL_RESTORE="$expect_incomplete" \
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
  make_checkpoint \
    "$sandbox/models/Muse-Glimmer-30B-Abliterated-BF16" \
    "mlasli/Muse-Glimmer-30B-Abliterated-BF16@$TARGET_REV"
  make_checkpoint \
    "$sandbox/models/Muse-Glimmer-30B-assistant" \
    "meta-models/Muse-Glimmer-30B-assistant@$DRAFT_REV"

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
# display-manager must be inactive.
exit 1
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

run_creative_rollback_case 0
run_creative_rollback_case 1
run_dual_cleanup_case
printf 'PASS: creative profile transitions rollback and clean up behaviorally\n'
