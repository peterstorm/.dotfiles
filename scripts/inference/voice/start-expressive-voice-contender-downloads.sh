#!/usr/bin/env bash
# Start every expressive-voice model closure in its own detached tmux lane.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOWNLOADER="$ROOT/scripts/inference/voice/download-expressive-voice-contenders.sh"
SESSION="expressive-voice-contender-download"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"
MANIFEST="$ROOT/scripts/inference/voice/expressive-voice-contenders.manifest.tsv"
mapfile -t PROFILES < <(awk -F '\t' '$1 == "profile" { print $2 }' "$MANIFEST")
(( ${#PROFILES[@]} > 0 )) || { echo "error: no profiles in $MANIFEST" >&2; exit 1; }

profile_command() {
  local profile="$1" command
  local log="$MODELS_ROOT/download-$profile.log"
  printf -v command 'exec env VOICE_MODELS_ROOT=%q EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28 %q %q >>%q 2>&1' \
    "${VOICE_MODELS_ROOT:-/models/voice}" "$DOWNLOADER" "$profile" "$log"
  printf '%s\n' "$command"
}

command -v tmux >/dev/null 2>&1 || { echo 'error: tmux is required' >&2; exit 1; }
[[ -x "$DOWNLOADER" ]] || { echo "error: downloader is not executable: $DOWNLOADER" >&2; exit 1; }
mkdir -p "$MODELS_ROOT"

if tmux has-session -t "$SESSION" 2>/dev/null; then
  if tmux list-panes -s -t "$SESSION" -F '#{pane_dead}' | grep -Fxq 0; then
    echo "EXPRESSIVE_VOICE_DOWNLOAD_ALREADY_ACTIVE: tmux=$SESSION"
    exit 0
  fi
  tmux kill-session -t "$SESSION"
fi

for index in "${!PROFILES[@]}"; do
  profile="${PROFILES[$index]}"
  command="$(profile_command "$profile")"
  if [[ "$index" == 0 ]]; then
    tmux new-session -d -s "$SESSION" -n "$profile" "$command"
  else
    tmux new-window -d -t "$SESSION" -n "$profile" "$command"
  fi
done
tmux set-option -t "$SESSION" remain-on-exit on >/dev/null

printf 'EXPRESSIVE_VOICE_DOWNLOAD_STARTED: tmux=%s lanes=%s logs=%s/download-<profile>.log\n' \
  "$SESSION" "${#PROFILES[@]}" "$MODELS_ROOT"
