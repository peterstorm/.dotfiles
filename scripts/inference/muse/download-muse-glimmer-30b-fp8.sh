#!/usr/bin/env bash
# shellcheck disable=SC1091 # Runtime-relative shared inference modules.
# Download and verify the pinned Muse Glimmer FP8 target and official DFlash draft.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-fp8-profile.sh
source "$SCRIPT_DIR/muse-glimmer-fp8-profile.sh"

write_completion_marker() {
  local directory="$1" expected="$2" temporary
  temporary="$directory/.download-complete.new"
  printf '%s\n' "$expected" >"$temporary"
  chmod 0640 "$temporary"
  mv -f "$temporary" "$directory/.download-complete"
}

checkpoint_is_complete() {
  local directory="$1" expected="$2" manifest="$3"
  if [ -f "$directory/.download-complete" ] \
    && grep -Fxq "$expected" "$directory/.download-complete" \
    && inference_verify_checkpoint_manifest "$directory" "$manifest"; then
    return 0
  fi
  if inference_verify_checkpoint_manifest "$directory" "$manifest" 2>/dev/null; then
    write_completion_marker "$directory" "$expected"
    return 0
  fi
  return 1
}

download_checkpoint() {
  local repo="$1" revision="$2" directory="$3" manifest="$4"
  hf download "$repo" --revision "$revision" --local-dir "$directory"
  inference_verify_checkpoint_manifest "$directory" "$manifest"
  write_completion_marker "$directory" "$repo@$revision"
}

download_all() {
  local state_dir="$1" lock
  lock="$state_dir/muse-glimmer-30b-fp8.lock"
  mkdir -p "$state_dir" "$MUSE_FP8_TARGET_HOST" "$MUSE_FP8_DRAFT_HOST"
  exec 9>"$lock"
  if ! flock -n 9; then
    echo "error: another Muse FP8 download or verification owns $lock" >&2
    return 1
  fi

  export HF_HUB_DISABLE_XET=1
  if ! checkpoint_is_complete \
    "$MUSE_FP8_TARGET_HOST" "$MUSE_FP8_TARGET_REPO@$MUSE_FP8_TARGET_REV" \
    "$MUSE_FP8_TARGET_MANIFEST"; then
    download_checkpoint \
      "$MUSE_FP8_TARGET_REPO" "$MUSE_FP8_TARGET_REV" \
      "$MUSE_FP8_TARGET_HOST" "$MUSE_FP8_TARGET_MANIFEST"
  fi
  if ! checkpoint_is_complete \
    "$MUSE_FP8_DRAFT_HOST" "$MUSE_FP8_DRAFT_REPO@$MUSE_FP8_DRAFT_REV" \
    "$MUSE_FP8_DRAFT_MANIFEST"; then
    download_checkpoint \
      "$MUSE_FP8_DRAFT_REPO" "$MUSE_FP8_DRAFT_REV" \
      "$MUSE_FP8_DRAFT_HOST" "$MUSE_FP8_DRAFT_MANIFEST"
  fi
  echo "DOWNLOAD_COMPLETE: Muse Glimmer FP8 target and DFlash draft verified."
}

main() {
  local command token_file token_mode state_dir log_file worker_pid
  inference_resolve_operator
  for command in hf sha256sum stat flock; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required Nix-managed command is unavailable: $command" >&2
      return 1
    }
  done

  token_file="$INFERENCE_OPERATOR_HOME/.config/hf/token"
  if [ -f "$token_file" ]; then
    token_mode="$(stat -c %a "$token_file")"
    if ((8#$token_mode & 8#077)); then
      echo "error: Hugging Face token file must be private: $token_file" >&2
      return 1
    fi
    export HF_TOKEN_PATH="$token_file"
  else
    echo "note: no Hugging Face token file; using unauthenticated rate limits" >&2
  fi

  MUSE_FP8_DOWNLOAD_DETACH="${MUSE_FP8_DOWNLOAD_DETACH:-no}"
  MUSE_FP8_DOWNLOAD_WORKER="${MUSE_FP8_DOWNLOAD_WORKER:-no}"
  case "$MUSE_FP8_DOWNLOAD_DETACH:$MUSE_FP8_DOWNLOAD_WORKER" in
    yes:no|no:no|no:yes) ;;
    *)
      echo "error: invalid detached/worker state" >&2
      return 2
      ;;
  esac

  state_dir="$INFERENCE_OPERATOR_HOME/.local/state/creative-model-downloads"
  if [ "$MUSE_FP8_DOWNLOAD_DETACH" = yes ]; then
    mkdir -p "$state_dir"
    log_file="$state_dir/muse-glimmer-30b-fp8.log"
    nohup env \
      MUSE_FP8_DOWNLOAD_DETACH=no \
      MUSE_FP8_DOWNLOAD_WORKER=yes \
      MUSE_FP8_MODELS_ROOT="${MUSE_FP8_MODELS_ROOT:-/models/vllm-cache/muse-glimmer-30b-fp8}" \
      bash "$0" >"$log_file" 2>&1 </dev/null &
    worker_pid=$!
    echo "DOWNLOAD_STARTED: Muse Glimmer FP8 worker PID $worker_pid"
    echo "Follow: tail -f $log_file"
    return 0
  fi

  download_all "$state_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
