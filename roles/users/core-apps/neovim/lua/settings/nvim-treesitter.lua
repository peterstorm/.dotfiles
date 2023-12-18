local M = {}

M.setup = function()
  local ts = require 'nvim-treesitter.configs'
  ts.setup { ensure_installed = { "scala", "nix", "kotlin", "rust", "haskell", "lua", "bash", "java" }, highlight = { enable = true } }
end

return M
