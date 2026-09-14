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

---Relative-time label for an ISO 8601 UTC timestamp (e.g. session entry
---`timestamp`). Coarse buckets only (m/h/d), so the local-offset correction
---need not be exact. Returns '' when the string can't be parsed.
---@param iso string|nil
---@return string
function M.relative_time_iso(iso)
  if type(iso) ~= 'string' then
    return ''
  end
  local y, mo, d, h, mi, s = iso:match '(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return ''
  end
  local epoch = os.time {
    year = tonumber(y),
    month = tonumber(mo),
    day = tonumber(d),
    hour = tonumber(h),
    min = tonumber(mi),
    sec = tonumber(s),
    isdst = false,
  }
  if not epoch then
    return ''
  end
  -- os.time reads the (UTC) fields as local time; undo the local offset.
  local offset = os.difftime(os.time(os.date '!*t'), os.time(os.date '*t'))
  return M.relative_time(epoch - offset)
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

---List sessions off the main thread when the adapter supports it (falls back
---to the blocking `M.list` otherwise, e.g. adapters without a threadwork path).
---@param opts { cwd?: string, adapter?: string }|nil
---@param callback fun(sessions: ConductorSession[], adapter: ConductorAdapter)
function M.list_async(opts, callback)
  opts = opts or {}
  local conductor_config = require('conductor.config').options
  local interface = require 'conductor.adapters.interface'
  local adapter = interface.get(opts.adapter or conductor_config.default_adapter)

  if not adapter.list_sessions_async then
    callback(adapter.list_sessions { cwd = opts.cwd }, adapter)
    return
  end

  adapter.list_sessions_async({ cwd = opts.cwd }, function(ok, sessions_or_error)
    if ok then
      callback(sessions_or_error, adapter)
    else
      vim.notify('conductor: ' .. tostring(sessions_or_error), vim.log.levels.ERROR)
      callback({}, adapter)
    end
  end)
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

---Same as `M.preview_lines`, parsing off the main thread when the adapter
---supports it (large multi-MB session logs can take tens of ms to parse).
---@param session ConductorSession
---@param adapter ConductorAdapter
---@param callback fun(lines: string[])
function M.preview_lines_async(session, adapter, callback)
  local stat = vim.uv.fs_stat(session.path)
  local mtime = stat and stat.mtime.sec or 0
  local cached = preview_cache[session.path]
  if cached and cached.mtime == mtime then
    callback(cached.lines)
    return
  end

  if not adapter.parse_log_async then
    callback(M.preview_lines(session, adapter))
    return
  end

  adapter.parse_log_async(session.path, function(ok, result_or_error)
    if not ok then
      vim.notify('conductor: ' .. tostring(result_or_error), vim.log.levels.ERROR)
      callback {}
      return
    end
    local conductor_config = require('conductor.config').options
    local log_parser = require 'conductor.log_parser'
    local lines = log_parser.render_preview(result_or_error.meta, result_or_error.entries, {
      max_entries = conductor_config.picker.preview_max_entries,
      max_lines_per_entry = conductor_config.picker.preview_max_lines_per_entry,
    })
    preview_cache[session.path] = { mtime = mtime, lines = lines }
    callback(lines)
  end)
end

--- Preview highlighting ----------------------------------------------------

---Markdown-highlight a telescope preview buffer using Vim's regex syntax
---engine rather than Treesitter.
---
---Cancelling a picker with the interrupt key (`<C-c>`) sets Neovim's `got_int`
---flag. Telescope's teardown then `nvim_buf_delete`s the preview buffer; if the
---buffer has a Treesitter highlighter, its `destroy()` runs `nvim_buf_call()`
---(highlighter.lua:194), and any `nvim_buf_call` with a pending interrupt
---raises "Keyboard interrupt". Detaching Treesitter beforehand doesn't help:
---the LanguageTree still fires `on_detach` -> `destroy()` a second time during
---the delete. Setting `syntax` (instead of `filetype = 'markdown'`) skips the
---`FileType` autocmd that starts Treesitter entirely, so no highlighter exists
---to tear down and the delete never calls into Treesitter.
---@param bufnr integer
function M.highlight_markdown_preview(bufnr)
  -- `syntax` fires the `Syntax` (not `FileType`) autocmd, so Treesitter's
  -- default `FileType`-based `vim.treesitter.start` never attaches here.
  vim.bo[bufnr].syntax = 'markdown'
end

--- Shared actions ----------------------------------------------------------

---Resume in a terminal (default action).
---@param session ConductorSession
function M.action_resume(session)
  require('conductor').resume(session)
end

---Attach as a managed RPC instance (opened in its own tab).
---@param session ConductorSession
function M.action_attach(session)
  local instance, spawn_error = require('conductor.supervisor').spawn {
    adapter = session.adapter,
    cwd = session.cwd,
    session_path = session.path,
    name = session.name,
  }
  if instance then
    -- Open the managed view on a dedicated tab so it never disturbs the
    -- current (e.g. browser) layout. The sidebar + chat windows then fill
    -- the fresh tab; drop the empty scratch window `:tabnew` created.
    vim.cmd 'tabnew'
    local scratch_win = vim.api.nvim_get_current_win()
    local scratch_buf = vim.api.nvim_get_current_buf()
    require('conductor.sidebar').open()
    require('conductor.chatlog').open(instance)
    if
      vim.api.nvim_win_is_valid(scratch_win)
      and vim.api.nvim_win_get_buf(scratch_win) == scratch_buf
      and vim.api.nvim_buf_get_name(scratch_buf) == ''
    then
      pcall(vim.api.nvim_win_close, scratch_win, true)
    end
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
