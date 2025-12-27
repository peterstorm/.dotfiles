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

  services.libinput = {
    enable = true;
    touchpad.disableWhileTyping = true;
    touchpad.tapping = true;
    touchpad.additionalOptions = ''
        Option "PalmDetection" "on"
    '';
  };

  services.displayManager = {
      defaultSession = "none+xmonad";
      sddm.enable = true;
  };

  services.xserver = {
    enable = true;
    xkb = {
        layout = "us";
        options = "ctrl:swapcaps";
    };
    displayManager = {
      setupCommands = ''
        ${pkgs.xorg.xrandr}/bin/xrandr --dpi 144;
      '';
    };
    windowManager.xmonad = {
      enable = true;
      enableContribAndExtras = true;
    };
  };

}

