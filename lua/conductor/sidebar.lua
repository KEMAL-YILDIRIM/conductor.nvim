---Live sessions sidebar: one row per session with a color-coded status light.
---Session details (model, thinking level, context usage) live in the chat
---input window's statusline (see `conductor.statusline`). Updates are pushed
---via the `User ConductorUpdate` autocmd (no polling for managed instances).
local M = {}

---One session row (a single line) in the rendered panel.
---@class ConductorSidebarRow
---@field key string stable identity across renders ('i:<id>' / 'e:<pid>')
---@field instance_id integer|nil managed instance id
---@field external ConductorExternalSession|nil external (terminal) session
---@field first integer 1-based line of the row
---@field status_label string|nil status word shown in the details float
---@field todo { done: integer, total: integer }|nil todo progress
---@field changes integer|nil changed files in the session folder (nil = unknown)

local state = {
  bufnr = nil, ---@type integer|nil
  winid = nil, ---@type integer|nil
  ---Rows in display order.
  rows = {}, ---@type ConductorSidebarRow[]
  ---Maps each row's line to that row.
  line_to_row = {}, ---@type table<integer, ConductorSidebarRow>
  ---Key of the selected row (follows the cursor).
  selected_key = nil, ---@type string|nil
  ---Key of the row whose session is shown in the chat (highlighted).
  active_key = nil, ---@type string|nil
  autocmd_id = nil, ---@type integer|nil
  resize_autocmd_id = nil, ---@type integer|nil
  refresh_timer = nil, ---@type uv.uv_timer_t|nil
}

---The session-details float opened with `K`.
local details = {
  winid = nil, ---@type integer|nil
  ---Sidebar line the float was opened for; moving off it closes the float.
  line = nil, ---@type integer|nil
}

local led_icon = '●'

local status_led_groups = {
  starting = 'ConductorLedStarting',
  idle = 'ConductorLedIdle',
  streaming = 'ConductorLedRunning',
  needs_input = 'ConductorLedWaiting',
  error = 'ConductorLedError',
  exited = 'ConductorLedExited',
  readonly = 'ConductorLedExited',
}

local status_labels = require('conductor.statusline').status_labels

local namespace = vim.api.nvim_create_namespace 'conductor_sidebar'

---Status-light colors plus the dimmed text groups. `default = true` so
---user-defined groups win; re-run on ColorScheme (which clears highlights).
local function ensure_highlights()
  local function define(name, spec)
    spec.default = true
    vim.api.nvim_set_hl(0, name, spec)
  end
  define('ConductorLedRunning', { fg = '#8bcd5b' })
  define('ConductorLedWaiting', { fg = '#4fa6ed' })
  define('ConductorLedIdle', { fg = '#a0784e' })
  define('ConductorLedStarting', { fg = '#e5c07b' })
  define('ConductorLedError', { fg = '#e86671' })
  define('ConductorLedExited', { fg = '#5c6370' })
  define('ConductorSidebarStatus', { link = 'Comment' })
  define('ConductorSidebarSection', { link = 'Title' })

  -- Session shown in the chat: a teal wash blended into Normal's background
  -- across the row (background only, so the status light keeps its colour)
  -- plus a lighter (not bold) name, visible whatever the cursor or focus is
  -- doing.
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local function split(color)
    return math.floor(color / 0x10000) % 0x100, math.floor(color / 0x100) % 0x100, color % 0x100
  end
  local function clamp(value)
    return math.max(0, math.min(255, math.floor(value + 0.5)))
  end
  ---Blend `accent` into `base` by `alpha` (0..1 = accent weight).
  local function blend(base, accent, alpha)
    local base_red, base_green, base_blue = split(base)
    local accent_red, accent_green, accent_blue = split(accent)
    return clamp(base_red + (accent_red - base_red) * alpha) * 0x10000
      + clamp(base_green + (accent_green - base_green) * alpha) * 0x100
      + clamp(base_blue + (accent_blue - base_blue) * alpha)
  end
  if type(normal.bg) == 'number' then
    local red, green, blue = split(normal.bg)
    local dark = (0.299 * red + 0.587 * green + 0.114 * blue) < 128
    local foreground = type(normal.fg) == 'number' and normal.fg or (dark and 0xc8c8c8 or 0x383838)
    define('ConductorSidebarActive', { bg = blend(normal.bg, 0x2fb6c9, 0.24) })
    define('ConductorSidebarActiveName', { fg = blend(foreground, dark and 0xffffff or 0x000000, 0.6) })
  else
    -- No known background: borrow only Visual's background, never its text colour.
    local visual = vim.api.nvim_get_hl(0, { name = 'Visual', link = false })
    define('ConductorSidebarActive', { bg = visual.bg })
    define('ConductorSidebarActiveName', {})
  end
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

