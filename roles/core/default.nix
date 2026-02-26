{inputs, config, pkgs, lib, ...}:

{
  nix = {
    extraOptions = "experimental-features = nix-command flakes";
    gc = {
      automatic = true;
      options = "--delete-older-than 10d";
    };
    package = pkgs.nixVersions.latest;
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

  users.mutableUsers = false;

  security.sudo.extraRules = [{
    users = [ "peterstorm" ];
    commands = [
      { command = "/run/current-system/sw/bin/nixos-rebuild"; options = [ "NOPASSWD" ]; }
    ];
  }];

  virtualisation.docker.enable = true;


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
    parted
    kubernetes-helm # Shell
    k3d
    ripgrep
    gcc
    sops
    age
  ];

  imports = [
    inputs.sops-nix.nixosModules.sops
  ];

  # Configure sops age key location
  sops.age.keyFile = "/var/lib/sops-nix/keys.txt";
}

