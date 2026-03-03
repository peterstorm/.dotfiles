{ pkgs, config, lib, ... }:
{
  services.thermald.enable = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
  programs.light.enable = true;
  hardware.graphics = {
    enable32Bit = true;
  };
}
