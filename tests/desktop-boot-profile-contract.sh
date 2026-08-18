#!/usr/bin/env bash
# Declarative contract for the desktop's headless-default boot profiles.
# shellcheck disable=SC2016 # Assertions intentionally match literal Markdown.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/runbooks/new-desktop-install.md"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

contains() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "$file does not contain: $text"
}

contract="$({
  cd "$ROOT"
  nix eval --json \
    --apply 'desktop: let cfg = desktop.config; in {
      baseDefault = cfg.systemd.defaultUnit;
      baseModesetting = cfg.hardware.nvidia.modesetting.enable;
      graphicalDefault = cfg.specialisation.graphical.configuration.systemd.defaultUnit;
      graphicalModesetting = cfg.specialisation.graphical.configuration.hardware.nvidia.modesetting.enable;
      graphicalDisplayManager = cfg.services.displayManager.sddm.enable;
      specialisations = builtins.attrNames cfg.specialisation;
    }' \
    .#nixosConfigurations.desktop
})"

jq -e '
  .baseDefault == "multi-user.target" and
  .baseModesetting == false and
  .graphicalDefault == "graphical.target" and
  .graphicalModesetting == true and
  .graphicalDisplayManager == true and
  .specialisations == ["graphical"]
' <<<"$contract" >/dev/null || fail "desktop boot profile contract does not match: $contract"

contains "$DOC" '| `NixOS` (default) | `multi-user.target`'
contains "$DOC" '| `NixOS (graphical)` | `graphical.target`'
contains "$DOC" './system-apply.sh --specialisation graphical'

printf 'PASS: desktop defaults to headless and preserves the graphical specialisation\n'
