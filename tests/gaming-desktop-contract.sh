#!/usr/bin/env bash
# Gaming must be opt-in on desktop, never an accidental inference/remote-host dependency.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

contract="$(nix eval --json --apply 'host: let
  base = host.config;
  graphical = base.specialisation.graphical.configuration;
  names = ps: builtins.map (p: p.pname or p.name or "") ps;
  has = name: ps: builtins.elem name (names ps);
in {
  base = {
    steam = base.programs.steam.enable;
    gamemode = base.programs.gamemode.enable;
    mapCount = base.boot.kernel.sysctl."vm.max_map_count";
    lugHelper = has "lug-helper" base.environment.systemPackages;
  };
  graphical = {
    steam = graphical.programs.steam.enable;
    protontricks = graphical.programs.steam.protontricks.enable;
    ge = has "proton-ge-bin" graphical.programs.steam.extraCompatPackages;
    gamemode = graphical.programs.gamemode.enable;
    graphics32 = graphical.hardware.graphics.enable32Bit;
    mapCount = graphical.boot.kernel.sysctl."vm.max_map_count";
    lutris = has "lutris" graphical.environment.systemPackages;
    lugHelper = has "lug-helper" graphical.environment.systemPackages;
    mangohud = has "mangohud" graphical.environment.systemPackages;
    vulkanTools = has "vulkan-tools" graphical.environment.systemPackages;
  };
}' .#nixosConfigurations.desktop)"

jq -e '
  .base.steam == false and .base.gamemode == false and .base.lugHelper == false and
  .base.mapCount != .graphical.mapCount and
  .graphical == {
    steam: true, protontricks: true, ge: true, gamemode: true,
    graphics32: true, mapCount: 16777216, lutris: true,
    lugHelper: true, mangohud: true, vulkanTools: true
  }
' <<<"$contract" >/dev/null || { echo "Gaming specialisation contract failed: $contract" >&2; exit 1; }

for host in laptop-xps laptop-work homelab; do
  enabled="$(nix eval --raw --apply 'host: if host.config.programs.steam.enable then "true" else "false"' ".#nixosConfigurations.$host")"
  [[ "$enabled" == false ]] || { echo "Steam unexpectedly enabled on $host" >&2; exit 1; }
done

printf 'PASS: gaming is limited to desktop graphical specialisation\n'
