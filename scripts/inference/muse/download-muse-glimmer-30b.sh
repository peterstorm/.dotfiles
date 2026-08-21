#!/usr/bin/env bash
# Download a pinned BF16 Muse Glimmer target and the official BF16 DFlash draft.
#
# MUSE_VARIANT=standard selects the qualified upstream target;
# MUSE_VARIANT=abliterated selects mlasli's BF16 refusal-suppressed derivative.
# The linked Abliterated-BF16 repository is full BF16, not a quantization.
# Together target + draft occupy about 60.2 GiB. The operation is resumable and
# uses the Nix-managed Hugging Face client. Standard Hub HTTPS is forced because
# hf-xet 1.6.0 hangs on this workstation for Muse.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/muse/muse-glimmer-variant.sh
source "$SCRIPT_DIR/muse-glimmer-variant.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"

write_completion_marker() {
  local directory="$1" expected="$2" marker_tmp
  marker_tmp="$directory/.download-complete.new"
  printf '%s\n' "$expected" >"$marker_tmp"
  chmod 0640 "$marker_tmp"
  mv -f "$marker_tmp" "$directory/.download-complete"
}

download_checkpoint() {
  local repo="$1" revision="$2" directory="$3" manifest="$4"
  hf download "$repo" --revision "$revision" --local-dir "$directory" || return $?
  inference_verify_checkpoint_manifest "$directory" "$manifest" || return $?
  write_completion_marker "$directory" "$repo@$revision"
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

ensure_hf_metadata_access() {
  local directory="$1" metadata
  metadata="$directory/.cache/huggingface"
  if [ -e "$metadata" ] && [ ! -w "$metadata" ]; then
    sudo chown -R "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" "$metadata"
  fi
}

download_muse_models() {
  local state_dir="$1" lock target_ready=0 draft_ready=0
  lock="$state_dir/muse-glimmer-$MUSE_VARIANT.lock"
  mkdir -p "$state_dir"
  exec 9>"$lock"
  if ! flock -n 9; then
    echo "error: another Muse '$MUSE_VARIANT' download or verification owns $lock" >&2
    return 1
  fi

  checkpoint_is_complete \
    "$MUSE_TARGET_HOST" "$MUSE_TARGET_REPO@$MUSE_TARGET_REV" "$MUSE_TARGET_MANIFEST" \
    && target_ready=1
  checkpoint_is_complete \
    "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_REPO@$MUSE_DRAFT_REV" "$MUSE_DRAFT_MANIFEST" \
    && draft_ready=1
  if [ "$target_ready" -eq 1 ] && [ "$draft_ready" -eq 1 ]; then
    echo "DOWNLOAD_COMPLETE: Muse '$MUSE_VARIANT' target and DFlash draft verified."
    return 0
  fi

  export HF_HUB_DISABLE_XET=1
  if [ "$target_ready" -eq 0 ]; then
    ensure_hf_metadata_access "$MUSE_TARGET_HOST"
    download_checkpoint \
      "$MUSE_TARGET_REPO" "$MUSE_TARGET_REV" "$MUSE_TARGET_HOST" "$MUSE_TARGET_MANIFEST"
  fi
  if [ "$draft_ready" -eq 0 ]; then
    ensure_hf_metadata_access "$MUSE_DRAFT_HOST"
    download_checkpoint \
      "$MUSE_DRAFT_REPO" "$MUSE_DRAFT_REV" "$MUSE_DRAFT_HOST" "$MUSE_DRAFT_MANIFEST"
  fi
  echo "DOWNLOAD_COMPLETE: Muse '$MUSE_VARIANT' target and DFlash draft verified."
}

main() {
  local command token_file token_mode state_dir log_file worker_pid
  inference_resolve_operator
  muse_resolve_variant "${MUSE_VARIANT:-standard}"

  MUSE_DOWNLOAD_DETACH="${MUSE_DOWNLOAD_DETACH:-no}"
  MUSE_DOWNLOAD_WORKER="${MUSE_DOWNLOAD_WORKER:-no}"
  case "$MUSE_DOWNLOAD_DETACH:$MUSE_DOWNLOAD_WORKER" in
    yes:no|no:no|no:yes) ;;
    *)
      echo "error: MUSE_DOWNLOAD_DETACH and MUSE_DOWNLOAD_WORKER must describe a blocking, detached, or worker invocation" >&2
      return 2
      ;;
  esac

  for command in hf sha256sum stat flock; do
    command -v "$command" >/dev/null 2>&1 || {
      echo "error: required Nix-managed command is unavailable: $command" >&2
      echo "apply the desktop NixOS configuration before downloading" >&2
      return 1
    }
  done

  token_file="$HOME/.config/hf/token"
  if [ -f "$token_file" ]; then
    token_mode="$(stat -c %a "$token_file")"
    if ((8#$token_mode & 8#077)); then
      echo "error: Hugging Face token file must not be group/world-accessible: $token_file" >&2
      return 1
    fi
    export HF_TOKEN_PATH="$token_file"
  else
    echo "note: no HF token at $token_file - downloading unauthenticated (lower rate limits)" >&2
  fi

  if ! mkdir -p "$MUSE_TARGET_HOST" "$MUSE_DRAFT_HOST" 2>/dev/null; then
    sudo mkdir -p "$MUSE_TARGET_HOST" "$MUSE_DRAFT_HOST"
  fi
  if [ ! -w "$MUSE_TARGET_HOST" ] || [ ! -w "$MUSE_DRAFT_HOST" ]; then
    sudo chown "$INFERENCE_OPERATOR_USER:$INFERENCE_OPERATOR_GROUP" \
      "$MUSE_TARGET_HOST" "$MUSE_DRAFT_HOST"
  fi

  state_dir="$INFERENCE_OPERATOR_HOME/.local/state/creative-model-downloads"
  if [ "$MUSE_DOWNLOAD_DETACH" = yes ]; then
    mkdir -p "$state_dir"
    log_file="$state_dir/muse-$MUSE_VARIANT.log"
    nohup env \
      MUSE_DOWNLOAD_WORKER=yes \
      MUSE_DOWNLOAD_DETACH=no \
      MUSE_VARIANT="$MUSE_VARIANT" \
      MUSE_MODELS_ROOT="$MUSE_RESOLVED_MODEL_ROOT" \
      bash "$0" >"$log_file" 2>&1 </dev/null &
    worker_pid=$!
    echo "DOWNLOAD_STARTED: Muse '$MUSE_VARIANT' worker PID $worker_pid."
    echo "Follow: tail -f $log_file"
    return 0
  fi

  download_muse_models "$state_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
