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
      'nvim-telescope/telescope-fzy-native.nvim'
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
    'ShinKage/idris2-nvim',
    dependencies = {
      'neovim/nvim-lspconfig',
      'MunifTanjim/nui.nvim'
    }
  },
  {
    'numToStr/Comment.nvim',
    opts = {}
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
        'tailwindcss',
        'lua_ls',
      }
    }
  },
  {
    'luckasRanarison/tailwind-tools.nvim',
    dependencies = {
      'nvim-treesitter/nvim-treesitter' ,
    },
    opts = {}
  }
}
