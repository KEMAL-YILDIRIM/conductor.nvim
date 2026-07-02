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

---Cache of rendered previews keyed by path, invalidated by mtime.
---@type table<string, { mtime: integer, lines: string[] }>
local preview_cache = {}

local function relative_time(unix_time)
  local delta = os.time() - unix_time
  if delta < 60 then
    return 'just now'
  elseif delta < 3600 then
    return ('%dm ago'):format(math.floor(delta / 60))
  elseif delta < 86400 then
    return ('%dh ago'):format(math.floor(delta / 3600))
  else
    return ('%dd ago'):format(math.floor(delta / 86400))
  end
end

local function shorten_cwd(cwd)
  if not cwd then
    return ''
  end
  local home = vim.fs.normalize(vim.fn.expand '~')
  local normalized = vim.fs.normalize(cwd)
  if vim.startswith(normalized:lower(), home:lower()) then
    return '~' .. normalized:sub(#home + 1)
  end
  return normalized
end

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
  local conductor_config = require('conductor.config').options
  local interface = require 'conductor.adapters.interface'
  local adapter = interface.get(opts.adapter or conductor_config.default_adapter)

  local sessions = adapter.list_sessions { cwd = opts.cwd }
  local displayer = make_displayer()

  local previewer = previewers.new_buffer_previewer {
    title = 'Conversation Log',
    get_buffer_by_name = function(_, entry)
      return entry.value.path
    end,
    define_preview = function(self, entry)
      local session = entry.value
      local stat = vim.uv.fs_stat(session.path)
      local mtime = stat and stat.mtime.sec or 0

      local cached = preview_cache[session.path]
      local lines
      if cached and cached.mtime == mtime then
        lines = cached.lines
      else
        local log_parser = require 'conductor.log_parser'
        local meta, entries = adapter.parse_log(session.path)
        lines = log_parser.render_preview(meta, entries, {
          max_entries = conductor_config.picker.preview_max_entries,
          max_lines_per_entry = conductor_config.picker.preview_max_lines_per_entry,
        })
        preview_cache[session.path] = { mtime = mtime, lines = lines }
      end

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
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require('conductor').resume(entry.value)
          end
        end)

        local open_log = function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            vim.cmd.edit(vim.fn.fnameescape(entry.value.path))
          end
        end
        map('i', '<C-o>', open_log)
        map('n', '<C-o>', open_log)

        local attach_managed = function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            local session = entry.value
            local instance, spawn_error = require('conductor.supervisor').spawn {
              adapter = session.adapter,
              cwd = session.cwd,
              session_path = session.path,
              name = session.name,
            }
            if instance then
              require('conductor.sidebar').open()
              require('conductor.chatlog').open(instance)
            else
              vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
            end
          end
        end
        map('i', '<C-a>', attach_managed)
        map('n', '<C-a>', attach_managed)

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
