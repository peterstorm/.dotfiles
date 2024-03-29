{pkgs, config, lib, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
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
    vscode
    konsole
    cloudflare-warp
    cachix
    firefox
    google-chrome
    gparted
    element-desktop
    discord
    slack
    torrential
    vlc
    i3lock
    zoom-us
    obsidian
    docker-compose
    light
  ];

}

