{config, pkgs, lib, ...}:
{
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services.xserver = {
    enable = true;
    layout = "us";
    xkbOptions = "caps:none";
    displayManager = {
      sddm.enable = true;
      defaultSession = "none+xmonad";
    };
    libinput.enable = true;
    windowManager.xmonad = {
      enable = true;
      enableContribAndExtras = true;
    };
    desktopManager = {
      plasma5.enable = true;
    };
  };

}

