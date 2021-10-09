{config, pkgs, lib, ...}:
{
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  services.xserver = {
    enable = true;
    layout = "us";
    libinput = {
      enable = true;
      touchpad.disableWhileTyping = true;
      touchpad.tapping = true;
      touchpad.additionalOptions = ''
        Option "PalmDetection" "on"
      '';
    };
    xkbOptions = "caps:hyper";
    displayManager = {
      defaultSession = "none+xmonad";
      sddm.enable = true;
    };
    windowManager.xmonad = {
      enable = true;
      enableContribAndExtras = true;
    };
    desktopManager = {
      plasma5.enable = true;
    };
  };

}

