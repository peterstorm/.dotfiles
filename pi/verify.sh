#!/usr/bin/env bash
# Run the Pi agent install verification.
#
# The extensions import "@earendil-works/pi-coding-agent", which ships inside
# pi's own Nix store closure — nothing in this repo provides that specifier, and
# the store path changes with every pi version. Derive it from the pi on PATH
# rather than pinning it.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"

pi_bin="$(command -v pi)" || { echo "pi is not on PATH" >&2; exit 1; }
pi_root="$(dirname "$(dirname "$(readlink -f "$pi_bin")")")"
sdk="$pi_root/lib/node_modules"
[ -d "$sdk/@earendil-works" ] || { echo "no Pi SDK under $sdk" >&2; exit 1; }

export NODE_PATH="$sdk:$sdk/@earendil-works/pi-coding-agent/node_modules"

if [ "${1:-}" = "--tests" ]; then
  shift
  links="$here/../node_modules"
  mkdir -p "$links/@earendil-works"
  ln -sfn "$sdk/@earendil-works/pi-coding-agent" "$links/@earendil-works/pi-coding-agent"
  ln -sfn "$sdk/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-ai" "$links/@earendil-works/pi-ai"
  ln -sfn "$sdk/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-agent-core" "$links/@earendil-works/pi-agent-core"
  ln -sfn "$sdk/@earendil-works/pi-coding-agent/node_modules/@earendil-works/pi-tui" "$links/@earendil-works/pi-tui"
  ln -sfn "$sdk/@earendil-works/pi-coding-agent/node_modules/typebox" "$links/typebox"
  cleanup() {
    rm -f \
      "$links/@earendil-works/pi-coding-agent" \
      "$links/@earendil-works/pi-ai" \
      "$links/@earendil-works/pi-agent-core" \
      "$links/@earendil-works/pi-tui" \
      "$links/typebox"
    rmdir "$links/@earendil-works" 2>/dev/null || true
  }
  trap cleanup EXIT
  bun test \
    "$here/extensions/model-routing" \
    "$here/extensions/subagent" \
    "$here/extensions/loom-rules-gate/shell.test.ts" \
    "$here/root-extensions.test.ts" \
    "$here/creative-project-skills.test.ts" \
    "$@"
  exit $?
fi

exec bun "$here/verify-agent-install.ts" "$@"
