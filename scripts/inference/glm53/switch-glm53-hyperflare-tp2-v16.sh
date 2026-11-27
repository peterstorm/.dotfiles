#!/usr/bin/env bash
# Safely start/stop a GLM-5.3 Hyperflare TP2 profile: v16 by default, or the
# uncensored build with VARIANT=uncensored (hyperflare-variants.sh derives the
# container, served id, receipt and checkpoint from the variant, and the run
# script reads the same exported VARIANT). switch-primary.sh calls this for the
# `glm` and `uncensored` primaries.
# The rollback target is whatever profile set was running before (normally
# ds41-1017-native). The v15 qad2 checkpoint was deleted on 2026-11-13 to make
# room for the FP4-Local checkpoint and the Hyperflare package, so v15 needs
# its download before it can serve again.
# Launch is transactional at restart=no; only a fully accepted boot (healthy,
# authenticated, exact model id, the asked-for word decoded, bridge on :8011 translating)
# is promoted to restart=unless-stopped. The transaction is hyperflare-switch.sh,
# shared with the v17 switcher; this file says what it serves.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/inference/shared/inference-api-key.sh
source "$SCRIPT_DIR/../shared/inference-api-key.sh"
# shellcheck source=scripts/inference/shared/inference-profile-catalog.sh
source "$SCRIPT_DIR/../shared/inference-profile-catalog.sh"
# shellcheck source=scripts/inference/glm53/hyperflare-variants.sh
source "$SCRIPT_DIR/hyperflare-variants.sh"
# shellcheck source=scripts/inference/glm53/hyperflare-switch.sh
source "$SCRIPT_DIR/hyperflare-switch.sh"

# Exported: the run script this starts must serve the same variant.
VARIANT="${VARIANT:-v16}"
hyperflare_resolve_model "$VARIANT" >/dev/null || exit 2
export VARIANT
TARGET="$(hyperflare_variant_container "$VARIANT")"
EXPECTED_MODEL="$(hyperflare_variant_served "$VARIANT")"
RUN="$SCRIPT_DIR/run-glm53-flash-hyperflare-tp2-v16.sh"
BOOT_RECEIPT="${BOOT_RECEIPT:-$HOME/.local/state/glm53/flash-hyperflare-tp2-$VARIANT-boot-receipt.txt}"
PROFILE_LABEL="$VARIANT"
MODE="${1:-status}"

# Run only when executed, never when sourced: `return` succeeds only in a sourced
# file, whatever $0 is. Sourcing defines the functions only
# (tests/switch-glm53-hyperflare-receipt-unit.sh).
if ! (return 0 2>/dev/null); then
  hyperflare_switch_main
fi
