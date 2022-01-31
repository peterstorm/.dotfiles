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
  hardware.pulseaudio.package = pkgs.pulseaudioFull;
}
