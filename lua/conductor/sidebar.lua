---Live sessions sidebar: one row per session with a color-coded status light.
---The selected managed session expands into a detail tree (model, thinking
---level, context window usage). Updates are pushed via the
---`User ConductorUpdate` autocmd (no polling for managed instances).
local M = {}

---One session row in the rendered panel. A collapsed row spans one line; the
---selected managed row also spans its detail lines (`first`..`last`).
---@class ConductorSidebarRow
---@field key string stable identity across renders ('i:<id>' / 'e:<pid>')
---@field instance_id integer|nil managed instance id
---@field external ConductorExternalSession|nil external (terminal) session
---@field first integer 1-based header line
---@field last integer 1-based last line (== first when collapsed)

local state = {
  bufnr = nil, ---@type integer|nil
  winid = nil, ---@type integer|nil
  ---Rows in display order.
  rows = {}, ---@type ConductorSidebarRow[]
  ---Maps every line a row spans (header + details) to that row.
  line_to_row = {}, ---@type table<integer, ConductorSidebarRow>
  ---Key of the expanded (selected) row.
  selected_key = nil, ---@type string|nil
  autocmd_id = nil, ---@type integer|nil
  refresh_timer = nil, ---@type uv.uv_timer_t|nil
}

local led_icon = '●'

local status_led_groups = {
  starting = 'ConductorLedStarting',
  idle = 'ConductorLedIdle',
  streaming = 'ConductorLedRunning',
  needs_input = 'ConductorLedWaiting',
  error = 'ConductorLedError',
  exited = 'ConductorLedExited',
}

local status_labels = {
  starting = 'starting',
  idle = 'idle',
  streaming = 'running',
  needs_input = 'waiting',
  error = 'error',
  exited = 'exited',
}

local namespace = vim.api.nvim_create_namespace 'conductor_sidebar'

---Status-light colors plus the dimmed text groups. `default = true` so
---user-defined groups win; re-run on ColorScheme (which clears highlights).
local function ensure_highlights()
  local function define(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  define('ConductorLedRunning', { fg = '#4fa6ed' })
  define('ConductorLedWaiting', { fg = '#8bcd5b' })
  define('ConductorLedIdle', { fg = '#a0784e' })
  define('ConductorLedStarting', { fg = '#e5c07b' })
  define('ConductorLedError', { fg = '#e86671' })
  define('ConductorLedExited', { fg = '#5c6370' })
  define('ConductorSidebarStatus', { link = 'Comment' })
  define('ConductorSidebarLabel', { link = 'Comment' })
  define('ConductorSidebarTree', { link = 'NonText' })
  define('ConductorSidebarSection', { link = 'Title' })
end

ensure_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('conductor_sidebar_highlights', { clear = true }),
  callback = ensure_highlights,
})

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

---Shorten `text` to at most `max_width` display cells, ending in '…'.
---@param text string
---@param max_width integer
---@return string
local function truncate(text, max_width)
  if max_width < 1 then
    return ''
  end
  if vim.fn.strdisplaywidth(text) <= max_width then
    return text
  end
  for count = vim.fn.strchars(text) - 1, 0, -1 do
    local candidate = vim.fn.strcharpart(text, 0, count) .. '…'
    if vim.fn.strdisplaywidth(candidate) <= max_width then
      return candidate
    end
  end
  return ''
end

---Compact token count: 60000 → '60k', 1048576 → '1.0M'.
---@param count number
---@return string
local function short_count(count)
  if count >= 1000000 then
    return ('%.1fM'):format(count / 1000000)
  elseif count >= 1000 then
    return ('%dk'):format(math.floor(count / 1000 + 0.5))
  end
  return tostring(math.floor(count))
end

---Render an info field: `nil` = still loading, `false` = absent.
---@param value any
---@param absent string
---@return string
local function info_text(value, absent)
  if value == nil then
    return '…'
  elseif value == false then
    return absent
  end
  return value
end

---@param context { tokens: number|nil, window: number|nil, percent: number|nil }|false|nil
---@return string
local function context_text(context)
  if context == nil then
    return '…'
  elseif context == false or not context.window then
    return '—'
  elseif not context.tokens then
    -- Unknown right after a compaction until the next turn.
    return ('? / %s'):format(short_count(context.window))
  end
  local percent = context.percent or (context.tokens / context.window * 100)
  return ('%s / %s (%d%%)'):format(short_count(context.tokens), short_count(context.window), math.floor(percent + 0.5))
end

