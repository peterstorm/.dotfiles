{pkgs, config, lib, ...}:
{

  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "Peter Storm";
        email = "peter.storm@peterstorm.io";
      };
      init = {
        defaultBranch = "main";
      };
    };
  };
}
