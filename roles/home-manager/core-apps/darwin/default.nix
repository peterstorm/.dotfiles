{pkgs, config, lib, ...}:
{

  home.packages = with pkgs;[
    vscode
    discord
    ripgrep
    claude-code
    gh
    git
    (colima.override {
      lima = lima.override { withAdditionalGuestAgents = true; };
    })
    postman
    bruno
    bytecode-viewer
    azure-cli
    element-desktop
  ];

}

