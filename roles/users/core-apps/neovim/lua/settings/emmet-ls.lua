local M = {}

M.setup = function(on_attach)
  local lspconfig = require("lspconfig")
  local configs = require("lspconfig/configs")
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.textDocument.completion.completionItem.snippetSupport = true
  lspconfig.emmet_ls.setup({
    capabilities = capabilities,
    filetypes = { "html", "css", "scss", "javascript", "javascriptreact", "typescript", "typescriptreact", "vue" },
    flags = {
      debounce_text_changes = 150,
    },
  })
end

return M
