---Review and edit an agent's work from the live sessions sidebar.
---
---A session's folder is compared against the point its branch split from the
---main checkout's current branch (in a linked worktree), or against HEAD (in
---the main checkout itself). The comparison is with the working tree, so both
---committed and uncommitted work shows up.
---
---  diff(cwd)       open the changes in diffview; the right-hand side is the
---                  real file, so edits land directly in the agent's folder
---  edit(cwd)       open the folder in a new tab with the changed files in the
---                  quickfix list
---  cached_count()  number of changed files, computed in the background and
---                  cached so rendering the sidebar never waits on git
local M = {}

local GIT_TIMEOUT_MS = 10000
---How long a change count stays fresh before it is recomputed.
local COUNT_TTL_MS = 15000

local STATUS_LABELS = {
  A = 'added',
  M = 'modified',
  T = 'type changed',
  ['?'] = 'new (untracked)',
}

---@class ConductorReviewTarget
---@field root string repository root of the session's folder
---@field base string commit (or 'HEAD') the working tree is compared against
---@field base_label string human-readable description of `base`

---@class ConductorChangedFile
---@field status string git status letter ('A', 'M', 'D', 'T'), or '?' for untracked
---@field path string path relative to the repository root

---Run git in `cwd`. Inside a coroutine it yields until git finishes, so the
---UI never blocks; outside one it waits synchronously.
---@param cwd string
---@param args string[]
---@return boolean ok, string stdout, string stderr
local function git(cwd, args)
  local command = { 'git', '-c', 'core.quotePath=false', '-C', cwd }
  vim.list_extend(command, args)
  local options = { text = true, timeout = GIT_TIMEOUT_MS }
  local result
  local co = coroutine.running()
  if co then
    local started, error_message = pcall(vim.system, command, options, function(completed)
      vim.schedule(function()
        coroutine.resume(co, completed)
      end)
    end)
    if not started then
      return false, '', tostring(error_message)
    end
    result = coroutine.yield()
  else
    local started, process = pcall(vim.system, command, options)
    if not started then
      return false, '', tostring(process)
    end
    result = process:wait()
  end
  return result.code == 0, vim.trim(result.stdout or ''), vim.trim(result.stderr or '')
end

---@param first string
---@param second string
---@return boolean
local function same_path(first, second)
  local function key(path)
    path = vim.fs.normalize(path)
    if vim.fn.has 'win32' == 1 then
      path = path:lower()
    end
    return path
  end
  return key(first) == key(second)
end

---@param message string
---@param level integer|nil
local function notify(message, level)
  vim.notify('conductor: ' .. message, level or vim.log.levels.WARN)
end

---Find the repository of `cwd` and the commit its changes are compared against.
---@param cwd string|nil
---@return ConductorReviewTarget|nil target, string|nil error
function M.resolve(cwd)
  if not cwd or cwd == '' then
    return nil, 'this session has no folder'
  end
  local root_ok, root = git(cwd, { 'rev-parse', '--show-toplevel' })
  if not root_ok or root == '' then
    return nil, 'not a git repository: ' .. cwd
  end
  local branch_ok, branch = git(root, { 'symbolic-ref', '--short', '-q', 'HEAD' })
  if not branch_ok then
    return nil, 'HEAD is detached in ' .. root
  end
  local common_ok, common = git(root, { 'rev-parse', '--path-format=absolute', '--git-common-dir' })
  if not common_ok then
    return nil, 'cannot find the git directory of ' .. root
  end
  common = vim.fs.normalize(common)
  -- A bare or separate git directory has no main checkout to compare with.
  if vim.fs.basename(common) ~= '.git' then
    return { root = root, base = 'HEAD', base_label = 'HEAD of ' .. branch }
  end
  local primary = vim.fs.dirname(common)
  if same_path(primary, root) then
    return { root = root, base = 'HEAD', base_label = 'HEAD of ' .. branch }
  end
  local primary_ok, primary_branch = git(primary, { 'symbolic-ref', '--short', '-q', 'HEAD' })
  if not primary_ok then
    return nil, 'HEAD is detached in the main checkout ' .. primary
  end
  local merge_ok, merge_base = git(root, { 'merge-base', primary_branch, 'HEAD' })
  if not merge_ok or merge_base == '' then
    return nil, ('%s has no common history with %s'):format(branch, primary_branch)
  end
  return { root = root, base = merge_base, base_label = ('where %s branched from %s'):format(branch, primary_branch) }
