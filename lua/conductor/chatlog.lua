---Per-instance chat view: markdown-rendered conversation with collapsible
---tool-call entries and a persistent multi-line input bar below the log.
---
---@class ConductorChatEntry
---@field role 'user'|'assistant'|'system'|'tool'
---@field text string message text, or tool name for role='tool'
---@field summary string|nil tool args one-liner (role='tool')
---@field output string|nil tool output (role='tool', set on tool_end)
---@field running boolean|nil tool still executing
---@field is_error boolean|nil tool failed
---@field expanded boolean|nil tool output unfolded in the view
local M = {}

---Per-instance buffer/state, keyed by instance id. The chat log and input
---*windows* are shared across all instances (see `shell` below): only one chat
---window pair is ever visible; opening another instance swaps its buffers in.
---@type table<integer, { input_buf: integer|nil, tool_lines: table<integer, integer>, refresh_timer: uv.uv_timer_t|nil, refresh_pending: boolean|nil, last_render: integer|nil }>
local views = {}

---Shared chat "shell": a single log window + input window reused by every
---instance. `instance` is whichever instance is currently displayed.
---@type { log_win: integer|nil, input_win: integer|nil, instance: ConductorInstance|nil }
local shell = { log_win = nil, input_win = nil, instance = nil }

local function view_for(instance)
  views[instance.id] = views[instance.id] or { tool_lines = {} }
  return views[instance.id]
end

local function window_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function buffer_valid(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer)
end