---Sidebar width in columns. `sidebar.width` is either a fraction of the
---editor width (0 < width < 1, at least 24 columns) or a column count.
---@return integer
local function resolve_width()
  local configured = require('conductor.config').options.sidebar.width
  if type(configured) ~= 'number' or configured <= 0 then
    return 36
  end
  if configured < 1 then
    return math.max(24, math.floor(vim.o.columns * configured))
  end
  return math.floor(configured)
end

---Resize the sidebar window to its configured width (no-op when closed).
function M.apply_width()
  if window_valid() then
    vim.api.nvim_win_set_width(state.winid, resolve_width())
  end
end

local function close_details()
  if details.winid and vim.api.nvim_win_is_valid(details.winid) then
    vim.api.nvim_win_close(details.winid, true)
  end
  details.winid = nil
  details.line = nil
end

---Re-render and move the sidebar cursor onto the session the chat shows
---(without focusing the sidebar). Called by the chat when it opens a session.
function M.reveal()
  if not (buffer_valid() and window_valid()) then
    return
  end
  M.render()
  for _, row in ipairs(state.rows) do
    if row.key == state.active_key then
      if vim.api.nvim_win_get_cursor(state.winid)[1] ~= row.first then
        close_details()
        vim.api.nvim_win_set_cursor(state.winid, { row.first, 0 })
      end
      state.selected_key = row.key
      return
    end
  end
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


