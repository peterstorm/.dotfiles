local M = {}

M.setup = function()
  local telescope = require('telescope')
  local actions = require "telescope.actions"
  telescope.load_extension('fzy_native')
  telescope.load_extension('undo')
  telescope.setup({
    pickers = {
      find_files = {
        file_ignore_patterns = { 'node_modules', '%.kml' },
        path_display = { "truncate" },
      },
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