---@param instance ConductorInstance
---@return string[] lines, table<integer, integer> tool_lines map of line-number -> log index
local function render_lines(instance)
  local lines = {}
  local tool_lines = {}
  local function add(text)
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end

  add(('# %s  `%s`'):format(instance.name, instance.status))
  if instance.readonly then
    add '> read-only: this session runs in a terminal pi without the conductor bridge.'
    add '> Update conductor-presence and restart that pi to chat from here.'
  end
  add ''
  for index, entry in ipairs(instance.log) do
    if entry.role == 'user' then
      add '## You'
      add(entry.text)
      add ''
    elseif entry.role == 'assistant' then
      add '## Agent'
      add(entry.text)
      add ''
    elseif entry.role == 'tool' then
      local marker
      if entry.running then
        marker = '…'
      elseif entry.is_error then
        marker = '✗'
      else
        marker = entry.expanded and '▼' or '▶'
      end
      local label = entry.summary ~= '' and ('%s `%s`'):format(entry.text, entry.summary) or entry.text
      add(('> %s %s'):format(marker, label))
      tool_lines[#lines] = index
      if entry.expanded and entry.output and entry.output ~= '' then
        add '```'
        add(entry.output)
        add '```'
      end
      add ''
    else
      add('> ' .. entry.text:gsub('\n', '\n> '))
      add ''
    end
  end
  if instance.partial ~= '' then
    add '## Agent'
    add(instance.partial)
  end
  return lines, tool_lines
end

---Minimum interval between chat re-renders while streaming. Streaming emits one
---`text_delta` per token, and each render rebuilds the whole buffer (O(log)), so
---rendering per-token makes long conversations lag. We coalesce bursts into at
---most one render per interval, with a guaranteed trailing render for final state.
local REFRESH_INTERVAL_MS = 60

---Immediately rebuild the chat buffer; follows tail unless user scrolled up.
---@param instance ConductorInstance
local function do_render(instance)
  if not buffer_valid(instance.chat_bufnr) then
    return
  end
  local view = view_for(instance)
  local bufnr = instance.chat_bufnr
  local lines, tool_lines = render_lines(instance)
  view.tool_lines = tool_lines

  -- Detect whether each window showing the log is at the tail before redraw.
  local tail_windows = {}
  local old_line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, window in ipairs(vim.fn.win_findbuf(bufnr)) do
    local cursor_row = vim.api.nvim_win_get_cursor(window)[1]
    tail_windows[window] = cursor_row >= old_line_count - 1
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  for window, was_at_tail in pairs(tail_windows) do
    if was_at_tail and vim.api.nvim_win_is_valid(window) then
      vim.api.nvim_win_set_cursor(window, { #lines, 0 })
    end
  end
end

---Throttled re-render: renders immediately if enough time has elapsed since the
---last render, otherwise schedules a single trailing render. This keeps streaming
---smooth without dropping the final state.
---@param instance ConductorInstance
function M.refresh(instance)
  if not buffer_valid(instance.chat_bufnr) then
    return
  end
  local view = view_for(instance)
  local now = vim.uv.now()
  local elapsed = now - (view.last_render or 0)

  if elapsed >= REFRESH_INTERVAL_MS then
    if view.refresh_timer then
      view.refresh_timer:stop()
      view.refresh_pending = false
    end
    view.last_render = now
    do_render(instance)
    return
  end

  -- A render happened recently; coalesce this call into a single trailing render.
  if view.refresh_pending then
    return
  end
  view.refresh_pending = true
  view.refresh_timer = view.refresh_timer or vim.uv.new_timer()
  view.refresh_timer:start(
    REFRESH_INTERVAL_MS - elapsed,
    0,
    vim.schedule_wrap(function()
      view.refresh_pending = false
      view.last_render = vim.uv.now()
      do_render(instance)
    end)
  )
end

---Toggle the tool entry under the cursor.
---@param instance ConductorInstance
local function toggle_tool_at_cursor(instance)
  local view = view_for(instance)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  -- Search current line, then scan upward to the nearest tool line.
  local log_index = view.tool_lines[cursor_row]
  if not log_index then
    for row = cursor_row - 1, 1, -1 do
      if view.tool_lines[row] then
        log_index = view.tool_lines[row]
        break
      end
    end
  end
  if not log_index then
    return
  end
  local entry = instance.log[log_index]
  if entry and entry.role == 'tool' and not entry.running then
    entry.expanded = not entry.expanded
    M.refresh(instance)
  end
end

---Jump to the next/previous tool line.
---@param instance ConductorInstance
---@param direction 1|-1
local function jump_tool(instance, direction)
  local view = view_for(instance)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for row in pairs(view.tool_lines) do
    if direction == 1 and row > cursor_row and (not best or row < best) then
      best = row
    elseif direction == -1 and row < cursor_row and (not best or row > best) then
      best = row
    end
  end
  if best then
    vim.api.nvim_win_set_cursor(0, { best, 0 })
  end
end

local ensure_input_buf -- defined below; `set_input` needs it first

---Send the input buffer contents as a prompt.
---@param instance ConductorInstance
local function submit_input(instance)
  local view = view_for(instance)
  if not buffer_valid(view.input_buf) then
    return
  end
  local input_lines = vim.api.nvim_buf_get_lines(view.input_buf, 0, -1, false)
  local text = vim.trim(table.concat(input_lines, '\n'))
  if text == '' then
    return
  end
  -- Built-in commands may refuse the input (unknown command, agent busy):
  -- keep the text so it can be fixed instead of retyped.
  if require('conductor.supervisor').submit(instance, text) then
    vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, {})
  end
end

---Replace the input bar's text (e.g. the message restored by `/fork`) and
---focus it when this instance is the one on screen.
---@param instance ConductorInstance
---@param text string
function M.set_input(instance, text)
  local view = view_for(instance)
  local bufnr = ensure_input_buf(instance)
  local lines = vim.split(text, '\n', { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  if shell.instance == instance and window_valid(shell.input_win) and vim.api.nvim_win_get_buf(shell.input_win) == view.input_buf then
    vim.api.nvim_set_current_win(shell.input_win)
    vim.api.nvim_win_set_cursor(shell.input_win, { #lines, #lines[#lines] })
  end
end

---Ensure the per-instance input buffer (with its keymaps) exists.
---@param instance ConductorInstance
---@return integer input_buf
function ensure_input_buf(instance)
  local view = view_for(instance)
  if buffer_valid(view.input_buf) then
    return view.input_buf
  end

  view.input_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(view.input_buf, ('conductor://input/%d'):format(instance.id))
  vim.bo[view.input_buf].buftype = 'nofile'
  vim.bo[view.input_buf].bufhidden = 'hide'
  vim.bo[view.input_buf].swapfile = false
  -- Own filetype so completion plugins see a dedicated buffer (no markdown
  -- path/buffer sources on `/`); markdown highlighting via `syntax` only.
  local completion = require 'conductor.completion'
  vim.bo[view.input_buf].filetype = completion.FILETYPE
  vim.bo[view.input_buf].syntax = 'markdown'
  vim.b[view.input_buf].conductor_instance_id = instance.id
  completion.attach(view.input_buf)

  local config = require 'conductor.config'
  local options = { buffer = view.input_buf, nowait = true }
  config.map('input', 'send', { 'n', 'i' }, function()
    -- With a completion menu open, <CR> accepts the item instead of sending.
    if vim.api.nvim_get_mode().mode:sub(1, 1) == 'i' and completion.accept_if_open() then
      return
    end
    submit_input(instance)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: send prompt / run command' }))
  config.map('input', 'newline', 'i', '<CR>', vim.tbl_extend('force', options, { desc = 'Conductor: newline' }))
  config.map('input', 'focus_log', { 'n', 'i' }, function()
    completion.close_if_open()
    vim.cmd 'stopinsert'
    if window_valid(shell.log_win) then
      vim.api.nvim_set_current_win(shell.log_win)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: focus log' }))
  config.map('input', 'abort', { 'n', 'i' }, function()
    -- First press only closes an open completion menu.
    if completion.close_if_open() then
      return
    end
    require('conductor.supervisor').abort(instance)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: stop agent' }))
  config.map('input', 'close', 'n', function()
    M.close(instance)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: close chat' }))

  require('conductor.help').attach(view.input_buf)
  return view.input_buf
end

---Close the shared chat + input windows (buffers survive for reopening).
---@param instance ConductorInstance
function M.close(instance)
  local view = view_for(instance)
  if view.refresh_timer then
    view.refresh_timer:stop()
    view.refresh_timer:close()
    view.refresh_timer = nil
    view.refresh_pending = false
  end
  if window_valid(shell.input_win) then
    vim.api.nvim_win_close(shell.input_win, true)
  end
  if window_valid(shell.log_win) then
    vim.api.nvim_win_close(shell.log_win, true)
  end
  shell.input_win = nil
  shell.log_win = nil
  shell.instance = nil
end

---Focus the input bar in insert mode.
---@param instance ConductorInstance
function M.input_prompt(instance)
  M.open(instance)
  if window_valid(shell.input_win) then
    vim.api.nvim_set_current_win(shell.input_win)
    vim.cmd 'startinsert'
  end
end

---Swap the given instance's chat + input buffers into the shared shell windows.
---@param instance ConductorInstance
local function display_in_shell(instance)
  vim.api.nvim_win_set_buf(shell.log_win, instance.chat_bufnr)
  vim.api.nvim_win_set_buf(shell.input_win, ensure_input_buf(instance))
  shell.instance = instance
end

---Open (or focus) the chat view for an instance. There is only ever one chat
---window pair; opening a different instance reuses it, swapping buffers in.
---@param instance ConductorInstance
---@param opts { reuse_win?: integer }|nil when `reuse_win` is a valid window,
---adopt it as the log pane (splitting the prompt below it) instead of opening a
---fresh vsplit — lets the browser replace its log-preview pane in place.
function M.open(instance, opts)
  opts = opts or {}
  if not buffer_valid(instance.chat_bufnr) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    instance.chat_bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, ('conductor://chat/%d'):format(instance.id))
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].modifiable = false

    local config = require 'conductor.config'
    local options = { buffer = bufnr, nowait = true }
    config.map('chat', 'focus_input', 'n', function()
      M.input_prompt(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: focus input' }))
    config.map('chat', 'toggle_tool', 'n', function()
      toggle_tool_at_cursor(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: toggle tool output' }))
    config.map('chat', 'next_tool', 'n', function()
      jump_tool(instance, 1)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: next tool call' }))
    config.map('chat', 'prev_tool', 'n', function()
      jump_tool(instance, -1)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: previous tool call' }))
    config.map('chat', 'abort', 'n', function()
      require('conductor.supervisor').abort(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: abort agent' }))
    config.map('chat', 'close', 'n', function()
      M.close(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: close chat' }))

    require('conductor.help').attach(bufnr)
  end

  -- Shell already open: just swap this instance's buffers into the shared
  -- windows and focus the log. No new split.
  if window_valid(shell.log_win) and window_valid(shell.input_win) then
    display_in_shell(instance)
    vim.api.nvim_set_current_win(shell.log_win)
    M.refresh(instance)
    return
  end

  -- First open: build the shared shell (log window + input bar below it).
  -- When handed an existing window (e.g. the browser's log-preview pane),
  -- adopt it in place so the chat *replaces* that pane instead of adding a
  -- fresh vsplit alongside it. Otherwise adopt the *current* window so the
  -- chat opens in place — except when the current window is the sidebar,
  -- which must stay put: reuse the window to its right, splitting one off
  -- only if there is nothing there yet.
  if window_valid(opts.reuse_win) then
    vim.api.nvim_set_current_win(opts.reuse_win)
    shell.log_win = opts.reuse_win
  elseif require('conductor.sidebar').is_window(vim.api.nvim_get_current_win()) then
    local sidebar_win = vim.api.nvim_get_current_win()
    vim.cmd 'wincmd l'
    if vim.api.nvim_get_current_win() == sidebar_win then
      -- No neighbour to the right: carve one out.
      vim.cmd 'rightbelow vsplit'
    end
    shell.log_win = vim.api.nvim_get_current_win()
  else
    shell.log_win = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(shell.log_win, instance.chat_bufnr)
  vim.wo[shell.log_win].wrap = true
  vim.wo[shell.log_win].linebreak = true
  vim.wo[shell.log_win].number = false
  vim.wo[shell.log_win].relativenumber = false
  vim.wo[shell.log_win].signcolumn = 'no'

  vim.cmd 'belowright 5split'
  shell.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(shell.input_win, ensure_input_buf(instance))
  vim.wo[shell.input_win].number = false
  vim.wo[shell.input_win].relativenumber = false
  vim.wo[shell.input_win].signcolumn = 'no'
  vim.wo[shell.input_win].winfixheight = true
  vim.wo[shell.input_win].winbar = '%#Comment# prompt — <CR> send · <S-CR> newline · / commands · !cmd shell · <C-c> stop · <C-k> log '

  shell.instance = instance
  vim.api.nvim_set_current_win(shell.log_win)
  M.refresh(instance)
end

---Whether the given window is one of the shared chat shell windows (log or
---input). Lets other panels (e.g. the browser) avoid clobbering a live chat
---that is sharing their layout.
---@param window integer|nil
---@return boolean
function M.is_shell_window(window)
  return window ~= nil and (window == shell.log_win or window == shell.input_win)
end

return M
