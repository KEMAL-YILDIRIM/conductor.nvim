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

-- No git folder, so the change count stays empty and only the todo suffix shows.
local folder = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(folder, 'p')

local supervisor = require 'conductor.supervisor'
supervisor.list = function()
  return { { id = 1, name = 'managed', status = 'idle', cwd = folder, session_path = 'managed.jsonl', handle = {} } }
end
supervisor.session_key = function(path)
  return path
end
supervisor.instances = {}
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
local labels = {}
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buffer, -1, 0, -1, { details = true })) do
  local virtual_text = mark[4].virt_text
  if virtual_text then
    labels[vim.trim(lines[mark[2] + 1]):gsub('^●%s*', '')] = virtual_text[1][1]
  end
end

check(labels.managed == 'idle · 2/5', 'managed session shows progress from its presence file (got ' .. tostring(labels.managed) .. ')')
check(labels.tab and labels.tab:match ' · 3/7$', 'terminal session shows its progress (got ' .. tostring(labels.tab) .. ')')
check(labels.plain and not labels.plain:match '%d+/%d+', 'session without a list shows no progress (got ' .. tostring(labels.plain) .. ')')

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
