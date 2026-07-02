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

---Per-instance window/buffer state, keyed by instance id.
---@type table<integer, { log_win: integer|nil, input_buf: integer|nil, input_win: integer|nil, tool_lines: table<integer, integer> }>
local views = {}

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

---Re-render the chat buffer if it exists; follows tail unless user scrolled up.
---@param instance ConductorInstance
function M.refresh(instance)
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
  vim.api.nvim_buf_set_lines(view.input_buf, 0, -1, false, {})
  require('conductor.supervisor').prompt(instance, text)
end

---Create the input bar below the given log window.
---@param instance ConductorInstance
---@param log_window integer
local function open_input_bar(instance, log_window)
  local view = view_for(instance)
  if window_valid(view.input_win) then
    return
  end

  if not buffer_valid(view.input_buf) then
    view.input_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(view.input_buf, ('conductor://input/%d'):format(instance.id))
    vim.bo[view.input_buf].buftype = 'nofile'
    vim.bo[view.input_buf].bufhidden = 'hide'
    vim.bo[view.input_buf].swapfile = false
    vim.bo[view.input_buf].filetype = 'markdown'

    local options = { buffer = view.input_buf, nowait = true }
    vim.keymap.set({ 'n', 'i' }, '<CR>', function()
      submit_input(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: send prompt' }))
    vim.keymap.set('i', '<S-CR>', '<CR>', vim.tbl_extend('force', options, { desc = 'Conductor: newline' }))
    vim.keymap.set({ 'n', 'i' }, '<C-k>', function()
      vim.cmd 'stopinsert'
      if window_valid(view.log_win) then
        vim.api.nvim_set_current_win(view.log_win)
      end
    end, vim.tbl_extend('force', options, { desc = 'Conductor: focus log' }))
    vim.keymap.set('n', 'q', function()
      M.close(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: close chat' }))
  end

  vim.api.nvim_set_current_win(log_window)
  vim.cmd 'belowright 5split'
  view.input_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view.input_win, view.input_buf)
  vim.wo[view.input_win].number = false
  vim.wo[view.input_win].relativenumber = false
  vim.wo[view.input_win].signcolumn = 'no'
  vim.wo[view.input_win].winfixheight = true
  vim.wo[view.input_win].winbar = '%#Comment# prompt — <CR> send · <S-CR> newline · <C-k> log '
end

---Close chat + input windows (buffers survive for reopening).
---@param instance ConductorInstance
function M.close(instance)
  local view = view_for(instance)
  if window_valid(view.input_win) then
    vim.api.nvim_win_close(view.input_win, true)
  end
  if window_valid(view.log_win) then
    vim.api.nvim_win_close(view.log_win, true)
  end
  view.input_win = nil
  view.log_win = nil
end

---Focus the input bar in insert mode.
---@param instance ConductorInstance
function M.input_prompt(instance)
  M.open(instance)
  local view = view_for(instance)
  if window_valid(view.input_win) then
    vim.api.nvim_set_current_win(view.input_win)
    vim.cmd 'startinsert'
  end
end

---Open (or focus) the chat view for an instance.
---@param instance ConductorInstance
function M.open(instance)
  local view = view_for(instance)

  if buffer_valid(instance.chat_bufnr) and window_valid(view.log_win) then
    vim.api.nvim_set_current_win(view.log_win)
    return
  end

  if not buffer_valid(instance.chat_bufnr) then
    local bufnr = vim.api.nvim_create_buf(false, true)
    instance.chat_bufnr = bufnr
    vim.api.nvim_buf_set_name(bufnr, ('conductor://chat/%d'):format(instance.id))
    vim.bo[bufnr].buftype = 'nofile'
    vim.bo[bufnr].bufhidden = 'hide'
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = 'markdown'
    vim.bo[bufnr].modifiable = false

    local options = { buffer = bufnr, nowait = true }
    vim.keymap.set('n', 'i', function()
      M.input_prompt(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: focus input' }))
    vim.keymap.set('n', '<CR>', function()
      toggle_tool_at_cursor(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: toggle tool output' }))
    vim.keymap.set('n', ']t', function()
      jump_tool(instance, 1)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: next tool call' }))
    vim.keymap.set('n', '[t', function()
      jump_tool(instance, -1)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: previous tool call' }))
    vim.keymap.set('n', '<C-c>', function()
      require('conductor.supervisor').abort(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: abort agent' }))
    vim.keymap.set('n', 'q', function()
      M.close(instance)
    end, vim.tbl_extend('force', options, { desc = 'Conductor: close chat' }))
  end

  vim.cmd 'vsplit'
  view.log_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(view.log_win, instance.chat_bufnr)
  vim.wo[view.log_win].wrap = true
  vim.wo[view.log_win].linebreak = true
  vim.wo[view.log_win].number = false
  vim.wo[view.log_win].relativenumber = false
  vim.wo[view.log_win].signcolumn = 'no'

  open_input_bar(instance, view.log_win)
  vim.api.nvim_set_current_win(view.log_win)
  M.refresh(instance)
end

return M
