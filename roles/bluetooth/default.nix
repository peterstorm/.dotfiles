{ pkgs, config, lib, ... }:
{
  hardware.bluetooth = {
    enable = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socket";
      };
    };
  };
  services.pulseaudio.package = pkgs.pulseaudioFull;
}
