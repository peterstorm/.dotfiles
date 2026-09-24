{ pkgs, ... }:
{
  # Steam's NixOS module provides the FHS runtime, 32-bit graphics/audio and
  # controller udev rules. Installing pkgs.steam through home-manager alone
  # does not set up those host-side pieces.
  programs.steam = {
    enable = true;
    protontricks.enable = true;
    # Steam offers Valve Proton itself; expose a pinned GE-Proton alongside it.
    extraCompatPackages = [ pkgs.proton-ge-bin ];
  };

  programs.gamemode.enable = true;

  # LUG Helper's Star Citizen preflight requires at least this many VMAs.
  boot.kernel.sysctl."vm.max_map_count" = 16777216;

  environment.systemPackages = with pkgs; [
    (lutris.override {
      extraPkgs = pkgs: with pkgs; [
        wineWow64Packages.stable
        winetricks
      ];
    })
    lug-helper
    mangohud
    vulkan-tools
  ];
}