end

---Files that differ between `target.base` and the working tree, plus untracked files.
---@param target ConductorReviewTarget
---@return ConductorChangedFile[]|nil files, string|nil error
function M.changed_files(target)
  local diff_ok, diff, diff_error = git(target.root, { 'diff', '--name-status', '--no-renames', target.base })
  if not diff_ok then
    return nil, diff_error ~= '' and diff_error or 'git diff failed in ' .. target.root
  end
  local files = {}
  for line in diff:gmatch '[^\r\n]+' do
    local status, path = line:match '^(%a)%d*\t(.+)$'
    if status then
      files[#files + 1] = { status = status, path = path }
    end
  end
  local untracked_ok, untracked = git(target.root, { 'ls-files', '--others', '--exclude-standard' })
  if untracked_ok then
    for path in untracked:gmatch '[^\r\n]+' do
      files[#files + 1] = { status = '?', path = path }
    end
  end
  return files
end

---Open the changes of the session folder `cwd` in diffview, in a new tab.
---@param cwd string|nil
function M.diff(cwd)
  local has_diffview, diffview = pcall(require, 'diffview')
  if not has_diffview then
    notify('diffview.nvim is not installed; use edit to see the changed files instead', vim.log.levels.ERROR)
    return
  end
  local target, resolve_error = M.resolve(cwd)
  if not target then
    notify(resolve_error or 'cannot review this session')
    return
  end
  local files, files_error = M.changed_files(target)
  if not files then
    notify(files_error or 'cannot list changes')
    return
  end
  if #files == 0 then
    notify(('no changes in %s since %s'):format(target.root, target.base_label), vim.log.levels.INFO)
    return
  end
  -- The Lua API takes the arguments as a list, so a root with spaces needs no escaping.
  diffview.open { target.base, '-C' .. target.root }
end

---Open the session folder `cwd` in a new tab, with its changed files in the
---quickfix list (deleted files are left out, as there is nothing to open).
---@param cwd string|nil
---@param name string|nil session name, used in the quickfix title
function M.edit(cwd, name)
  local target, resolve_error = M.resolve(cwd)
  if not target then
    notify(resolve_error or 'cannot open this session')
    return
  end
  local files, files_error = M.changed_files(target)
  if not files then
    notify(files_error or 'cannot list changes')
    return
  end
  local items = {}
  for _, file in ipairs(files) do
    if file.status ~= 'D' then
      items[#items + 1] = {
        filename = target.root .. '/' .. file.path,
        lnum = 1,
        text = STATUS_LABELS[file.status] or file.status,
      }
    end
  end
  vim.cmd 'tabnew'
  vim.cmd('tcd ' .. vim.fn.fnameescape(target.root))
  local title = ('Conductor: %s changes since %s'):format(name or vim.fs.basename(target.root), target.base_label)
  vim.fn.setqflist({}, ' ', { title = title, items = items })
  if #items == 0 then
    notify(('no changed files in %s since %s'):format(target.root, target.base_label), vim.log.levels.INFO)
    return
  end
  vim.cmd 'cfirst'
  vim.cmd 'copen'
  vim.cmd 'wincmd p'
end

---@type table<string, { count: integer|nil, updated: number, pending: boolean }>
local count_cache = {}

---Number of changed files in the session folder `cwd`, or nil while unknown.
---Returns the cached value at once; when it is older than COUNT_TTL_MS a
---background refresh starts, and `on_change` runs if the count changed.
---@param cwd string|nil
---@param on_change fun()|nil
---@return integer|nil
function M.cached_count(cwd, on_change)
  if not cwd or cwd == '' then
    return nil
  end
  local entry = count_cache[cwd]
  if not entry then
    entry = { count = nil, updated = -math.huge, pending = false }
    count_cache[cwd] = entry
  end
  if not entry.pending and vim.uv.now() - entry.updated >= COUNT_TTL_MS then
    entry.pending = true
    coroutine.wrap(function()
      local ok, count = pcall(function()
        local target = M.resolve(cwd)
        local files = target and M.changed_files(target)
        return files and #files or nil
      end)
      count = ok and count or nil
      local changed = count ~= entry.count
      entry.count, entry.updated, entry.pending = count, vim.uv.now(), false
      if changed and on_change then
        on_change()
      end
    end)()
  end
  return entry.count
end

---Forget all cached counts (used by tests).
function M.clear_cache()
  count_cache = {}
end

return M
