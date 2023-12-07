{config, pkgs, lib, ...}:

{
  nix = {
    extraOptions = "experimental-features = nix-command flakes";
    gc = {
      automatic = true;
      options = "--delete-older-than 10d";
    };
    package = pkgs.nixUnstable;
    settings = {
      trusted-public-keys = [
        "undo-foundation.cachix.org-1:BSP9SjfX89JXxs2QXF9qxTYBlTSG3ad4N7V4HSlH9s0="
        "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
      ];
      substituters = [
        "https://undo-foundation.cachix.org"
        "https://cache.iog.io"
      ];
    };
  };

  time.timeZone = "Europe/Copenhagen";
  i18n.defaultLocale = "en_US.UTF-8";

  hardware.enableRedistributableFirmware = lib.mkDefault true;

  documentation.info.enable = false;

  virtualisation.docker.enable = true;

  environment.interactiveShellInit = ''
    if [ -z "$SSH_AUTH_SOCK" ] ; then
      eval `ssh-agent -s`
      ssh-add
    fi
    eval "$(direnv hook bash)"
    eval "$(starship init bash)"
    alias lock='i3lock -c 000000'
    alias sus='systemctl suspend'
  '';

  environment.systemPackages = with pkgs; [
    # Core utilities that need to be on every machine
    openvpn
    cloudflared
    k3s
    iptables
    terraform
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
    kubernetes-helm # Shell
    kube3d
    ripgrep
    gcc
  ];
}

