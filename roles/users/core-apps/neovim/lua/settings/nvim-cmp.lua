local M = {}

M.setup = function()
  local cmp = require('cmp')
  cmp.setup({
    sources = {
      { name = 'buffer' },
      { name = 'nvim_lsp' }
    },
    mapping = {
      ['<Tab>'] = cmp.mapping.select_next_item(),
      ['<S-Tab>'] = cmp.mapping.select_prev_item()
    }
  })
end

return M
