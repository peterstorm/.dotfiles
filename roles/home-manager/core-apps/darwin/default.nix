{pkgs, config, lib, ...}:
{

  home.sessionVariables = {
    EDITOR = "nvim";
  };

  home.packages = with pkgs;[
    vscode
    discord
    ripgrep
    gh
  ];

}

