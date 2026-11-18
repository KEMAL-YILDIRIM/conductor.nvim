-- Headless checks for conductor.review. Run from the repository root:
--   nvim -u NONE -l tests/review_spec.lua
-- Builds temporary repositories (a main checkout plus a linked worktree) and
-- exits non-zero on the first failure.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path
for name in pairs(package.loaded) do
  if name:match '^conductor' then
    package.loaded[name] = nil
  end
end
local review = require 'conductor.review'

local failures = 0
local function check(condition, message)
  if condition then
    print('ok    ' .. message)
  else
    failures = failures + 1
    print('FAIL  ' .. message)
  end
end

local function run(cwd, ...)
  local result = vim.system({ 'git', '-C', cwd, ... }, { text = true }):wait()
  assert(result.code == 0, table.concat({ ... }, ' ') .. ': ' .. (result.stderr or ''))
  return vim.trim(result.stdout or '')
end

local root = vim.fs.normalize(vim.fn.tempname()) .. ' review spec'
vim.fn.mkdir(root, 'p')
local primary = root .. '/repo'
local worktree = root .. '/repo.worktrees/task'
vim.fn.mkdir(primary, 'p')
run(primary, 'init', '-q', '-b', 'main')
for key, value in pairs { ['user.name'] = 'test', ['user.email'] = 'test@example.invalid', ['commit.gpgsign'] = 'false', ['core.autocrlf'] = 'false' } do
  run(primary, 'config', key, value)
end
vim.fn.writefile({ 'one' }, primary .. '/kept.txt')
vim.fn.writefile({ 'gone' }, primary .. '/removed.txt')
run(primary, 'add', '.')
run(primary, 'commit', '-q', '-m', 'initial')
run(primary, 'worktree', 'add', '-q', worktree, '-b', 'agent/task')

-- The worktree: one committed change, one deletion, one untracked file.
vim.fn.writefile({ 'one', 'two' }, worktree .. '/kept.txt')
run(worktree, 'rm', '-q', 'removed.txt')
run(worktree, 'commit', '-q', '-am', 'work')
vim.fn.writefile({ 'new' }, worktree .. '/new file.txt')
-- The main checkout moves on; the merge-base must stay at 'initial'.
vim.fn.writefile({ 'main' }, primary .. '/main-only.txt')
run(primary, 'add', '.')
run(primary, 'commit', '-q', '-m', 'main moves on')
local initial = run(primary, 'rev-parse', 'HEAD~1')

-- resolve
local target, resolve_error = review.resolve(worktree)
check(target ~= nil, 'resolve a linked worktree' .. (resolve_error and (': ' .. resolve_error) or ''))
check(target and target.base == initial, 'worktree base is the merge-base with the main branch')
check(target and target.base_label:match 'agent/task' and target.base_label:match 'main', 'base label names both branches')

local primary_target = review.resolve(primary)
check(primary_target and primary_target.base == 'HEAD', 'main checkout compares against HEAD')

local _, not_repository = review.resolve(root)
check(not_repository and not_repository:match 'not a git repository', 'folder outside git is refused')
local _, no_folder = review.resolve(nil)
check(no_folder ~= nil, 'missing folder is refused')

-- changed_files
local files = target and review.changed_files(target) or {}
local by_path = {}
for _, file in ipairs(files) do
  by_path[file.path] = file.status
end
check(#files == 3, ('three changed files (got %d)'):format(#files))
check(by_path['kept.txt'] == 'M', 'modified file listed')
check(by_path['removed.txt'] == 'D', 'deleted file listed')
check(by_path['new file.txt'] == '?', 'untracked file with a space listed')
check(by_path['main-only.txt'] == nil, 'changes made only on main are not listed')

-- cached_count: nil at first, filled in by the background refresh
review.clear_cache()
local changed = false
check(review.cached_count(worktree, function() changed = true end) == nil, 'count is unknown before the refresh')
vim.wait(10000, function() return changed end, 20)
check(changed, 'background refresh reports a change')
check(review.cached_count(worktree) == 3, 'cached count is 3')

-- edit: new tab rooted at the worktree, quickfix without the deleted file
local tabs_before = #vim.api.nvim_list_tabpages()
review.edit(worktree, 'task')
check(#vim.api.nvim_list_tabpages() == tabs_before + 1, 'edit opens a new tab')
check(vim.fs.normalize(vim.fn.getcwd(-1, 0)):lower() == vim.fs.normalize(worktree):lower(), 'new tab is rooted at the worktree')
local quickfix = vim.fn.getqflist { items = 1, title = 1 }
check(#quickfix.items == 2, ('quickfix has the two openable files (got %d)'):format(#quickfix.items))
check(quickfix.title:match 'task', 'quickfix title names the session')

-- detached HEAD
run(worktree, 'checkout', '-q', '--detach')
local _, detached = review.resolve(worktree)
check(detached and detached:match 'detached', 'detached HEAD is refused')

-- diff without diffview installed reports instead of failing
local messages = {}
local original_notify = vim.notify
vim.notify = function(message) messages[#messages + 1] = message end
review.diff(worktree)
vim.notify = original_notify
check(messages[1] and messages[1]:match 'diffview', 'diff without diffview shows a notification')

vim.cmd 'silent! %bwipeout!'
vim.cmd 'cd ~'
vim.fn.delete(root, 'rf')
print(failures == 0 and 'all checks passed' or (failures .. ' check(s) failed'))
os.exit(failures == 0 and 0 or 1)
