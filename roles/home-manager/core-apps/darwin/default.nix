{pkgs, config, lib, ...}:
{

  home.packages = with pkgs;[
    vscode
    discord
    ripgrep
    gh
  ];

}

