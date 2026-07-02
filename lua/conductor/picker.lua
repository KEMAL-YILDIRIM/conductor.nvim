---Backend-neutral picker core: session listing, display formatting, preview
---rendering, and the actions shared by telescope and fzf-lua frontends.
local M = {}

---Cache of rendered previews keyed by path, invalidated by mtime.
---@type table<string, { mtime: integer, lines: string[] }>
local preview_cache = {}

---@param unix_time integer
---@return string
function M.relative_time(unix_time)
  local delta = os.time() - unix_time
  if delta < 60 then
    return 'just now'
  elseif delta < 3600 then
    return ('%dm ago'):format(math.floor(delta / 60))
  elseif delta < 86400 then
    return ('%dh ago'):format(math.floor(delta / 3600))
  else
    return ('%dd ago'):format(math.floor(delta / 86400))
  end
end

---@param cwd string|nil
---@return string
function M.shorten_cwd(cwd)
  if not cwd then
    return ''
  end
  local home = vim.fs.normalize(vim.fn.expand '~')
  local normalized = vim.fs.normalize(cwd)
  if vim.startswith(normalized:lower(), home:lower()) then
    return '~' .. normalized:sub(#home + 1)
  end
  return normalized
end

---List sessions for the configured (or given) adapter.
---@param opts { cwd?: string, adapter?: string }|nil
---@return ConductorSession[] sessions, ConductorAdapter adapter
function M.list(opts)
  opts = opts or {}
  local conductor_config = require('conductor.config').options
  local interface = require 'conductor.adapters.interface'
  local adapter = interface.get(opts.adapter or conductor_config.default_adapter)
  return adapter.list_sessions { cwd = opts.cwd }, adapter
end

---Rendered preview lines for a session (mtime-cached).
---@param session ConductorSession
---@param adapter ConductorAdapter
---@return string[]
function M.preview_lines(session, adapter)
  local stat = vim.uv.fs_stat(session.path)
  local mtime = stat and stat.mtime.sec or 0
  local cached = preview_cache[session.path]
  if cached and cached.mtime == mtime then
    return cached.lines
  end

  local conductor_config = require('conductor.config').options
  local log_parser = require 'conductor.log_parser'
  local meta, entries = adapter.parse_log(session.path)
  local lines = log_parser.render_preview(meta, entries, {
    max_entries = conductor_config.picker.preview_max_entries,
    max_lines_per_entry = conductor_config.picker.preview_max_lines_per_entry,
  })
  preview_cache[session.path] = { mtime = mtime, lines = lines }
  return lines
end

--- Shared actions ----------------------------------------------------------

---Resume in a terminal (default action).
---@param session ConductorSession
function M.action_resume(session)
  require('conductor').resume(session)
end

---Attach as a managed RPC instance.
---@param session ConductorSession
function M.action_attach(session)
  local instance, spawn_error = require('conductor.supervisor').spawn {
    adapter = session.adapter,
    cwd = session.cwd,
    session_path = session.path,
    name = session.name,
  }
  if instance then
    require('conductor.sidebar').open()
    require('conductor.chatlog').open(instance)
  else
    vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
  end
end

---Open the raw session log file.
---@param session ConductorSession
function M.action_open_log(session)
  vim.cmd.edit(vim.fn.fnameescape(session.path))
end

---Open the session picker with the configured backend.
---@param opts { cwd?: string, adapter?: string, backend?: string }|nil
function M.open(opts)
  opts = opts or {}
  local backend = opts.backend or require('conductor.config').options.picker.backend

  if backend == 'fzf-lua' then
    local ok = pcall(require, 'fzf-lua')
    if ok then
      require('conductor.picker_fzf').open(opts)
      return
    end
    backend = 'telescope'
  end

  local ok, telescope = pcall(require, 'telescope')
  if not ok then
    vim.notify('conductor: no picker backend available (telescope.nvim or fzf-lua required)', vim.log.levels.ERROR)
    return
  end
  telescope.extensions.conductor.sessions(opts)
end

return M
