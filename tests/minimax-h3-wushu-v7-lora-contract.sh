#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
DOWNLOADER="$ROOT/scripts/comfyui/download-minimax-h3-wushu-v7-lora.sh"
RUNBOOK="$ROOT/docs/runbooks/comfyui-krea2-minimax-h3-muse-runbook.md"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local file=$1 needle=$2
  grep -Fq -- "$needle" "$file" || fail "missing $(basename "$file") contract: $needle"
}

contains "$DOWNLOADER" 'REPO="Jojocodex/wushu-action-v7-minimax-h3-fl2va-ref2va-lora"'
contains "$DOWNLOADER" 'REV="9abd1a8ae5edf0c8a1aea541bfd58b778273ca6a"'
contains "$DOWNLOADER" 'SOURCE="wushu_action_v7_ref2va_aitoolkit_NO-ADALN_pruned-int8convrot_2000step.safetensors"'
contains "$DOWNLOADER" 'EXPECTED_SHA256="f070becda73c65a19a8204384db51bb8204d2303055852172c25aa699589326e"'
contains "$DOWNLOADER" 'EXPECTED_BYTES="310167928"'
contains "$DOWNLOADER" 'MINIMAX_H3_WUSHU_V7_RESEARCH_ONLY'
contains "$DOWNLOADER" 'license=upstream-other-no-production-grant-established'
contains "$DOWNLOADER" 'MINIMAX_H3_ACCEPT_LICENSE'
contains "$DOWNLOADER" 'MINIMAX_H3_AUTHORIZED'
contains "$RUNBOOK" 'Wushu Action V7 — private local qualification only'
contains "$RUNBOOK" 'strength **0.5**'
contains "$RUNBOOK" 'Do not import either upstream workflow'

if grep -Eq 'resolve/main|tree/main' "$DOWNLOADER"; then
  fail 'downloader contains a mutable Hugging Face URL'
fi

bash -n "$DOWNLOADER"
printf 'PASS: MiniMax H3 Wushu V7 is revision/checksum pinned and blocked from Production authority\n'
