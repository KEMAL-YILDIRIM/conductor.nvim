local has_telescope, telescope = pcall(require, 'telescope')
if not has_telescope then
  error 'conductor.nvim telescope extension requires telescope.nvim'
end

local actions = require 'telescope.actions'
local action_state = require 'telescope.actions.state'
local finders = require 'telescope.finders'
local pickers = require 'telescope.pickers'
local previewers = require 'telescope.previewers'
local telescope_config = require('telescope.config').values
local entry_display = require 'telescope.pickers.entry_display'

local picker_core = require 'conductor.picker'
local relative_time = picker_core.relative_time
local shorten_cwd = picker_core.shorten_cwd

local function make_displayer()
  return entry_display.create {
    separator = ' │ ',
    items = {
      { width = 40 },
      { width = 10 },
      { width = 8 },
      { remaining = true },
    },
  }
end

local function session_picker(opts)
  opts = opts or {}
  local sessions, adapter = picker_core.list(opts)
  local displayer = make_displayer()

  local previewer = previewers.new_buffer_previewer {
    title = 'Conversation Log',
    get_buffer_by_name = function(_, entry)
      return entry.value.path
    end,
    define_preview = function(self, entry)
      local lines = picker_core.preview_lines(entry.value, adapter)
      vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      vim.bo[self.state.bufnr].filetype = 'markdown'
      vim.wo[self.state.winid].wrap = true
    end,
  }

  pickers
    .new(opts, {
      prompt_title = opts.cwd and ('Agent Sessions (%s)'):format(shorten_cwd(opts.cwd)) or 'Agent Sessions',
      finder = finders.new_table {
        results = sessions,
        entry_maker = function(session)
          return {
            value = session,
            ordinal = table.concat({ session.name, session.cwd or '', session.path }, ' '),
            display = function(entry)
              return displayer {
                { entry.value.name, 'TelescopeResultsIdentifier' },
                { relative_time(entry.value.mtime), 'TelescopeResultsComment' },
                { ('%d msg'):format(entry.value.message_count), 'TelescopeResultsNumber' },
                { shorten_cwd(entry.value.cwd), 'TelescopeResultsComment' },
              }
            end,
            path = session.path,
          }
        end,
      },
      sorter = telescope_config.generic_sorter(opts),
      previewer = previewer,
      attach_mappings = function(prompt_bufnr, map)
        local function with_selected(action)
          return function()
            local entry = action_state.get_selected_entry()
            actions.close(prompt_bufnr)
            if entry then
              action(entry.value)
            end
          end
        end

        actions.select_default:replace(with_selected(picker_core.action_resume))
        map('i', '<C-o>', with_selected(picker_core.action_open_log))
        map('n', '<C-o>', with_selected(picker_core.action_open_log))
        map('i', '<C-a>', with_selected(picker_core.action_attach))
        map('n', '<C-a>', with_selected(picker_core.action_attach))

        return true
      end,
    })
    :find()
end

return telescope.register_extension {
  exports = {
    conductor = session_picker,
    sessions = session_picker,
  },
}
