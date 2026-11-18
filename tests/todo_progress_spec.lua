-- Headless checks for todo progress in the sidebar. Run from the repository root:
--   nvim -u NONE -l tests/todo_progress_spec.lua
-- Stubs the supervisor and the presence cache, renders the sidebar, and checks
-- the status labels. Exits non-zero on the first failure.
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

-- No git folder, so the change count stays unknown and only the todo progress shows.
local folder = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(folder, 'p')

local supervisor = require 'conductor.supervisor'
local managed_instance = { id = 1, name = 'managed', status = 'idle', cwd = folder, session_path = 'managed.jsonl', handle = {} }
supervisor.list = function()
  return { managed_instance }
end
supervisor.session_key = function(path)
  return path
end
supervisor.instances = { [1] = managed_instance }
require('conductor.statusline').status_label = function()
  return 'idle'
end
require('conductor.external').list_cached = function()
  return {
    -- Presence file of the managed RPC instance: hidden as a row, but its progress is used.
    { pid = 10, status = 'idle', session_file = 'managed.jsonl', name = 'managed', cwd = folder, mode = 'rpc', todo = { done = 2, total = 5 } },
    { pid = 20, status = 'streaming', session_file = 'tab.jsonl', name = 'tab', cwd = folder, mode = 'tui', todo = { done = 3, total = 7 } },
    { pid = 30, status = 'idle', session_file = 'plain.jsonl', name = 'plain', cwd = folder, mode = 'tui' },
  }
end

local sidebar = require 'conductor.sidebar'
local ok, open_error = pcall(sidebar.open)
check(ok, 'sidebar opens' .. (ok and '' or (': ' .. tostring(open_error))))

local buffer = vim.fn.bufnr 'conductor://sessions'
local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
-- Rows hold only the status light and the name; progress lives in the K float.
local sidebar_win = vim.fn.bufwinid(buffer)
local todo_lines = {}
for index, line in ipairs(lines) do
  local name = line:match '^ ● (.+)$'
  if name then
    check(name == vim.trim(name) and not name:find('·', 1, true), 'row shows only icon and name (' .. name .. ')')
    vim.api.nvim_set_current_win(sidebar_win)
    vim.api.nvim_win_set_cursor(sidebar_win, { index, 0 })
    vim.api.nvim_feedkeys('K', 'x', false)
    for _, window in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if vim.api.nvim_win_get_config(window).relative ~= '' then
        for _, float_line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(window), 0, -1, false)) do
          if float_line:match '^Todo:' then
            todo_lines[name] = float_line
          end
        end
        vim.api.nvim_win_close(window, true)
      end
    end
  end
end

check(todo_lines.managed == 'Todo:     2/5 done', 'managed session shows progress from its presence file (got ' .. tostring(todo_lines.managed) .. ')')
check(todo_lines.tab == 'Todo:     3/7 done', 'terminal session shows its progress (got ' .. tostring(todo_lines.tab) .. ')')
check(todo_lines.plain == nil, 'session without a list shows no progress (got ' .. tostring(todo_lines.plain) .. ')')

local count = 0
for _, line in ipairs(lines) do
  if line:match 'managed' then
    count = count + 1
  end
end
check(count == 1, 'managed session appears once')

vim.fn.delete(folder, 'rf')
print(failures == 0 and 'all checks passed' or (failures .. ' check(s) failed'))
os.exit(failures == 0 and 0 or 1)
