with import <nixpkgs> {};

neovim.override {
  configure = {
    customRC = builtins.readFile "/home/peterstorm/.config/nvim/init.vim";
    packages.myVimPackage = with pkgs.vimPlugins; {
      start = [ vim-plug ];
    };
  };
}
