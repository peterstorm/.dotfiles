{inputs, config, pkgs, lib, ...}:

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
        "hydra.iohk.io:f/Ea+s+dFdN+3Y/G+FDgSq+a5NEWhJGzdjvKNGv0/EQ="
        "miso-haskell.cachix.org-1:6N2DooyFlZOHUfJtAx1Q09H0P5XXYzoxxQYiwn6W1e8="

      ];
      substituters = [
        "https://cache.iog.io"
        "https://miso-haskell.cachix.org"
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
    alias warpc='warp-cli connect'
    alias warpd='warp-cli disconnect'
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

  imports = [
    inputs.sops-nix.nixosModules.sops
  ];
}

