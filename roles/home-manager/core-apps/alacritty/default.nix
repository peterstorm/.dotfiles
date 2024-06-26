{pkgs, lib, config, ...}:
{
  home.sessionVariables = {
    TERMINAL = "${pkgs.alacritty}/bin/alacritty";
  };

  home.packages = with pkgs; [
    alacritty
  ];

  home.file = {
    ".config/alacritty/alacritty.toml".source = ./alacritty.toml;
  };
}
