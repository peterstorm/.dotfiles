local M = {}

M.setup = function(on_attach)
  local capabilities = vim.lsp.protocol.make_client_capabilities()
  capabilities.textDocument.completion.completionItem.snippetSupport = true
  vim.lsp.config('emmet_ls', {
    capabilities = capabilities,
    filetypes = { "html", "css", "scss", "javascript", "javascriptreact", "typescript", "typescriptreact", "vue" },
  })
  vim.lsp.enable('emmet_ls')
end

return M
