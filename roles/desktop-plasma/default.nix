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
      # Without `config` the none+xmonad session runs STOCK XMonad: Alt-based
      # default bindings, and none of the custom Super-based ones — including
      # the Super+Ctrl+R / Super+Shift+R recompile/restart shortcuts. Install
      # the shared config (same file the desktop gets via the home-manager
      # desktop profile) so the session loads it.
      config = ../home-manager/window-manager/xmonad/xmonad.hs;
    };
  };

  # The custom xmonad.hs launches `xmobar` for the top bar.
  programs.xmobar.enable = true;

  # Escape hatches for a config-less XMonad fallback: if the recompile ever
  # fails, stock XMonad's Alt+Shift+Return (xterm) and Alt+p (dmenu) are the
  # only way in — leaving them broken is not worth the two packages.
  environment.systemPackages = with pkgs; [ xterm dmenu ];

}

