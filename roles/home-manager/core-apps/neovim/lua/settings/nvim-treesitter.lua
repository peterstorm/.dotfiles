local M = {}

M.setup = function()
  local ts = require 'nvim-treesitter.configs'
  ts.setup { ensure_installed = 
    { "scala"
    , "nix"
    , "kotlin"
    , "graphql"
    , "haskell"
    , "lua"
    , "bash"
    , "java"
    , "html"
    , "css"
    , "rust"
    }, highlight = { enable = true } }
end

return M
