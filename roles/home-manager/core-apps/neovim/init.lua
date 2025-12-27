local api = vim.api
local cmd = vim.cmd  -- to execute Vim commands e.g. cmd('pwd')
local fn = vim.fn    -- to call Vim functions e.g. fn.bufnr()
local g = vim.g      -- a table to access global variables
local opt = vim.opt  -- to set optio
local f = require('settings.functions')
local setup = require('settings.setup')
local map = f.map
local keyset = vim.keymap.set

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
opt.shiftwidth = 4                  -- Size of an indent
opt.softtabstop = 4
opt.sidescrolloff = 8               -- Columns of context
opt.smartcase = true                -- Do not ignore case with capitals
opt.smarttab = true
opt.smartindent = true              -- Insert indents automatically
opt.splitbelow = true               -- Put new windows below current
opt.splitright = true               -- Put new windows right of current
opt.expandtab = true
opt.tabstop = 4                     -- Number of spaces tabs count for
opt.termguicolors = true            -- True color support
opt.wildmode = {'list', 'longest'}  -- Command-line completion mode
opt.wrap = false                    -- Disable line wrap
opt.mouse = 'a'
opt.undofile = true                 -- persistent undo

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

-- setup lazy.nvim
require('config.lazy')

-- telescope config
require('settings.telescope').setup()

map('n', '<leader>ff', '<cmd>Telescope find_files<cr>')
map('n', '<leader>fg', '<cmd>Telescope live_grep<cr>')
map('n', '<leader>fb', '<cmd>Telescope buffers<cr>')
map('n', '<leader>fr', '<cmd>Telescope resume<cr>')
map('n', '<leader>cd', '<cmd>Telescope diagnostics<cr>')

-- nvim-treesitter config
require('settings.nvim-treesitter').setup()

-- nvim-cmp config
require('settings.nvim-cmp').setup()

-- nvim-metals config
require('settings.nvim-metals').setup()
keyset("n", "<leader>mc", require("telescope").extensions.metals.commands)

-- nvim-java
require('java').setup({
  jdk = {
    auto_install = false,
  },
})

-- nvim-lsp config
local builtin = require('telescope.builtin')
keyset('n', '<leader>gd', builtin.lsp_definitions)
keyset('n', '<leader>gr', builtin.lsp_references)
keyset("n", "K",  vim.lsp.buf.hover)
keyset("n", "<leader>ca", vim.lsp.buf.code_action)
keyset("n", "<leader>sr", vim.lsp.buf.rename)
map("n", "<space>e", ":lua vim.diagnostic.open_float(0, { scope = 'line' })<CR>")

vim.diagnostic.config({
  virtual_text = true,
})

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
vim.lsp.config('hls', {
  filetypes = { 'haskell', 'lhaskell', 'cabal' },
  settings = {
    haskell = {
      formattingProvider = "formolu"
    }
  }
})
vim.lsp.enable('hls')

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

-- hardtime
require("hardtime").setup()

-- copilot
g.copilot_assume_mapped = true


-- emmet-ls
require('settings.emmet-ls').setup()


-- typescript-tools
require("typescript-tools").setup({})

-- lua setup
vim.lsp.enable('lua_ls')

-- java lsp
vim.lsp.enable('jdtls')

-- neoformat

g.neoformat_try_node_exe = 1

api.nvim_create_autocmd("BufWritePre", {
  pattern = { "*.js", "*.jsx", "*.ts", "*.tsx" },
  command = "Neoformat prettier",
})

require("conform").setup({
  formatters_by_ft = {
    java = { "google-java-format" },
  },
  format_on_save = function(bufnr)
    -- Disable autoformat on certain filetypes
    local ignore_filetypes = { "sql" }
    if vim.tbl_contains(ignore_filetypes, vim.bo[bufnr].filetype) then
      return
    end
    -- Disable with a global or buffer-local variable
    if vim.g.disable_autoformat or vim.b[bufnr].disable_autoformat then
      return
    end
    -- Disable autoformat for files in a certain path
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    if bufname:match("/node_modules/") then
      return
    end
    -- ...additional logic...
    return { timeout_ms = 500, lsp_format = "fallback" }
  end,
})
