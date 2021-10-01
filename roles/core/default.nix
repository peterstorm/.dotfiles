{config, pkgs, lib, ...}:

{

  nix = {
    extraOptions = "experimental-features = nix-command flakes";
    gc = {
      automatic = true;
      options = "--delete-older-than 5d";
    };
    package = pkgs.nixUnstable;
  };

  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_US.UTF-8";

  console = {
    font = "Ubuntu";
    keyMap = "us";
  }

  hardware.enableRedistributableFirmware = lib.mkDefault true;

  # Hot fix for issues
  documentation.info.enable = false;

  virtualisation.docker.enable = true;

  environment.systemPackages = with pkgs; [

    # Core utilities that need to be on every machine
    wget
    curl
    killall
    htop
    unzip
    zip
    git
    git-crypt
    tmux
    unrar
    gitAndTools.gh
    parted
    kubectl # Should be moved to shell
    kubernetes-helm # Shell
    kube3d
    ripgrep
  ];
}

