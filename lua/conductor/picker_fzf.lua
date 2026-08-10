---fzf-lua backend for the session picker. Same actions as the telescope
---frontend: <CR> resume, <C-a> attach managed, <C-o> open raw log.
local M = {}

---Build fzf-lua's exec options (previewer + actions) bound to a `by_line`
---lookup table snapshot; the async listing path below rebuilds both together.
---@param opts { cwd?: string, adapter?: string }|nil
---@param by_line table<string, ConductorSession>
---@param adapter ConductorAdapter
---@return table fzf-lua exec opts
local function build_exec_opts(opts, by_line, adapter)
  local picker = require 'conductor.picker'

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
    picker.preview_lines_async(session, adapter, function(lines)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      picker.highlight_markdown_preview(bufnr)
    end)
    self:set_preview_buf(bufnr)
  end
  function previewer_builder:gen_winopts()
    return vim.tbl_extend('force', self.winopts, { wrap = true, number = false })
  end

  return {
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
  }
end

---@param sessions ConductorSession[]
---@param picker table conductor.picker module
---@return string[] lines, table<string, ConductorSession> by_line
local function build_lines(sessions, picker)
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
  return lines, by_line
end

---@param opts { cwd?: string, adapter?: string }|nil
function M.open(opts)
  opts = opts or {}
  local fzf = require 'fzf-lua'
  local picker = require 'conductor.picker'

  -- Open immediately with a "loading…" placeholder so listing hundreds of
  -- session files (conductor.threadwork, off the main thread) never stalls
  -- opening the picker; fzf_exec's contents get replaced once results land.
  ---@type table<string, ConductorSession>
  local by_line = {}
  local exec_opts = build_exec_opts(opts, by_line, nil)

  fzf.fzf_exec({ 'loading sessions…' }, exec_opts)

  picker.list_async(opts, function(sessions, adapter)
    local lines, resolved_by_line = build_lines(sessions, picker)
    by_line = resolved_by_line
    local resolved_opts = build_exec_opts(opts, by_line, adapter)
    fzf.fzf_exec(lines, resolved_opts)
  end)
end

return M
