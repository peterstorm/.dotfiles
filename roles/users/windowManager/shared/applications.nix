{pkgs, config, lib, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  home.packages = with pkgs;[
    firefox
    google-chrome
    element-desktop
    discord
    neovim
  ];
}

