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
  ];

  home.packages = with pkgs;[
    firefox
    google-chrome
    gparted
    element-desktop
    discord
    slack
  ];
}

