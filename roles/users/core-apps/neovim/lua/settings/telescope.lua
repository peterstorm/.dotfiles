local M = {}

M.setup = function()
  local telescope = require('telescope')
  local actions = require "telescope.actions"
  telescope.load_extension('fzy_native')
  telescope.setup({
    file_ignore_patterns = { "node_modules", "%.kml" },
    pickers = {
      buffers = {
        mappings = {
          i = {
            ["<C-d>"] = actions.delete_buffer + actions.move_to_top,
          }
        }
      }
    }
  })
end

return M
