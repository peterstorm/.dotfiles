#!/usr/bin/env bash
# Contract for the headless boot-pin selector and its use in system-apply.sh.
#
# The selector decides which boot entry the persistent EFI pin names. The
# desktop has no unattended reboot test, and a wrong pick is only visible after
# the next boot, so the selection is pinned here against fixture entry
# directories — including the graphical specialisation, which shares the same
# version string and must never be picked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SELECTOR="$ROOT/scripts/boot-pin-entry.sh"
APPLY="$ROOT/system-apply.sh"
DOC="$ROOT/docs/runbooks/gaming-desktop.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

entry() { # entry <filename> <title> <generation>
  cat >"$tmp/$1" <<EOF
title $2
version Generation $3 NixOS Zokor 26.11.20261103.1d06008 (Linux 6.18.60), built on 2026-11-12
linux /EFI/nixos/linux.efi
options init=/nix/store/x-nixos-system-desktop/init root=fstab
EOF
}

entry nixos-aaa.conf 'NixOS' 78
entry nixos-bbb.conf 'NixOS' 79
entry nixos-ccc.conf 'NixOS (graphical)' 79
entry nixos-ddd.conf 'NixOS' 80
# Decoys: a prefix collision on the generation number, and the same generation
# under a title that is not the headless entry.
entry nixos-eee.conf 'NixOS' 790
entry nixos-fff.conf 'NixOS 79 (recovery)' 79

selected=$("$SELECTOR" 79 "$tmp")
[ "$selected" = "nixos-bbb.conf" ] ||
  fail "generation 79 selected '$selected' (want the headless nixos-bbb.conf)"

selected=$("$SELECTOR" 78 "$tmp")
[ "$selected" = "nixos-aaa.conf" ] || fail "generation 78 selected '$selected'"

if "$SELECTOR" 81 "$tmp" >/dev/null; then
  fail "a generation with no headless entry must fail, not fall back"
fi

if "$SELECTOR" 79 "$tmp/missing" >/dev/null 2>&1; then
  fail "a missing entry directory must fail"
fi

if "$SELECTOR" '79.conf' "$tmp" >/dev/null 2>&1; then
  fail "a non-numeric generation must be rejected"
fi

grep -Fq 'scripts/boot-pin-entry.sh' "$APPLY" ||
  fail "system-apply.sh no longer uses scripts/boot-pin-entry.sh"
grep -Fq 'pin_rc=1' "$APPLY" ||
  fail "system-apply.sh does not fail when the EFI pin cannot be moved"
if grep -Fq 'jq ' "$APPLY"; then
  fail "system-apply.sh depends on jq again; a missing jq silently froze the EFI pin"
fi
grep -Fq 'EFI pin' "$APPLY" ||
  fail "system-apply.sh does not verify the EFI pin it wrote"
contains_doc='a manual `switch-to-configuration` must re-pin by hand'
grep -Fq -- "$contains_doc" "$DOC" ||
  fail "docs/runbooks/gaming-desktop.md lost the manual re-pin caveat"

printf 'PASS: the EFI boot pin always moves to the newest generation headless entry\n'
