local api = vim.api
local cmd = vim.cmd  -- to execute Vim commands e.g. cmd('pwd')
local fn = vim.fn    -- to call Vim functions e.g. fn.bufnr()
local g = vim.g      -- a table to access global variables
local opt = vim.opt  -- to set options
local f = require('settings.functions')
local setup = require('settings.setup')
local map = f.map
local keyset = vim.keymap.set


-- setup packer and plugins
setup.bootstrapPacker()
require('plugins')

-- generel nvim config
opt.colorcolumn = "80"
opt.expandtab = true                -- Use spaces instead of tabs
opt.hidden = true                   -- Enable background buffers
opt.hlsearch = true                 -- Highlight search terms
opt.incsearch = true
opt.ignorecase = true               -- Ignore case
opt.joinspaces = false              -- No double spaces with join
opt.list = true                     -- Show some invisible characters
opt.number = true                   -- Show line numbers
opt.relativenumber = true
opt.scrolloff = 4                   -- Lines of context
opt.shiftround = true               -- Round indent
opt.shiftwidth = 2                  -- Size of an indent
opt.sidescrolloff = 8               -- Columns of context
opt.smartcase = true                -- Do not ignore case with capitals
opt.smartindent = true              -- Insert indents automatically
opt.splitbelow = true               -- Put new windows below current
opt.splitright = true               -- Put new windows right of current
opt.expandtab = true
opt.tabstop = 2                     -- Number of spaces tabs count for
opt.termguicolors = true            -- True color support
opt.wildmode = {'list', 'longest'}  -- Command-line completion mode
opt.wrap = false                    -- Disable line wrap
opt.mouse = 'a'
opt.undofile = true                 -- persistent undo
cmd('colorscheme tomorrow-night-eighties')

-- nvim mappings
g['mapleader'] = ","
map('i', 'jk', '<ESC>')
map('x', 'jk', '<ESC>')
map('v', 'jk', '<ESC>')
map('n', '<leader>n', '<cmd>noh<cr>')
map('n', '<leader>bd', '<cmd>bd<cr>')
map('n', '<leader>e', '<cmd>Explore<cr>')
map('n', '<leader>hs', '<cmd>split<cr>')
map('n', '<leader>vs', '<cmd>vsplit<cr>')
map('n', '<leader>cs', '<cmd>close<cr>')
map('n', '<leader>h', '<cmd>vertical res -10<cr>')
map('n', '<leader>l', '<cmd>vertical res +10<cr>')
map('n', '<leader>j', '<cmd>res +10<cr>')
map('n', '<leader>k', '<cmd>res -10<cr>')

-- telescope config
require('telescope').load_extension('fzy_native')
local actions = require "telescope.actions"
require("telescope").setup {
  file_ignore_patterns = { "node_modules", "%.kml" },
  pickers = {
    buffers = {
      mappings = {
        i = {
          ["<C-d>"] = actions.delete_buffer + actions.move_to_top,
        }
      }
    }
  }
}
map('n', '<leader>ff', '<cmd>Telescope find_files<cr>')
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>')
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>')
map('n', '<leader>fr', '<cmd>Telescope resume<cr>')

-- nvim-treesitter config
require('settings.nvim-treesitter').setup()

-- nvim-cmp config
require('settings.nvim-cmp').setup()

-- nvim-metails config

local metals_config = require("metals").bare_config()

metals_config.settings = {
  showImplicitArguments = true,
  excludedPackages = { "akka.actor.typed.javadsl", "com.github.swagger.akka.javadsl" },
}

metals_config.capabilities = require("cmp_nvim_lsp").default_capabilities()

-- Autocmd that will actually be in charging of starting the whole thing
local nvim_metals_group = api.nvim_create_augroup("nvim-metals", { clear = true })
api.nvim_create_autocmd("FileType", {
  -- NOTE: You may or may not want java included here. You will need it if you
  -- want basic Java support but it may also conflict if you are using
  -- something like nvim-jdtls which also works on a java filetype autocmd.
  pattern = { "scala", "sbt", "java" },
  callback = function()
    require("metals").initialize_or_attach(metals_config)
  end,
  group = nvim_metals_group,
})

keyset("n", "<leader>mmc", require("metals").commands)
keyset("n", "<leader>mc", require("telescope").extensions.metals.commands)

-- nvim-lsp config
keyset("n", "<leader>gd",  vim.lsp.buf.definition)
keyset("n", "gr", vim.lsp.buf.references)
keyset("n", "K",  vim.lsp.buf.hover)
keyset("n", "<leader>ca", vim.lsp.buf.code_action)

-- vim-sneak config
g['sneak#label'] = 1

-- lualine config
require('lualine').setup {
  options = { theme = 'iceberg_dark' },
}

-- vim-fugitive
map('n', '<leader>gs', '<cmd>Git<cr>')
map('n', '<leader>gc', '<cmd>Git commit<cr>')
map('n', '<leader>gl', '<cmd>Git log<cr>')
map('n', '<leader>gp', '<cmd>Git push<cr>')

-- comment nvim
require('Comment').setup()

-- haskell specific
fourmoluOnSave = function()
  cmd("silent %!fourmolu -q --stdin-input-file %:p")
  -- local key = api.nvim_replace_termcodes("<C-o>", true, false, true)
  -- api.nvim_feedkeys(key, 'n', false)
end

api.nvim_create_autocmd(
  "BufWritePre",
  { pattern = "*.hs"
  , callback = fourmoluOnSave
  }
)
