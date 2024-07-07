--[[ return require('packer').startup(function(use)
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
end) ]]

return {
  {
    'peterstorm/tomorrow-night-eighties',
    lazy = false,
    priority = 100,
  },
  {
    'nvim-treesitter/nvim-treesitter',
    build = ':TSUpdate'
  },
  {
    'christoomey/vim-tmux-navigator'
  },
  {
    'tpope/vim-surround'
  },
  {
    'tpope/vim-fugitive'
  },
  {
    'justinmk/vim-sneak'
  },
  {
    'hoob3rt/lualine.nvim'
  },
  {
    'github/copilot.vim'
  },
  {
    'ShinKage/idris2-nvim',
    dependencies = {
      'neovim/nvim-lspconfig',
      'MunifTanjim/nui.nvim'
    }
  },
  {
    'numToStr/Comment.nvim',
    opts = {}
    --[[ config = function()
        require('Comment').setup()
    end ]]
  },
  {
    'hrsh7th/vim-vsnip'
  },
  {
    'neovim/nvim-lspconfig'
  },
  {
    'simrat39/rust-tools.nvim'
  },
  {
    'https://git.sr.ht/~whynothugo/lsp_lines.nvim',
    opts = {}
    --[[ config = function()
      require("lsp_lines").setup()
    end, ]]
  },
  {
    'scalameta/nvim-metals',
    dependencies = {
      "nvim-lua/plenary.nvim"
    }
  },
  {
    'nvim-telescope/telescope.nvim',
    dependencies = {
      'nvim-lua/popup.nvim',
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-fzy-native.nvim'
    },
  },
  {
    'hrsh7th/nvim-cmp',
    dependencies = {
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-nvim-lsp',
    },
  },
  {
    'pmizio/typescript-tools.nvim',
    dependencies = {
      'nvim-lua/plenary.nvim',
      'neovim/nvim-lspconfig'
    },
    --[[ config = function()
      require("typescript-tools").setup {}
    end, ]]
  }
}
