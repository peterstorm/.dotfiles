{config, pkgs, lib, ...}:
{
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services.autorandr.enable = true;

  services.xserver = {
    enable = true;
    layout = "us";
    xkbOption = "caps:none, caps:hyper";
    displayManager.sddm.enable = true;
    desktopManager.plasma5.enable = true;
  };
}

