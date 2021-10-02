{ pkgs, config, lib, ... }:
{
  services.thermald.enable = lib.mkDefault true;
  powerManagement.cpuFreqGovernor = lib.mkDefault "powersave";
}
