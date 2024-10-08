{config, pkgs, lib, ...}:
{
  hardware.pulseaudio.enable = false;

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;
  };

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
      setupCommands = ''
        ${pkgs.xorg.xrandr}/bin/xrandr --dpi 144;
      '';
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

