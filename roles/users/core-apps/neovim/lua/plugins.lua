return require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'
  use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }
  use 'peterstorm/tomorrow-night-eighties'
  use 'christoomey/vim-tmux-navigator'
  use 'tpope/vim-surround'
  use 'tpope/vim-fugitive'
  use 'justinmk/vim-sneak'
  use 'hoob3rt/lualine.nvim'
  use {'neoclide/coc.nvim', branch = 'release'}
  use 'fannheyward/telescope-coc.nvim'
  use {
    'numToStr/Comment.nvim',
    config = function()
        require('Comment').setup()
    end
  }
  --use 'neovim/nvim-lspconfig'
  --use({'scalameta/nvim-metals', requires = { "nvim-lua/plenary.nvim" }})
  use({
    'nvim-telescope/telescope.nvim',
    requires = {
      { "nvim-lua/popup.nvim" },
      { "nvim-lua/plenary.nvim" },
      { 'nvim-telescope/telescope-fzy-native.nvim' }
    },
  })
  use({
    "hrsh7th/nvim-cmp",
    requires = {
      { "hrsh7th/cmp-buffer" },
      { "hrsh7th/cmp-nvim-lsp" },
    },
  })
end)
