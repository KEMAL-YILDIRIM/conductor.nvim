-- Headless checks for the sidebar width and the session-details float. Run
-- from the repository root:
--   nvim -u NONE -l tests/sidebar_width_details_spec.lua
-- Exits non-zero on the first failure.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
for name in pairs(package.loaded) do
  if name:match '^conductor' then
    package.loaded[name] = nil
  end
end

local failures = 0
local function check(condition, message)
  if condition then
    print('ok    ' .. message)
  else
    failures = failures + 1
    print('FAIL  ' .. message)
  end
end

vim.o.columns = 200
vim.o.lines = 50

-- A session file whose first prompt spans several lines.
local folder = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(folder, 'p')
local session_path = folder .. '/session.jsonl'
local first_prompt = 'first line of a long prompt that must not be truncated\nsecond line'
vim.fn.writefile({
  vim.json.encode { type = 'session', id = 'abc', cwd = folder, timestamp = '2026-11-18T10:00:00Z' },
  vim.json.encode {
    type = 'message',
    id = 'm1',
    timestamp = '2026-11-18T10:00:01Z',
    message = { role = 'user', content = { { type = 'text', text = first_prompt } } },
  },
}, session_path)

local supervisor = require 'conductor.supervisor'
local instance = { id = 1, name = 'managed', status = 'idle', cwd = folder, session_path = session_path, handle = {}, log = {}, partial = '' }
supervisor.instances[1] = instance
local other = { id = 2, name = 'other', status = 'idle', cwd = folder, handle = {}, log = {}, partial = '' }
supervisor.instances[2] = other
supervisor.list = function()
  return { instance, other }
end
local external = require 'conductor.external'
external.list_cached = function()
  return {}
end
external.refresh_async = function() end
require('conductor.review').cached_count = function()
  return nil
end

require('conductor').setup { sidebar = { persist = false } }
local sidebar = require 'conductor.sidebar'

sidebar.open()
local sidebar_win = vim.api.nvim_get_current_win()
check(vim.api.nvim_win_get_width(sidebar_win) == 40, 'sidebar opens at 20% (40 of 200 columns)')

-- Close the right-hand window (as closing the chat does), then reopen the chat.
vim.cmd 'wincmd l'
vim.cmd 'close'
check(vim.api.nvim_win_get_width(sidebar_win) == 200, 'sidebar fills the tab once alone (precondition)')
vim.api.nvim_set_current_win(sidebar_win)
require('conductor.chatlog').open(instance)
check(vim.api.nvim_win_get_width(sidebar_win) == 40, 'sidebar back at 20% after the chat reopens')

vim.o.columns = 250
vim.api.nvim_exec_autocmds('VimResized', {})
check(vim.api.nvim_win_get_width(sidebar_win) == 50, 'sidebar follows an editor resize (50 of 250)')

-- The session shown in the chat is highlighted on the sidebar.
local function active_rows()
  local buffer = vim.fn.bufnr 'conductor://sessions'
  local buffer_lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  local result = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })) do
    if mark[4].line_hl_group == 'ConductorSidebarActive' then
      result[#result + 1] = buffer_lines[mark[2] + 1]
    end
  end
  return result
end
local active = active_rows()
check(#active == 1 and active[1] == ' ● managed', 'loaded session is highlighted (got ' .. vim.inspect(active) .. ')')
require('conductor.chatlog').open(other)
active = active_rows()
check(#active == 1 and active[1] == ' ● other', 'highlight follows the chat to another session (got ' .. vim.inspect(active) .. ')')
local cursor_line = vim.api.nvim_buf_get_lines(vim.fn.bufnr 'conductor://sessions', 0, -1, false)[vim.api.nvim_win_get_cursor(sidebar_win)[1]]
check(cursor_line == ' ● other', 'sidebar cursor moves to the loaded session')
check(vim.api.nvim_get_current_win() ~= sidebar_win, 'focus stays in the chat')
local highlight = vim.api.nvim_get_hl(0, { name = 'ConductorSidebarActive' })
check(not highlight.bold, 'highlight is not bold')
check(highlight.fg == nil, 'row highlight has no text colour (keeps the status light colour)')
local led_group
do
  local buffer = vim.fn.bufnr 'conductor://sessions'
  local active_line = vim.api.nvim_win_get_cursor(sidebar_win)[1] - 1
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, -1, { active_line, 0 }, { active_line, -1 }, { details = true })) do
    if mark[3] == 1 and mark[4].hl_group and mark[4].hl_group:match '^ConductorLed' then
      led_group = mark[4].hl_group
    end
  end
end
check(led_group == 'ConductorLedIdle', 'status light on the loaded row keeps its status colour (got ' .. tostring(led_group) .. ')')
require('conductor.chatlog').close(other)
check(#active_rows() == 0, 'no highlight once the chat is closed')
vim.api.nvim_set_current_win(sidebar_win)
require('conductor.chatlog').open(instance)

-- Shift+K on the session row.
vim.api.nvim_set_current_win(sidebar_win)
local session_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  if line:find('managed', 1, true) and not line:find('Managed', 1, true) then
    session_line = index
    check(line == ' ● managed', 'row shows only icon and name (got [' .. line .. '])')
  end
end
vim.api.nvim_win_set_cursor(sidebar_win, { session_line, 0 })
vim.api.nvim_feedkeys('K', 'x', false)

local float
for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
  if vim.api.nvim_win_get_config(window).relative ~= '' then
    float = window
  end
end
check(float ~= nil, 'K opens the details float')
if float then
  local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(float), 0, -1, false), '\n')
  check(text:find(session_path, 1, true) ~= nil, 'float shows the full session file path')
  check(text:find(first_prompt, 1, true) ~= nil, 'float shows the full first prompt')
  check(text:find('Status:', 1, true) ~= nil, 'float shows the status')
  check(text:find('Changes:', 1, true) ~= nil, 'float shows the changed-file count')
  check(text:find('Folder:   ' .. folder, 1, true) ~= nil, 'float shows the folder')
  check(vim.api.nvim_get_current_win() == sidebar_win, 'focus stays in the sidebar')
end

sidebar.close()
check(not (float and vim.api.nvim_win_is_valid(float)), 'closing the sidebar closes the float')

vim.fn.delete(folder, 'rf')
if failures > 0 then
  print(('%d check(s) failed'):format(failures))
  vim.cmd 'cquit 1'
end
print 'all checks passed'
vim.cmd 'qall!'
