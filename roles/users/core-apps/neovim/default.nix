{pkgs, lib, config, ...}:
{

  programs.neovim = {
    enable = true;
    vimAlias = true;
    viAlias = true;
    package = pkgs.neovim-nightly;
    plugins = with pkgs.vimPlugins; [
    	packer-nvim
    ];
  };

  xdg.configFile."nvim/init.lua" = {
    source = ./init.lua;
    recursive = true;
  };
}
