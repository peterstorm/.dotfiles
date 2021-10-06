local cmd = vim.cmd  -- to execute Vim commands e.g. cmd('pwd')
local fn = vim.fn    -- to call Vim functions e.g. fn.bufnr()
local g = vim.g      -- a table to access global variables
local opt = vim.opt  -- to set options
local f = require('settings.functions')
local setup = require('settings.setup')
local map = f.map

-- setup packer and plugins
setup.bootstrapPacker()
require('plugins')

-- generel nvim config
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
map('n', 'n', '<cmd>noh<cr>')
map('n', '<leader>bd', '<cmd>bd<cr>')

-- telescope config
map('n', '<leader>ff', '<cmd>Telescope find_files<cr>')
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>')
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>')

-- nvim-treesitter config
require('settings.nvim-treesitter').setup()

-- nvim-cmp config
require('settings.nvim-cmp').setup()

-- vim-sneak config
g['sneak#label'] = 1

-- lsp config
map('n', '<leader>gd', [[<cmd>lua vim.lsp.buf.declaration()<cr>]])

-- metals config
metals_config = require("metals").bare_config
metals_config.init_options.statusBarProvider = "on"
cmd([[augroup lsp]])
cmd([[autocmd!]])
cmd([[autocmd FileType scala,sbt lua require("metals").initialize_or_attach(metals_config)]])
cmd([[augroup end]])

-- lualine config
require('lualine').setup {
  options = { theme = 'iceberg_dark' }
}

