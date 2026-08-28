#!/usr/bin/env bash
# Start the complete expressive-voice download transaction as a detached user unit.
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOWNLOADER="$ROOT/scripts/inference/voice/download-expressive-voice-contenders.sh"
UNIT="expressive-voice-contender-download"
MODELS_ROOT="${VOICE_MODELS_ROOT:-/models/voice}/expressive-contenders"
LOG="$MODELS_ROOT/download.log"

command -v systemd-run >/dev/null 2>&1 || { echo 'error: systemd-run is required' >&2; exit 1; }
[[ -x "$DOWNLOADER" ]] || { echo "error: downloader is not executable: $DOWNLOADER" >&2; exit 1; }
mkdir -p "$MODELS_ROOT"

if systemctl --user is-active --quiet "$UNIT.service"; then
  echo "EXPRESSIVE_VOICE_DOWNLOAD_ALREADY_ACTIVE: $UNIT.service"
  exit 0
fi
systemctl --user reset-failed "$UNIT.service" 2>/dev/null || true

systemd-run --user \
  --unit="$UNIT" \
  --collect \
  --property=Type=exec \
  --property=Restart=on-failure \
  --property=RestartSec=30s \
  --property="StandardOutput=append:$LOG" \
  --property="StandardError=append:$LOG" \
  --setenv="VOICE_MODELS_ROOT=${VOICE_MODELS_ROOT:-/models/voice}" \
  --setenv=EXPRESSIVE_VOICE_ACCEPT_RESTRICTED_LICENSES=yes \
  --setenv=EXPRESSIVE_VOICE_DOWNLOAD_AUTHORIZATION=user-request-2026-08-28 \
  --setenv=HF_HUB_DISABLE_XET=0 \
  "$DOWNLOADER"

printf 'EXPRESSIVE_VOICE_DOWNLOAD_STARTED: unit=%s.service log=%s\n' "$UNIT" "$LOG"
