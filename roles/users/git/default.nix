{pkgs, config, lib, ...}:
{

  programs.git = {
    enable = true;
    userName = "Peter Storm";
    userEmail = "peter.storm@peterstorm.io";
    extraConfig = {
      init = {
        defaultBranch = "main";
      };
    };
  };
}
