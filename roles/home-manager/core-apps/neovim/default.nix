{input, pkgs, lib, config, ...}:
{
  home.packages = with pkgs; [
    neovim
  ];

  home.file = {
    ".config/nvim/lua/config/lazy.lua".source = ./lua/config/lazy.lua;
    ".config/nvim/init.lua".source = ./init.lua;
    ".config/nvim/lua/plugins/java/init.lua".source = ./lua/plugins/java/init.lua;
    ".config/nvim/lua/settings/functions.lua".source = ./lua/settings/functions.lua;
    ".config/nvim/lua/settings/setup.lua".source = ./lua/settings/setup.lua;
    ".config/nvim/lua/plugins/plugins.lua".source = ./lua/plugins/plugins.lua;
    ".config/nvim/lua/settings/nvim-treesitter.lua".source = ./lua/settings/nvim-treesitter.lua;
    ".config/nvim/lua/settings/nvim-cmp.lua".source = ./lua/settings/nvim-cmp.lua;
    ".config/nvim/lua/settings/nvim-metals.lua".source = ./lua/settings/nvim-metals.lua;
    ".config/nvim/lua/settings/telescope.lua".source = ./lua/settings/telescope.lua;
    ".config/nvim/lua/settings/emmet-ls.lua".source = ./lua/settings/emmet-ls.lua;
    ".config/nvim/lua/settings/rust-tools.lua".source = ./lua/settings/rust-tools.lua;
  };
}
