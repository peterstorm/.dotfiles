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
map('n', '<leader>n', '<cmd>noh<cr>')
map('n', '<leader>bd', '<cmd>bd<cr>')
map('n', '<leader>e', '<cmd>Explore<cr>')
map('n', '<leader>hs', '<cmd>split<cr>')
map('n', '<leader>vs', '<cmd>vsplit<cr>')
map('n', '<leader>cs', '<cmd>close<cr>')

-- telescope config
require('telescope').load_extension('fzy_native')
require('telescope').load_extension('coc')
map('n', '<leader>ff', '<cmd>Telescope find_files<cr>')
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>')
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>')
map('n', '<leader>ds', '<cmd>Telescope coc document_symbols<cr>')
map('n', '<leader>cc', '<cmd>Telescope coc commands<cr>')
map('n', '<leader>cd', '<cmd>Telescope coc diagnostics<cr>')

-- nvim-treesitter config
require('settings.nvim-treesitter').setup()

-- nvim-cmp config
require('settings.nvim-cmp').setup()

-- coc.nvim config
map('n', '<leader>gd', '<cmd>call CocActionAsync("jumpDefinition")<cr>')
map('n', '<leader>gr', '<cmd>call CocActionAsync("jumpReferences")<cr>')
map('n', '<leader>d,', '<cmd>call CocActionAsync("diagnosticPrevious")<cr>')
map('n', '<leader>d.', '<cmd>call CocActionAsync("diagnosticNext")<cr>')
map('n', '<leader>ca', '<cmd>call CocActionAsync("codeAction", "cursor")<cr>')
map('n', '<leader>rn', '<cmd>call CocActionAsync("rename")<cr>')
map('n', 'K', '<cmd>call CocActionAsync("doHover")<cr>')
cmd[[inoremap <expr> <Tab> pumvisible() ? "\<C-n>" : "\<Tab>"]]
cmd[[inoremap <expr> <S-Tab> pumvisible() ? "\<C-p>" : "\<S-Tab>"]]
cmd[[nnoremap <expr><C-f> coc#util#has_float() ? coc#util#float_scroll(1) : "\<C-f>"]]
cmd[[nnoremap <expr><C-b> coc#util#has_float() ? coc#util#float_scroll(0) : "\<C-b>"]]
cmd[[if exists('*complete_info')
  inoremap <expr> <cr> complete_info()["selected"] != "-1" ? "\<C-y>" : "\<C-g>u\<CR>"
else
  imap <expr> <cr> pumvisible() ? "\<C-y>" : "\<C-g>u\<CR>"
endif]]

-- vim-sneak config
g['sneak#label'] = 1

-- lualine config
require('lualine').setup {
  options = { theme = 'iceberg_dark' },
  sections = { lualine_a = {'g:coc_status'} }
}

-- vim-fugitive
map('n', '<leader>gs', '<cmd>Git<cr>')
map('n', '<leader>gc', '<cmd>Git commit<cr>')
map('n', '<leader>gl', '<cmd>Git log<cr>')
map('n', '<leader>gp', '<cmd>Git push<cr>')

-- comment nvim
require('Comment').setup()
