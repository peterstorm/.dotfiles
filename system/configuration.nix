# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
      #./cachix.nix
    ];

  # enable flakes
  nix = {
    package = pkgs.nixUnstable;
    extraOptions = ''
      experimental-features = nix-command flakes
    '';
   };

  ## unfree packages
  nixpkgs.config.allowUnfree = true;

  # Use the systemd-boot EFI boot loader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.
  networking.hostName = "laptop-xps"; # Define your hostname.
  networking.networkmanager.enable = true;

  # The global useDHCP flag is deprecated, therefore explicitly set to false here.
  # Per-interface useDHCP will be mandatory in the future, so this generated config
  # replicates the default behaviour.
  networking.useDHCP = false;
  #networking.interfaces.enp6s0.useDHCP = true;
  #networking.interfaces.wlp5s0.useDHCP = true;

  # maybe this will enable wifi again?
  hardware.enableRedistributableFirmware = true;
  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # enable bluetooth
  hardware.bluetooth.enable = true;

  # Select internationalisation properties.
  # i18n.defaultLocale = "en_US.UTF-8";
  # console = {
  #   font = "Lat2-Terminus16";
  #   keyMap = "us";
  # };

  # enable docker
  virtualisation.docker.enable = true;

  # Dell XPS Settings
  services.thermald.enable = true;
  boot.kernelPatches = [{
    name = "enable-soundwire-drivers";
    patch = null;
    extraConfig = ''
      SND_SOC_INTEL_USER_FRIENDLY_LONG_NAMES y
      SND_SOC_INTEL_SOUNDWIRE_SOF_MACH m
      SND_SOC_RT1308 m
    '';
    ignoreConfigErrors = true;
  }];


  # enable xcape mapping to use capslock as hyper key
  systemd.services.xcape = {
    description = "xcape daemon";
    after = [ "graphical.target" ];
    wantedBy = [ "default.target" ];
    serviceConfig = {
      User = "peterstorm";
      ExecStart = ''
        /run/current-system/sw/bin/xcape -e ''\"Hyper_L=Caps_Lock;Hyper_R=backslash''\"
      '';
      Restart = "always";
      Type = "forking";
      Environment = "DISPLAY=:0";
      RestartSec = "1";
    };
  };

  # Set your time zone.
  time.timeZone = "Europe/Copenhagen";

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # nvim stuff
    (import ./vim.nix)
    pkgs.python3Packages.pynvim
    pkgs.vimPlugins.vim-plug
    nodejs-12_x
    # terminal
    alacritty
    # browser
    firefox
    # nix-shell stuff
    niv
    cachix
    # utils
    autorandr
    ffmpeg
    glances
    mosh
    git
    gitAndTools.gh
    starship
    tmux
    ripgrep
    unzip
    wget
    curl
    kube3d
    kubectl
    kubernetes-helm
    skaffold
    # chat
    slack
    element-desktop
    discord
    # xmonad stuff
    dmenu
    haskellPackages.xmobar
    xcape # key-remap
    # media
    vlc
    spotify
  ];

  environment.interactiveShellInit = ''
    eval "$(starship init bash)"
    alias m='mosh peterstorm@167.86.86.136'
    alias n='nvim'
    alias c='cd /etc/nixos/'
    alias k='k3d cluster create dev --port 8080:80@loadbalancer --port 8443:443@loadbalancer --image rancher/k3s:v1.21.0-k3s1'
    alias kc='export KUBECONFIG="$(k3d kubeconfig write dev)"'
        '';

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  #   pinentryFlavor = "gnome3";
  # };
  fonts.fonts = with pkgs; [
    fira-code
    fira-code-symbols
    ubuntu_font_family
  ];
  fonts.enableDefaultFonts = true;
  fonts.fontconfig = {
    defaultFonts = {
      serif = [ "Ubuntu" ];
      sansSerif = [ "Ubuntu" ];
      monospace = [ "Ubuntu" ];
    };
  };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # Open ports in the firewall.
  # networking.firewall.allowedTCPPorts = [ ... ];
  # networking.firewall.allowedUDPPorts = [ ... ];
  # Or disable the firewall altogether.
  # networking.firewall.enable = false;

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  sound.enable = true;
  hardware.pulseaudio.enable = true;

  # Enable the X11 windowing system.
  services.xserver.enable = true;
  services.xserver.layout = "us";
  services.xserver.xkbOptions = "caps:none, caps:hyper";
  # services.xserver.videoDrivers = [ "nvidia" ];
  services.xserver.windowManager = {
    xmonad.enable = true;
    xmonad.enableContribAndExtras = true;
    xmonad.extraPackages = haskellPackages: [
      haskellPackages.xmonad-contrib
      haskellPackages.xmonad-extras
      haskellPackages.xmonad
    ];
  };
  services.xserver.displayManager.defaultSession = "none+xmonad";


  # Enable touchpad support.
  services.xserver.libinput.enable = true;

  # Enable the KDE Desktop Environment.
  services.xserver.displayManager.sddm.enable = true;
  services.xserver.desktopManager.plasma5.enable = true;

  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users.peterstorm = {
    isNormalUser = true;
    initialPassword = "HelloWorld";
    extraGroups = [ "wheel" "docker" ]; # Enable ‘sudo’ for the user.
  };

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "21.05"; # Did you read the comment?

}


