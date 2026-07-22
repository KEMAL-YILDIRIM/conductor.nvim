---Live sessions sidebar: one line per managed instance with a status icon.
---Updates are pushed via the `User ConductorUpdate` autocmd (no polling).
local M = {}

local state = {
  bufnr = nil, ---@type integer|nil
  winid = nil, ---@type integer|nil
  ---Maps sidebar line numbers to instance ids.
  line_to_instance = {}, ---@type table<integer, integer>
  ---Maps sidebar line numbers to external session entries.
  line_to_external = {}, ---@type table<integer, ConductorExternalSession>
  autocmd_id = nil, ---@type integer|nil
  refresh_timer = nil, ---@type uv.uv_timer_t|nil
}

local status_icons = {
  starting = '󰦖',
  idle = '',
  streaming = '󰑮',
  needs_input = '󰋗',
  error = '',
  exited = '󰅚',
}

local status_highlights = {
  starting = 'Comment',
  idle = 'Normal',
  streaming = 'DiagnosticInfo',
  needs_input = 'DiagnosticWarn',
  error = 'DiagnosticError',
  exited = 'Comment',
}

local namespace = vim.api.nvim_create_namespace 'conductor_sidebar'

local function buffer_valid()
  return state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr)
end

local function window_valid()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

---Whether the given window is the live-sessions sidebar. Lets other panels
---(e.g. the chat shell) avoid adopting the sidebar as their own pane.
---@param window integer|nil
---@return boolean
function M.is_window(window)
  return window ~= nil and window == state.winid and window_valid()
end

