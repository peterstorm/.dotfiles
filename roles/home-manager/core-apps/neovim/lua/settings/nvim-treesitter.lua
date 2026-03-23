local M = {}

M.setup = function()
  require('nvim-treesitter.configs').setup({
    ensure_installed = {
      "scala", "nix", "kotlin", "graphql", "haskell", "lua",
      "bash", "java", "html", "css", "rust", "javascript",
      "typescript", "dockerfile",
    },
    highlight = { enable = true },
    indent = { enable = true },
  })
end

return M
