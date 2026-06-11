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
      # Public plugin repos (peterstorm/*) clone over HTTPS even when tooling
      # emits SSH URLs — these machines authenticate to GitHub via HTTPS.
      url."https://github.com/peterstorm/".insteadOf = "git@github.com:peterstorm/";
    };
  };
}
