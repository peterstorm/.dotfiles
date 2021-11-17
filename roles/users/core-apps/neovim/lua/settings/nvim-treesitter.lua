local M = {}

M.setup = function()
  local ts = require 'nvim-treesitter.configs'
  ts.setup { ensure_installed = { "scala" }, highlight = { enable = true } }
end

return M
