return {
  {
    'peterstorm/tomorrow-night-eighties',
    lazy = false,
    priority = 100,
    config = function()
      -- load the colorscheme here
      vim.cmd([[colorscheme tomorrow-night-eighties]])
    end
  },
  {
    'nvim-telescope/telescope.nvim',
    dependencies = {
      'nvim-lua/popup.nvim',
      'nvim-lua/plenary.nvim',
      'nvim-telescope/telescope-fzy-native.nvim',
      'debugloop/telescope-undo.nvim'
    },
    lazy = false
  },
  {
    'nvim-treesitter/nvim-treesitter',
    lazy = false,
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
    'numToStr/Comment.nvim',
    opts = {}
  },
  {
    'sbdchd/neoformat'
  },
  {
    'hrsh7th/vim-vsnip'
  },
  {
    'neovim/nvim-lspconfig'
  },
  {
    'scalameta/nvim-metals',
    dependencies = {
      "nvim-lua/plenary.nvim"
    }
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
  },
  { 'williamboman/mason-lspconfig.nvim',
    opts = {
      ensure_installed = {
        'lua_ls',
      }
    },
    dependencies = {
        { "mason-org/mason.nvim", opts = {} },
        "neovim/nvim-lspconfig",
    },
  },
  {
   "m4xshen/hardtime.nvim",
   lazy = false,
   dependencies = { "MunifTanjim/nui.nvim" },
   opts = {},
  },
  {
  'stevearc/conform.nvim',
  opts = {},
  },
}