function M.render()
  if not buffer_valid() then
    return
  end
  local supervisor = require 'conductor.supervisor'
  local instances = supervisor.list()
  local all_externals = require('conductor.external').list_cached()

  -- Remember which row the cursor sits on so the cursor stays on the same
  -- session even when rows above appear or disappear.
  local cursor_key
  if window_valid() and vim.api.nvim_win_get_buf(state.winid) == state.bufnr then
    local row = state.line_to_row[vim.api.nvim_win_get_cursor(state.winid)[1]]
    if row then
      cursor_key = row.key
    end
  end
  local previous_selected = state.selected_key

  -- Dedupe: a session lives on the panel once. A running managed instance
  -- (one with an agent process) wins over the External row for the same
  -- session file. A stopped one (e.g. restored on startup, `handle == nil`)
  -- must not hide a live terminal pi: show the External row and hide the
  -- stopped placeholder instead.
  -- Todo progress by session file, from every presence file (Conductor's own
  -- RPC instances write one too), before duplicates are hidden below.
  local todo_by_session = {}
  for _, external in ipairs(all_externals) do
    local key = supervisor.session_key(external.session_file)
    if key and external.todo then
      todo_by_session[key] = external.todo
    end
  end

  local running_session_paths = {}
  for _, instance in ipairs(instances) do
    local key = supervisor.session_key(instance.session_path)
    if key and instance.handle then
      running_session_paths[key] = true
    end
  end
  local externals = {}
  local external_session_paths = {}
  for _, external in ipairs(all_externals) do
    local key = supervisor.session_key(external.session_file)
    if not (key and running_session_paths[key]) then
      externals[#externals + 1] = external
      if key then
        external_session_paths[key] = true
      end
    end
  end
  local visible_instances = {}
  for _, instance in ipairs(instances) do
    local key = supervisor.session_key(instance.session_path)
    if instance.handle or not (key and external_session_paths[key]) then
      visible_instances[#visible_instances + 1] = instance
    end
  end
  instances = visible_instances

  -- The row whose session the chat is showing. A managed instance hidden in
  -- favour of a live terminal row maps onto that External row instead.
  local active_key
  local current = require('conductor.chatlog').current_instance()
  if current then
    for _, instance in ipairs(instances) do
      if instance.id == current.id then
        active_key = 'i:' .. instance.id
        break
      end
    end
    local current_session = not active_key and supervisor.session_key(current.session_path)
    if current_session then
      for _, external in ipairs(externals) do
        if supervisor.session_key(external.session_file) == current_session then
          active_key = 'e:' .. external.pid
          break
        end
      end
    end
  end
  state.active_key = active_key

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

  local width = window_valid() and vim.api.nvim_win_get_width(state.winid) or resolve_width()

  local lines = { ' Conductor', '' }
  ---@type { line: integer, start_col: integer, end_col: integer, group: string }[]
  local spans = {}
  local section_lines = { 0 }
  state.rows = {}
  state.line_to_row = {}

  ---Append a session line: ' ● name'. Everything else (status, todo
  ---progress, changes, paths, first prompt) lives in the `K` details float,
  ---so the name gets the whole width.
  ---@param row ConductorSidebarRow
  ---@param name string
  ---@param status string
  local function add_header(row, name, status)
    local prefix = ' ' .. led_icon .. ' '
    local name_width = width - vim.fn.strdisplaywidth(prefix) - 1
    lines[#lines + 1] = prefix .. truncate(name, name_width)
    row.first = #lines
    spans[#spans + 1] = { line = #lines - 1, start_col = 1, end_col = 1 + #led_icon, group = status_led_groups[status] or 'ConductorLedExited' }
  end

  ---Changed files in the session folder, counted in the background (see
  ---conductor.review); re-renders once a count changes so the details float
  ---reads a fresh value. nil while unknown.
  ---@param cwd string|nil
  ---@return integer|nil
  local function change_count(cwd)
    return require('conductor.review').cached_count(cwd, function()
      if buffer_valid() then
        M.render()
      end
    end)
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
        local row = {
          key = 'i:' .. instance.id,
          instance_id = instance.id,
          first = 0,
          status_label = require('conductor.statusline').status_label(instance),
          todo = todo_by_session[supervisor.session_key(instance.session_path) or ''],
          changes = change_count(instance.cwd),
        }
        add_header(row, instance.name, instance.status)
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
        local row = {
          key = 'e:' .. external.pid,
          external = external,
          first = 0,
          status_label = status_labels[external.status] or external.status,
          todo = external.todo,
          changes = change_count(external.cwd),
        }
        add_header(row, external.name, external.status)
        state.rows[#state.rows + 1] = row
      end
    end
    lines[#lines + 1] = ''
    lines[#lines + 1] = ' K: details  g?: keys'
  end

  for _, row in ipairs(state.rows) do
    state.line_to_row[row.first] = row
  end

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false

  vim.api.nvim_buf_clear_namespace(state.bufnr, namespace, 0, -1)
  for _, line in ipairs(section_lines) do
    vim.api.nvim_buf_set_extmark(state.bufnr, namespace, line, 0, { end_row = line, end_col = #lines[line + 1], hl_group = 'ConductorSidebarSection' })
  end
  for _, span in ipairs(spans) do
    -- Above the active-row highlight so the status light keeps its colour.
    vim.api.nvim_buf_set_extmark(state.bufnr, namespace, span.line, span.start_col, { end_col = span.end_col, hl_group = span.group, priority = 4200 })
  end
  for _, row in ipairs(state.rows) do
    if row.key == active_key then
      vim.api.nvim_buf_set_extmark(state.bufnr, namespace, row.first - 1, 0, { line_hl_group = 'ConductorSidebarActive' })
      -- Lighter text on the name only (after ' ● '), never on the light.
      local name_start = #(' ' .. led_icon .. ' ')
      vim.api.nvim_buf_set_extmark(state.bufnr, namespace, row.first - 1, name_start, {
        end_col = #lines[row.first],
        hl_group = 'ConductorSidebarActiveName',
      })
      break
    end
  end

  -- Put the cursor back on its session's row.
  if cursor_key and window_valid() and vim.api.nvim_win_get_buf(state.winid) == state.bufnr then
    for _, row in ipairs(state.rows) do
      if row.key == cursor_key then
        if vim.api.nvim_win_get_cursor(state.winid)[1] ~= row.first then
          vim.api.nvim_win_set_cursor(state.winid, { row.first, 0 })
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

---Float beside the sidebar with everything the row leaves out: status,
---process, todo progress, changed files, full file path, folder and the full
---first prompt. Pressing `K` again while it is open focuses it.
---@param row ConductorSidebarRow
local function show_details(row)
  if details.winid and vim.api.nvim_win_is_valid(details.winid) then
    vim.api.nvim_set_current_win(details.winid)
    return
  end

  local name, cwd, path, process
  if row.instance_id then
    local instance = require('conductor.supervisor').instances[row.instance_id]
    if not instance then
      return
    end
    name, cwd, path = instance.name, instance.cwd, instance.session_path
  elseif row.external then
    name, cwd, path = row.external.name, row.external.cwd, row.external.session_file
    process = ('pid %d · terminal'):format(row.external.pid)
  else
    return
  end

  local prompt
  if path and vim.uv.fs_stat(path) then
    local ok, meta = pcall(require('conductor.log_parser').scan_meta, path)
    if ok and type(meta) == 'table' then
      prompt = meta.first_user_text
    end
  end

  local changes = '(not available)'
  if row.changes then
    changes = row.changes == 0 and 'none' or ('%d %s'):format(row.changes, row.changes == 1 and 'file' or 'files')
  end
  local fields = {
    { 'Session', name or '?' },
    { 'Status', row.status_label or '?' },
    process and { 'Process', process } or nil,
    row.todo and { 'Todo', ('%d/%d done'):format(row.todo.done, row.todo.total) } or nil,
    { 'Changes', changes },
    { 'File', path or '(no session file yet)' },
    { 'Folder', cwd or '?' },
  }
  local lines = {}
  local label_ends = {}
  for index = 1, 7 do
    local field = fields[index]
    if field then
      lines[#lines + 1] = ('%-9s %s'):format(field[1] .. ':', field[2])
      label_ends[#lines] = #field[1] + 1
    end
  end
  lines[#lines + 1] = ''
  lines[#lines + 1] = 'First prompt:'
  local prompt_heading = #lines
  for _, line in ipairs(vim.split(prompt or '(no prompt yet)', '\n', { plain = true })) do
    lines[#lines + 1] = (line:gsub('\r$', ''))
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  for line, end_col in pairs(label_ends) do
    vim.api.nvim_buf_set_extmark(bufnr, namespace, line - 1, 0, { end_col = end_col, hl_group = 'ConductorSidebarSection' })
  end
  vim.api.nvim_buf_set_extmark(bufnr, namespace, prompt_heading - 1, 0, { end_col = #lines[prompt_heading], hl_group = 'ConductorSidebarSection' })

  -- Beside the sidebar, level with the cursor row, wrapped to fit the screen.
  local sidebar_width = vim.api.nvim_win_get_width(state.winid)
  local position = vim.fn.win_screenpos(state.winid)
  local widest = 0
  for _, line in ipairs(lines) do
    widest = math.max(widest, vim.fn.strdisplaywidth(line))
  end
  local width = math.max(20, math.min(widest, vim.o.columns - (position[2] - 1) - sidebar_width - 4))
  local height = 0
  for _, line in ipairs(lines) do
    height = height + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / width))
  end
  height = math.max(1, math.min(height, vim.o.lines - 4))
  local top = position[1] - 1 + vim.fn.winline() - 1
  top = math.max(0, math.min(top, vim.o.lines - height - 4))

  details.winid = vim.api.nvim_open_win(bufnr, false, {
    relative = 'editor',
    row = top,
    col = position[2] - 1 + sidebar_width,
    width = width,
    height = height,
    style = 'minimal',
    border = 'rounded',
    title = ' Session details ',
  })
  details.line = vim.api.nvim_win_get_cursor(state.winid)[1]
  vim.wo[details.winid].wrap = true
  vim.wo[details.winid].linebreak = true

  for _, key in ipairs { 'q', '<Esc>', 'K' } do
    vim.keymap.set('n', key, close_details, { buffer = bufnr, nowait = true, desc = 'Conductor: close session details' })
  end
  -- Leaving the focused float closes it.
  vim.api.nvim_create_autocmd('WinLeave', {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(close_details)
    end,
  })
end

local function setup_keymaps()
  local config = require 'conductor.config'
  local options = { buffer = state.bufnr, nowait = true }

  local function open_chat_at_cursor()
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
        supervisor.restart(existing, { quiet = true })
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
  end

  config.map('sidebar', 'open_chat', 'n', open_chat_at_cursor, vim.tbl_extend('force', options, { desc = 'Conductor: open chat' }))
  config.map('sidebar', 'enter', 'n', open_chat_at_cursor, vim.tbl_extend('force', options, { desc = 'Conductor: enter session' }))

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
      local instance, spawn_error = require('conductor.supervisor').spawn { name = name ~= '' and name or nil, name_explicit = name ~= '' }
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

  ---Folder and name of the session under the cursor (managed or external).
  ---@return string|nil cwd, string|nil name
  local function session_folder_at_cursor()
    local instance = instance_at_cursor()
    if instance then
      return instance.cwd, instance.name
    end
    local row = row_at_cursor()
    if row and row.external then
      return row.external.cwd, row.external.name
    end
    return nil, nil
  end

  config.map('sidebar', 'review', 'n', function()
    local cwd = session_folder_at_cursor()
    if cwd then
      require('conductor.review').diff(cwd)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: review changes in diffview' }))

  config.map('sidebar', 'edit_changes', 'n', function()
    local cwd, name = session_folder_at_cursor()
    if cwd then
      require('conductor.review').edit(cwd, name)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: edit changed files in a new tab' }))

  config.map('sidebar', 'details', 'n', function()
    local row = row_at_cursor()
    if row then
      show_details(row)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: session details (full first prompt, file path)' }))

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
    -- Selection follows the cursor (any motion, mouse too).
    vim.api.nvim_create_autocmd('CursorMoved', {
      buffer = state.bufnr,
      callback = function()
        if vim.api.nvim_get_current_win() ~= state.winid then
          return
        end
        local row = row_at_cursor()
        if row then
          state.selected_key = row.key
        end
        -- The details float belongs to one row; moving off it closes it.
        if details.line and vim.api.nvim_win_get_cursor(state.winid)[1] ~= details.line then
          close_details()
        end
      end,
    })
  end

  -- Always open on a dedicated tab so the user's working tab is never split
  -- or resized: empty main window on the right, sidebar split off its left.
  local width = resolve_width()
  require('conductor.tabs').open_dedicated()
  vim.cmd(('topleft %dvsplit'):format(width))
  state.winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.winid, state.bufnr)
  vim.wo[state.winid].number = false
  vim.wo[state.winid].relativenumber = false
  vim.wo[state.winid].signcolumn = 'no'
  vim.wo[state.winid].winfixwidth = true
  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].cursorline = true

  -- Keep a fractional width proportional when the editor is resized.
  if not state.resize_autocmd_id then
    state.resize_autocmd_id = vim.api.nvim_create_autocmd('VimResized', {
      callback = function()
        M.apply_width()
      end,
    })
  end

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

  -- Land on the selected session's row.
  for _, row in ipairs(state.rows) do
    if row.key == state.selected_key then
      vim.api.nvim_win_set_cursor(state.winid, { row.first, 0 })
      break
    end
  end
end

function M.close()
  close_details()
  -- Tear down the dedicated tab when it holds only the sidebar (or the blank
  -- scratch); otherwise close just the sidebar window.
  local closed_tab = require('conductor.tabs').close_if_owned(state.winid, function(window)
    return window == state.winid
  end)
  if not closed_tab and window_valid() then
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
