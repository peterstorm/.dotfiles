#!/usr/bin/env bash
# Start all expressive-voice downloads in three balanced, detached tmux lanes.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOWNLOADER="$ROOT/scripts/inference/voice/download-expressive-voice-contenders.sh"
SESSION="expressive-voice-contender-download"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"

lane_command() {
  local log="$1"
  shift
  local command profile
  printf -v command 'exec env VOICE_MODELS_ROOT=%q EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28 HF_HUB_DISABLE_XET=0 %q' \
    "${VOICE_MODELS_ROOT:-/models/voice}" "$DOWNLOADER"
  for profile in "$@"; do
    printf -v command '%s %q' "$command" "$profile"
  done
  printf -v command '%s >>%q 2>&1' "$command" "$log"
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

lane_a="$(lane_command "$MODELS_ROOT/download-lane-a.log" \
  voxcpm2-32279eff higgs-tts3-7556c17e moss-tts-voice-acting-aabb7b60)"
lane_b="$(lane_command "$MODELS_ROOT/download-lane-b.log" \
  breeze-tts2-c1c8ca18 cosyvoice3-29e01c4e fish-s2-pro-1de9996b)"
lane_c="$(lane_command "$MODELS_ROOT/download-lane-c.log" \
  dramabox-404f967f dramabox-gemma-826e729d dramabox-reuse-76190506)"

tmux new-session -d -s "$SESSION" -n lane-a "$lane_a"
tmux new-window -d -t "$SESSION" -n lane-b "$lane_b"
tmux new-window -d -t "$SESSION" -n lane-c "$lane_c"
tmux set-option -t "$SESSION" remain-on-exit on >/dev/null

printf 'EXPRESSIVE_VOICE_DOWNLOAD_STARTED: tmux=%s lanes=3 logs=%s/download-lane-{a,b,c}.log\n' "$SESSION" "$MODELS_ROOT"
