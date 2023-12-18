local M = {}

M.setup = function()
  local rust_tools = require('rust-tools')
  local opts = {
    tools = {
      runnables = {
        use_telescope = true,
      },
      inlay_hints = {
        auto = true,
        show_parameter_hints = false,
        parameter_hints_prefix = "",
        other_hints_prefix = "",
      },
    },
  }
  rust_tools.setup(opts)
end

return M