function M.render()
  if not buffer_valid() then
    return
  end
  local supervisor = require 'conductor.supervisor'
  local instances = supervisor.list()
  local all_externals = require('conductor.external').list_cached()

  -- Dedupe: a session that has been attached as a managed instance must not
  -- also appear in the External section. A session lives on the panel once.
  local managed_session_paths = {}
  for _, instance in ipairs(instances) do
    if instance.session_path then
      managed_session_paths[instance.session_path] = true
    end
  end
  local externals = {}
  for _, external in ipairs(all_externals) do
    if not (external.session_file and managed_session_paths[external.session_file]) then
      externals[#externals + 1] = external
    end
  end

  local lines = { ' Conductor', '' }
  local highlights = {} ---@type { line: integer, group: string }[]
  state.line_to_instance = {}
  state.line_to_external = {}

  if #instances == 0 and #externals == 0 then
    lines[#lines + 1] = '  no live sessions'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  n: new session'
    lines[#lines + 1] = '  q: close'
  else
    if #instances > 0 then
      lines[#lines + 1] = ' Managed'
      for _, instance in ipairs(instances) do
        local icon = status_icons[instance.status] or '?'
        lines[#lines + 1] = ('%s %s'):format(icon, instance.name)
        state.line_to_instance[#lines] = instance.id
        highlights[#highlights + 1] = { line = #lines - 1, group = status_highlights[instance.status] or 'Normal' }
        local detail = instance.status
        if instance.status == 'exited' and instance.exit_code then
          detail = ('exited (%d)'):format(instance.exit_code)
        end
        lines[#lines + 1] = ('   %s'):format(detail)
      end
    end
    if #externals > 0 then
      if #instances > 0 then
        lines[#lines + 1] = ''
      end
      lines[#lines + 1] = ' External (terminal)'
      for _, external in ipairs(externals) do
        local icon = status_icons[external.status] or '?'
        lines[#lines + 1] = ('%s %s'):format(icon, external.name)
        state.line_to_external[#lines] = external
        highlights[#highlights + 1] = { line = #lines - 1, group = status_highlights[external.status] or 'Normal' }
        lines[#lines + 1] = ('   %s · pid %d'):format(external.status, external.pid)
      end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = ' <CR>: open chat  n: new'
    lines[#lines + 1] = ' p: prompt  s: stop  x: kill  q: close'
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.hl.range(state.bufnr, namespace, highlight.group, { highlight.line, 0 }, { highlight.line, -1 })
  end
end

---@return ConductorInstance|nil
local function instance_at_cursor()
  if not window_valid() then
    return nil
  end
  local line = vim.api.nvim_win_get_cursor(state.winid)[1]
  -- Direct hit or the detail line below it.
  local instance_id = state.line_to_instance[line] or state.line_to_instance[line - 1]
  if instance_id then
    return require('conductor.supervisor').instances[instance_id]
  end
  return nil
end

local function setup_keymaps()
  local config = require 'conductor.config'
  local options = { buffer = state.bufnr, nowait = true }

  config.map('sidebar', 'open_chat', 'n', function()
    local instance = instance_at_cursor()
    if instance then
      require('conductor.chatlog').open(instance)
      return
    end
    -- External session: attach as a managed RPC instance so it becomes a live,
    -- interactive chat instead of a static read-only log dump. If we've already
    -- attached to this session file, just reopen its chat view.
    local line = vim.api.nvim_win_get_cursor(state.winid)[1]
    local external = state.line_to_external[line] or state.line_to_external[line - 1]
    if external and external.session_file then
      local supervisor = require 'conductor.supervisor'
      for _, existing in ipairs(supervisor.list()) do
        if existing.session_path == external.session_file then
          require('conductor.chatlog').open(existing)
          return
        end
      end
      local attached, spawn_error = supervisor.spawn {
        adapter = 'pi',
        cwd = external.cwd,
        session_path = external.session_file,
        name = external.name,
      }
      if attached then
        require('conductor.chatlog').open(attached)
      else
        vim.notify('conductor: ' .. (spawn_error or 'attach failed'), vim.log.levels.ERROR)
      end
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: open chat' }))

  config.map('sidebar', 'prompt', 'n', function()
    local instance = instance_at_cursor()
    if instance then
      require('conductor.chatlog').input_prompt(instance)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: prompt instance' }))

  config.map('sidebar', 'new', 'n', function()
    vim.ui.input({ prompt = 'session name (empty = auto): ' }, function(name)
      if name == nil then
        return
      end
      local instance, spawn_error = require('conductor.supervisor').spawn { name = name ~= '' and name or nil }
      if not instance then
        vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
        return
      end
      -- Open the new instance's chat in the shared chat window.
      require('conductor.chatlog').open(instance)
    end)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: new session' }))

  config.map('sidebar', 'stop', 'n', function()
    local instance = instance_at_cursor()
    if instance then
      require('conductor.supervisor').abort(instance)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: stop agent' }))

  config.map('sidebar', 'kill', 'n', function()
    local instance = instance_at_cursor()
    if instance then
      require('conductor.supervisor').remove(instance)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: kill instance' }))

  config.map('sidebar', 'close', 'n', M.close, vim.tbl_extend('force', options, { desc = 'Conductor: close sidebar' }))

  require('conductor.help').attach(state.bufnr)
end

function M.open()
  if window_valid() then
    vim.api.nvim_set_current_win(state.winid)
    return
  end

  if not buffer_valid() then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, 'conductor://sessions')
    vim.bo[state.bufnr].buftype = 'nofile'
    vim.bo[state.bufnr].bufhidden = 'hide'
    vim.bo[state.bufnr].swapfile = false
    vim.bo[state.bufnr].filetype = 'conductor'
    setup_keymaps()
  end

  -- If the all-sessions browser already owns the current tab, open the live
  -- sessions panel on a fresh tab so the two layouts don't fight over the
  -- same window space. Otherwise carve a left split out of the current tab.
  local width = require('conductor.config').options.sidebar.width
  if require('conductor.browser').is_open() then
    -- Fresh tab: empty main window on the right, sidebar split off its left.
    vim.cmd 'tabnew'
  end
  vim.cmd(('topleft %dvsplit'):format(width))
  state.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].signcolumn = 'no'
  vim.wo[state.winid].winfixwidth = true
  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].cursorline = true

  if not state.autocmd_id then
    state.autocmd_id = vim.api.nvim_create_autocmd('User', {
      pattern = 'ConductorUpdate',
      callback = function()
        M.render()
      end,
    })
  end

  -- Poll presence files for external sessions while the sidebar is open.
  -- Managed instances remain purely event-driven. The liveness probe runs
  -- asynchronously (see external.refresh_async) so it never blocks the UI
  -- thread; render() only ever reads the cached result.
  if not state.refresh_timer then
    state.refresh_timer = vim.uv.new_timer()
    state.refresh_timer:start(2000, 2000, vim.schedule_wrap(function()
      if not window_valid() then
        return
      end
      require('conductor.external').refresh_async {
        on_done = function()
          if window_valid() then
            M.render()
          end
        end,
      }
    end))
  end

  -- Kick off an initial async refresh, then render whatever is cached so far.
  require('conductor.external').refresh_async {
    interval_ms = 0,
    on_done = function()
      if window_valid() then
        M.render()
      end
    end,
  }
  M.render()
end

function M.close()
  if window_valid() then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
  if state.refresh_timer then
    state.refresh_timer:stop()
    state.refresh_timer:close()
    state.refresh_timer = nil
  end
end

function M.toggle()
  if window_valid() then
    M.close()
  else
    M.open()
  end
end

return M
