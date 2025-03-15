{pkgs, config, lib, ...}:
{

  home.packages = with pkgs;[
    vscode
    discord
    ripgrep
    gh
    git
    colima
    postman
    bruno
    bytecode-viewer
    azure-cli
    element-desktop
  ];

}

