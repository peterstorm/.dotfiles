{pkgs, config, lib, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  programs.ssh = {
    enable = true;
    matchBlocks = {
      homelab = {
        hostname = "192.168.0.28";
        user = "peterstorm";
      };
    };
  };

  imports = [
    ./git
    ./tmux
    ./alacritty
    ./starship
    ./neovim
    ./nix-direnv
  ];

  home.packages = with pkgs;[
    gh
    vscode
    cloudflare-warp
    cachix
    firefox
    google-chrome
    gparted
    element-desktop
    discord
    slack
    vlc
    i3lock
    zoom-us
    obsidian
    docker-compose
    light
    claude-code
  ];

}

