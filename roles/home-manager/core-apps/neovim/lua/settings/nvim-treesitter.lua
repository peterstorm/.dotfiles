local M = {}

M.setup = function()
  local ts = require('nvim-treesitter')
  local desired = {
    "scala", "nix", "kotlin", "graphql", "haskell", "lua",
    "bash", "java", "html", "css", "rust", "javascript",
    "typescript", "dockerfile",
  }
  local installed = ts.get_installed()
  local missing = vim.tbl_filter(function(lang)
    return not vim.list_contains(installed, lang)
  end, desired)
  if #missing > 0 then
    ts.install(missing)
  end
end

return M
