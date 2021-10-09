{ pkgs, config, lib, ... }:
{
  hardware.bluetooth = {
    enable = true;
    settings = {
      General = {
        Enable = "Source,Sink,Media,Socke";
      };
    };
  };
  hardware.pulseaudio.package = pkgs.pulseaudioFull;
}
