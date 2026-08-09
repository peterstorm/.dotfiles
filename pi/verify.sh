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

export NODE_PATH="$sdk"
exec bun "$here/verify-agent-install.ts" "$@"
