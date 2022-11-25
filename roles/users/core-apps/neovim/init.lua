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
require('telescope').load_extension('coc')
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
map('n', '<leader>ds', '<cmd>Telescope coc document_symbols<cr>')
map('n', '<leader>cc', '<cmd>Telescope coc commands<cr>')
map('n', '<leader>cd', '<cmd>Telescope coc diagnostics<cr>')
map('n', '<leader>fr', '<cmd>Telescope resume<cr>')

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

function _G.check_back_space()
    local col = vim.fn.col('.') - 1
    return col == 0 or vim.fn.getline('.'):sub(col, col):match('%s') ~= nil
end

-- Use tab for trigger completion with characters ahead and navigate.
-- NOTE: There's always complete item selected by default, you may want to enable
-- no select by `"suggest.noselect": true` in your configuration file.
-- NOTE: Use command ':verbose imap <tab>' to make sure tab is not mapped by
-- other plugin before putting this into your config.
local opts = {silent = true, noremap = true, expr = true, replace_keycodes = false}
keyset("i", "<TAB>", 'coc#pum#visible() ? coc#pum#next(1) : v:lua.check_back_space() ? "<TAB>" : coc#refresh()', opts)
keyset("i", "<S-TAB>", [[coc#pum#visible() ? coc#pum#prev(1) : "\<C-h>"]], opts)

-- Make <CR> to accept selected completion item or notify coc.nvim to format
-- <C-g>u breaks current undo, please make your own choice.
keyset("i", "<cr>", [[coc#pum#visible() ? coc#pum#confirm() : "\<C-g>u\<CR>\<c-r>=coc#on_enter()\<CR>"]], opts)
--
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

-- haskell specific
api.nvim_create_autocmd(
  "BufWritePost",
  { pattern = "*.hs"
  , command = "%!fourmolu -q --stdin-input-file %:p"
  }
)
