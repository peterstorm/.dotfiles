#!/usr/bin/env bash
# Safely start/stop the GLM-5.3 v17 Hyperflare TP2 test profile (upstream
# Hyperflare + hyperflare-recipes PR #55 + FlashInfer PR #151). PREFILL picks the
# core (rowshard, default, or the baseline control) and is exported to the run
# script. The transaction is v16's (hyperflare-switch.sh): launch at restart=no,
# accept only a boot that is healthy, authenticated, serves exactly the v17 id,
# decodes the asked-for word and shows on the :8011 bridge, then promote; on any
# failure restore whatever profile set ran before (normally a primary).
#
#   switch-glm53-hyperflare-tp2-v17.sh {status|start|stop}
#   PREFILL=baseline switch-glm53-hyperflare-tp2-v17.sh start
#
# Back to a primary afterwards: stop this profile, then switch-primary.sh glm
# (or uncensored). switch-primary refuses while a non-primary catalog profile such
# as this one holds the GPUs, so the stop is deliberate, never implied.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
# shellcheck source=scripts/inference/glm53/glm53-v17-hyperflare/pins.sh
source "$SCRIPT_DIR/glm53-v17-hyperflare/pins.sh"
# shellcheck source=scripts/inference/glm53/hyperflare-switch.sh
source "$SCRIPT_DIR/hyperflare-switch.sh"

# Exported: the run script this starts must serve the same core.
PREFILL="$(v17_resolve_prefill "${PREFILL:-rowshard}")" || exit 2
export PREFILL
TARGET="$V17_CONTAINER"
EXPECTED_MODEL="$V17_SERVED_MODEL"
RUN="$SCRIPT_DIR/run-glm53-flash-hyperflare-tp2-v17.sh"
BOOT_RECEIPT="${BOOT_RECEIPT:-$HOME/.local/state/glm53/flash-hyperflare-tp2-v17-$PREFILL-boot-receipt.txt}"
PROFILE_LABEL="v17-$PREFILL"
MODE="${1:-status}"

if ! (return 0 2>/dev/null); then
  hyperflare_switch_main
fi