---@param instance ConductorInstance
---@return string
local function instance_status_label(instance)
  if instance.status == 'exited' and instance.exit_code then
    return ('exited (%d)'):format(instance.exit_code)
  end
  return status_labels[instance.status] or instance.status
end

---Detail lines shown under the selected managed session.
---@param instance ConductorInstance
---@return { label: string, value: string }[]
local function instance_details(instance)
  local info = instance.info or {}
  return {
    { label = 'model', value = info_text(info.model, 'none') },
    { label = 'thinking', value = info_text(info.thinking, '—') },
    { label = 'context', value = context_text(info.context) },
  }
end

function M.render()
  if not buffer_valid() then
    return
  end
  local supervisor = require 'conductor.supervisor'
  local instances = supervisor.list()
  local all_externals = require('conductor.external').list_cached()

  -- Remember which row the cursor sits on (and how far into it) so the cursor
  -- stays on the same session even when rows above expand or collapse.
  local cursor_key, cursor_offset
  if window_valid() and vim.api.nvim_win_get_buf(state.winid) == state.bufnr then
    local cursor_line = vim.api.nvim_win_get_cursor(state.winid)[1]
    local row = state.line_to_row[cursor_line]
    if row then
      cursor_key = row.key
      cursor_offset = cursor_line - row.first
    end
  end
  local previous_selected = state.selected_key

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

  -- Selection follows the cursor; fall back to the previous selection, then
  -- to the first session when the selected one has gone away.
  local existing_keys = {}
  local first_key
  for _, instance in ipairs(instances) do
    local key = 'i:' .. instance.id
    existing_keys[key] = true
    first_key = first_key or key
  end
  for _, external in ipairs(externals) do
    local key = 'e:' .. external.pid
    existing_keys[key] = true
    first_key = first_key or key
  end
  local selected = cursor_key or previous_selected
  if not (selected and existing_keys[selected]) then
    selected = first_key
  end
  state.selected_key = selected

  local width = window_valid() and vim.api.nvim_win_get_width(state.winid) or require('conductor.config').options.sidebar.width

  local lines = { ' Conductor', '' }
  ---@type { line: integer, start_col: integer, end_col: integer, group: string }[]
  local spans = {}
  ---@type { line: integer, text: string }[]
  local status_marks = {}
  local section_lines = { 0 }
  state.rows = {}
  state.line_to_row = {}

  ---Append a session header line: ' ● name' with a right-aligned status.
  ---@param row ConductorSidebarRow
  ---@param name string
  ---@param status string
  ---@param label string
  local function add_header(row, name, status, label)
    local prefix = ' ' .. led_icon .. ' '
    local name_width = width - vim.fn.strdisplaywidth(prefix) - vim.fn.strdisplaywidth(label) - 2
    lines[#lines + 1] = prefix .. truncate(name, name_width)
    row.first = #lines
    row.last = #lines
    spans[#spans + 1] = { line = #lines - 1, start_col = 1, end_col = 1 + #led_icon, group = status_led_groups[status] or 'ConductorLedExited' }
    status_marks[#status_marks + 1] = { line = #lines - 1, text = label }
  end

  ---Append the detail tree under the selected managed session.
  ---@param row ConductorSidebarRow
  ---@param instance ConductorInstance
  local function add_details(row, instance)
    local details = instance_details(instance)
    for index, detail in ipairs(details) do
      local branch = index == #details and '└' or '├'
      local indent = '   '
      local label = ('%-9s'):format(detail.label)
      lines[#lines + 1] = indent .. branch .. ' ' .. label .. ' ' .. detail.value
      local branch_start = #indent
      local label_start = branch_start + #branch + 1
      spans[#spans + 1] = { line = #lines - 1, start_col = branch_start, end_col = branch_start + #branch, group = 'ConductorSidebarTree' }
      spans[#spans + 1] = { line = #lines - 1, start_col = label_start, end_col = label_start + #label, group = 'ConductorSidebarLabel' }
    end
    row.last = #lines
  end

  if #instances == 0 and #externals == 0 then
    lines[#lines + 1] = '  no live sessions'
    lines[#lines + 1] = ''
    lines[#lines + 1] = '  n: new session'
    lines[#lines + 1] = '  q: close'
  else
    if #instances > 0 then
      lines[#lines + 1] = ' Managed'
      section_lines[#section_lines + 1] = #lines - 1
      for _, instance in ipairs(instances) do
        ---@type ConductorSidebarRow
        local row = { key = 'i:' .. instance.id, instance_id = instance.id, first = 0, last = 0 }
        add_header(row, instance.name, instance.status, instance_status_label(instance))
        if row.key == selected then
          add_details(row, instance)
        end
        state.rows[#state.rows + 1] = row
      end
    end
    if #externals > 0 then
      if #instances > 0 then
        lines[#lines + 1] = ''
      end
      lines[#lines + 1] = ' External (terminal)'
      section_lines[#section_lines + 1] = #lines - 1
      for _, external in ipairs(externals) do
        ---@type ConductorSidebarRow
        local row = { key = 'e:' .. external.pid, external = external, first = 0, last = 0 }
        local label = ('%s · pid %d'):format(status_labels[external.status] or external.status, external.pid)
        add_header(row, external.name, external.status, label)
        state.rows[#state.rows + 1] = row
      end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = ' <CR>: open chat  n: new'
    lines[#lines + 1] = ' p: prompt  s: stop  x: kill  q: close'
  end

  for _, row in ipairs(state.rows) do
    for line = row.first, row.last do
      state.line_to_row[line] = row
    end
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
  for _, line in ipairs(section_lines) do
    vim.api.nvim_buf_set_extmark(state.bufnr, namespace, line, 0, { end_row = line, end_col = #lines[line + 1], hl_group = 'ConductorSidebarSection' })
  end
  for _, span in ipairs(spans) do
    vim.api.nvim_buf_set_extmark(state.bufnr, namespace, span.line, span.start_col, { end_col = span.end_col, hl_group = span.group })
  end
  for _, mark in ipairs(status_marks) do
    vim.api.nvim_buf_set_extmark(state.bufnr, namespace, mark.line, 0, {
      virt_text = { { mark.text, 'ConductorSidebarStatus' } },
      virt_text_pos = 'right_align',
    })
  end

  -- Put the cursor back on its session: same offset when that session was
  -- already the expanded one (push update), else on the new row's header.
  if cursor_key and window_valid() and vim.api.nvim_win_get_buf(state.winid) == state.bufnr then
    for _, row in ipairs(state.rows) do
      if row.key == cursor_key then
        local offset = cursor_key == previous_selected and cursor_offset or 0
        local target = math.min(row.first + offset, row.last)
        if vim.api.nvim_win_get_cursor(state.winid)[1] ~= target then
          vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
        end
        break
      end
    end
  end
end

---@return ConductorSidebarRow|nil
local function row_at_cursor()
  if not window_valid() then
    return nil
  end
  return state.line_to_row[vim.api.nvim_win_get_cursor(state.winid)[1]]
end

---@return ConductorInstance|nil
local function instance_at_cursor()
  local row = row_at_cursor()
  if row and row.instance_id then
    return require('conductor.supervisor').instances[row.instance_id]
  end
  return nil
end

---Move the cursor to the next (`direction` = 1) or previous (-1) session
---header, `v:count1` times. Past the last/first session it falls back to a
---plain line motion so the footer stays reachable.
---@param direction 1|-1
local function jump(direction)
  if not window_valid() then
    return
  end
  for _ = 1, vim.v.count1 do
    local line = vim.api.nvim_win_get_cursor(state.winid)[1]
    local target
    for _, row in ipairs(state.rows) do
      if direction > 0 and row.first > line then
        target = row.first
        break
      elseif direction < 0 and row.first < line then
        target = row.first
      end
    end
    if target then
      vim.api.nvim_win_set_cursor(state.winid, { target, 0 })
    else
      vim.cmd('normal! ' .. (direction > 0 and 'j' or 'k'))
    end
  end
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
    local row = row_at_cursor()
    local external = row and row.external
    if external and external.session_file then
      local supervisor = require 'conductor.supervisor'
      local existing = supervisor.find_by_session(external.session_file)
      if existing then
        -- Revive an exited instance on its session file before showing it.
        supervisor.restart(existing)
        require('conductor.chatlog').open(existing)
        return
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

  config.map('sidebar', 'next_session', 'n', function()
    jump(1)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: next session' }))

  config.map('sidebar', 'prev_session', 'n', function()
    jump(-1)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: previous session' }))

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
    -- Expand whichever session the cursor lands on (any motion, mouse too).
    vim.api.nvim_create_autocmd('CursorMoved', {
      buffer = state.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() ~= state.winid then
          return
        end
        local row = row_at_cursor()
        if row and row.key ~= state.selected_key then
          M.render()
        end
      end,
    })
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

  -- Land on the selected (expanded) session's header.
  for _, row in ipairs(state.rows) do
    if row.key == state.selected_key then
      vim.api.nvim_win_set_cursor(state.winid, { row.first, 0 })
      break
    end
  end
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
