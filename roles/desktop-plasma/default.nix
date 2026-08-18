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
      # The custom config is deliberately NOT here: it is home-manager managed
      # — each laptop's NixOS config integrates the window-manager/xmonad role
      # via home-manager.users (applied atomically by nixos-rebuild switch),
      # which installs and compiles ~/.xmonad/xmonad.hs and enables xmobar
      # (home-manager's own module — nixpkgs dropped its NixOS one). NixOS
      # provides the session, HM owns the config. Without it the none+xmonad
      # session runs STOCK XMonad: Alt-based defaults, none of the Super
      # bindings or the recompile/restart shortcuts.
    };
  };

  # Escape hatches for a config-less XMonad fallback: if the recompile ever
  # fails, stock XMonad's Alt+Shift+Return (xterm) and Alt+p (dmenu) are the
  # only way in — leaving them broken is not worth the two packages.
  environment.systemPackages = with pkgs; [ xterm dmenu ];

}

