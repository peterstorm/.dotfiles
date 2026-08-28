#!/usr/bin/env bash
# Start the complete expressive-voice download transaction in a detached tmux session.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOWNLOADER="$ROOT/scripts/inference/voice/download-expressive-voice-contenders.sh"
SESSION="expressive-voice-contender-download"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"
LOG="$MODELS_ROOT/download.log"

command -v tmux >/dev/null 2>&1 || { echo 'error: tmux is required' >&2; exit 1; }
[[ -x "$DOWNLOADER" ]] || { echo "error: downloader is not executable: $DOWNLOADER" >&2; exit 1; }
mkdir -p "$MODELS_ROOT"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  pane_dead="$(tmux display-message -p -t "$SESSION:0.0" '#{pane_dead}')"
  if [[ "$pane_dead" == 0 ]]; then
    echo "EXPRESSIVE_VOICE_DOWNLOAD_ALREADY_ACTIVE: tmux=$SESSION"
    exit 0
  fi
  tmux kill-session -t "$SESSION"
fi

printf -v command 'exec env VOICE_MODELS_ROOT=%q EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28 HF_HUB_DISABLE_XET=0 %q >>%q 2>&1' \
  "${VOICE_MODELS_ROOT:-/models/voice}" "$DOWNLOADER" "$LOG"
tmux new-session -d -s "$SESSION" "$command"
tmux set-option -t "$SESSION" remain-on-exit on >/dev/null

printf 'EXPRESSIVE_VOICE_DOWNLOAD_STARTED: tmux=%s log=%s\n' "$SESSION" "$LOG"
