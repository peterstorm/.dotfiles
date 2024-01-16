{pkgs, lib, config, ...}:
{
  programs.starship = {
    enable = true;
    enableBashIntegration = true;
    enableZshIntegration = true;
  };
}
