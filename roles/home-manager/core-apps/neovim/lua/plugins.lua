return require('packer').startup(function(use)
  use 'wbthomason/packer.nvim'
  use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }
  use 'peterstorm/tomorrow-night-eighties'
  use 'christoomey/vim-tmux-navigator'
  use 'tpope/vim-surround'
  use 'tpope/vim-fugitive'
  use 'justinmk/vim-sneak'
  use 'hoob3rt/lualine.nvim'
  use 'github/copilot.vim'
  use ({'ShinKage/idris2-nvim', requires = {'neovim/nvim-lspconfig', 'MunifTanjim/nui.nvim'}})
  use {
    'numToStr/Comment.nvim',
    config = function()
        require('Comment').setup()
    end
  }
  use 'hrsh7th/vim-vsnip'
  use 'neovim/nvim-lspconfig'
  use 'simrat39/rust-tools.nvim'
  use({
    "https://git.sr.ht/~whynothugo/lsp_lines.nvim",
    config = function()
      require("lsp_lines").setup()
    end,
  })
  use({'scalameta/nvim-metals', requires = { "nvim-lua/plenary.nvim" }})
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
  use ({
    "pmizio/typescript-tools.nvim",
    requires = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
    config = function()
      require("typescript-tools").setup {}
    end,
  })
end)
