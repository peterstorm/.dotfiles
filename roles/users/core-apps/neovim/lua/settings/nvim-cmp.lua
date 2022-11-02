local M = {}

M.setup = function()
  local cmp = require('cmp')
  cmp.setup({
    sources = {
      { name = 'buffer' },
      { name = 'nvim_lsp' }
    }
  })
end

return M
