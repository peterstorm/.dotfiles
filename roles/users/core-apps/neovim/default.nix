{pkgs, lib, config, ...}:
{
  home.packages = with pkgs; [
    nodejs-16_x
    neovim-nightly
  ];

  home.file = {
    ".config/nvim/init.lua".source = ./init.lua;
    ".config/nvim/lua/settings/functions.lua".source = ./lua/settings/functions.lua;
    ".config/nvim/lua/settings/setup.lua".source = ./lua/settings/setup.lua;
    ".config/nvim/lua/plugins.lua".source = ./lua/plugins.lua;
    ".config/nvim/lua/settings/nvim-treesitter.lua".source = ./lua/settings/nvim-treesitter.lua;
    ".config/nvim/lua/settings/nvim-cmp.lua".source = ./lua/settings/nvim-cmp.lua;
  };
}
