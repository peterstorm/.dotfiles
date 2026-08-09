{config, pkgs, lib, ...}:
{
  services.pulseaudio.enable = false;

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
        # Caps Lock acts as Ctrl (matches the laptops' desktop-plasma role).
        # XMonad uses mod4 (Super) as its modkey, so Caps is free to be Ctrl.
        options = "ctrl:swapcaps";
        layout = "us";

    };
    displayManager = {
      setupCommands = ''
          ${pkgs.xrandr}/bin/xrandr \
          --output DP-4 --mode 2560x1440 --rotate right --pos 0x0 \
          --output DP-6 --primary --mode 3840x1600 --pos 1440x750
      '';
    };
    windowManager.xmonad = {
      enable = true;
      enableContribAndExtras = true;
    };
  };

}
