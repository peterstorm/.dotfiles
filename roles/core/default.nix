{config, pkgs, lib, ...}:

{
  imports = [
   ./cachix.nix
  ];
  nix = {
    extraOptions = "experimental-features = nix-command flakes";
    gc = {
      automatic = true;
      options = "--delete-older-than 5d";
    };
    package = pkgs.nixUnstable;
    settings = {
      trusted-public-keys = [
        "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      ];
      substituters = [
        "https://cache.iog.io"
      ];
    };
  };

  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_US.UTF-8";

  hardware.enableRedistributableFirmware = lib.mkDefault true;
  hardware.video.hidpi.enable = lib.mkDefault true;

  documentation.info.enable = false;

  virtualisation.docker.enable = true;

  environment.interactiveShellInit = ''
    eval "$(starship init bash)"
    alias lock='i3lock -c 000000'
    alias sus='systemctl suspend'
  '';

  environment.systemPackages = with pkgs; [
    # Core utilities that need to be on every machine
    wget
    xcape
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
    gcc
  ];
}

