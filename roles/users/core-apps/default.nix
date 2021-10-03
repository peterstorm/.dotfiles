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
  ];

  home.packages = with pkgs;[
    firefox
    google-chrome
    element-desktop
    discord
    neovim
  ];
}

