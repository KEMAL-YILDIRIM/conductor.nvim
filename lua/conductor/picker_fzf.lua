---fzf-lua backend for the session picker. Same actions as the telescope
---frontend: <CR> resume, <C-a> attach managed, <C-o> open raw log.
local M = {}

---@param opts { cwd?: string, adapter?: string }|nil
function M.open(opts)
  opts = opts or {}
  local fzf = require 'fzf-lua'
  local picker = require 'conductor.picker'

  local sessions, adapter = picker.list(opts)
  ---@type table<string, ConductorSession>
  local by_line = {}
  local lines = {}
  for _, session in ipairs(sessions) do
    local line = ('%-40s │ %-10s │ %4d msg │ %s'):format(
      session.name:sub(1, 40),
      picker.relative_time(session.mtime),
      session.message_count,
      picker.shorten_cwd(session.cwd)
    )
    -- Ensure uniqueness if two sessions format identically.
    while by_line[line] do
      line = line .. ' '
    end
    by_line[line] = session
    lines[#lines + 1] = line
  end

  local function selected_session(selected)
    return selected and selected[1] and by_line[selected[1]] or nil
  end

  local previewer_builder = require('fzf-lua.previewer.builtin').base:extend()
  function previewer_builder:new(o, picker_opts, fzf_win)
    previewer_builder.super.new(self, o, picker_opts, fzf_win)
    setmetatable(self, previewer_builder)
    return self
  end
  function previewer_builder:populate_preview_buf(entry_str)
    local session = by_line[entry_str]
    if not session then
      return
    end
    local bufnr = self:get_tmp_buffer()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, picker.preview_lines(session, adapter))
    vim.bo[bufnr].filetype = 'markdown'
    self:set_preview_buf(bufnr)
  end
  function previewer_builder:gen_winopts()
    return vim.tbl_extend('force', self.winopts, { wrap = true, number = false })
  end

  fzf.fzf_exec(lines, {
    prompt = (opts.cwd and 'Agent Sessions (cwd)> ' or 'Agent Sessions> '),
    previewer = previewer_builder,
    actions = {
      ['default'] = function(selected)
        local session = selected_session(selected)
        if session then
          picker.action_resume(session)
        end
      end,
      ['ctrl-a'] = function(selected)
        local session = selected_session(selected)
        if session then
          picker.action_attach(session)
        end
      end,
      ['ctrl-o'] = function(selected)
        local session = selected_session(selected)
        if session then
          picker.action_open_log(session)
        end
      end,
    },
  })
end

return M
