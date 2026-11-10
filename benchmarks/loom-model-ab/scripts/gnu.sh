#!/usr/bin/env bash
# Run any command with GNU bash >= 4 and GNU coreutils/sed/grep/find first
# on PATH. The harness was written for the Linux desktop (mapfile, `date -Is`,
# `realpath -e`, `timeout`); macOS ships bash 3.2 and BSD tools. Nix supplies
# the same toolchain offline, so the harness runs unchanged on either host.
#
#   bash scripts/gnu.sh bash scripts/verify-harness.sh
#   bash scripts/gnu.sh bash scripts/run-arm.sh --probe ds41
set -euo pipefail

(($# > 0)) || { echo "usage: $0 <command> [args...]" >&2; exit 2; }

if [[ "$(uname -s)" == Linux ]]; then
  exec "$@"
fi

exec nix --extra-experimental-features 'nix-command flakes' shell --offline \
  nixpkgs#bash nixpkgs#coreutils nixpkgs#gnused nixpkgs#gnugrep \
  nixpkgs#findutils -c "$@"
