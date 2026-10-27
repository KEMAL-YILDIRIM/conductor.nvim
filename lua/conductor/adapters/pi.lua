---Pi coding agent adapter.
---Sessions live in ~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<uuid>.jsonl
---
---`list_sessions` and `sessions_root` below avoid `vim.fn`/`vim.env`/`vim.g`
---on purpose: they also run inside `conductor.threadwork`'s libuv-threadpool
---worker (a bare Lua state with only `vim.uv`/`vim.json`/`vim.fs`/stdlib), so
---the potentially slow directory walk + file scans never block the main
---thread. Keep it that way when editing this file.
local log_parser = require 'conductor.log_parser'

---@type ConductorAdapter
local M = { name = 'pi' }

---Metadata cache keyed by file path, invalidated by mtime+size (mtime alone
---has 1s resolution — too coarse for successive edits from the browser).
---Shared only within a single worker/main-thread Lua state — each threadpool
---call starts fresh, so this just avoids re-scanning within one listing pass.
---@type table<string, { key: string, meta: ConductorSessionMeta }>
local meta_cache = {}

---Options lookup that works both on the main thread (via conductor.config)
---and inside a threadpool worker (no vim.g-backed config there — callers on
---that path pass overrides explicitly instead).
---@param overrides table|nil
---@return table
local function options(overrides)
  if overrides then
    return overrides
  end
  local ok, config = pcall(require, 'conductor.config')
  if ok then
    return config.options.adapters.pi
  end
  return {}
end

---Resolve the session storage root using pi's own precedence:
---1. explicit `adapters.pi.sessions_dir` config
---2. $PI_CODING_AGENT_DIR/sessions (pi's agent-dir redirect)
---3. ~/.pi/agent/sessions (pi default)
---@param overrides table|nil { sessions_dir?: string } — required when called from a worker thread
---@return string
local function sessions_root(overrides)
  local configured = options(overrides).sessions_dir
  if configured and configured ~= '' then
    return vim.fs.normalize(configured)
  end
  local agent_dir = os.getenv 'PI_CODING_AGENT_DIR'
  if agent_dir and agent_dir ~= '' then
    return vim.fs.normalize(agent_dir .. '/sessions')
  end
  return vim.fs.normalize((vim.uv.os_homedir() or '') .. '/.pi/agent/sessions')
end

---Decode pi's directory encoding back to a readable path.
---Encoding: path separators (and drive colon) become '-', e.g.
---'C:/Users/me/proj' -> '--C--Users-me-proj' (best-effort; used for display only).
---@param dir_name string
---@return string
local function decode_cwd_dir(dir_name)
  local decoded = dir_name:gsub('^%-%-', ''):gsub('%-+$', ''):gsub('%-%-', ':/'):gsub('%-', '/')
  return decoded ~= '' and decoded or dir_name
end

---Convert an ISO-8601 UTC timestamp (e.g. '2026-05-11T09:37:07.037Z') to unix
---seconds. Uses only stdlib os.time/os.date, so it also runs in the threadpool
---worker. Returns nil when the string can't be parsed.
---@param iso string|nil
---@return integer|nil
local function iso_to_epoch(iso)
  if type(iso) ~= 'string' then
    return nil
  end
  local y, mo, d, h, mi, s = iso:match '(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)'
  if not y then
    return nil
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
    return nil
  end
  -- os.time reads the (UTC) fields as local time; undo the local offset.
  local offset = os.difftime(os.time(os.date '!*t'), os.time(os.date '*t'))
  return epoch - offset
end

---Uses `vim.fs.dir` (not `vim.fn.glob`) so this walk works unchanged inside
---a threadpool worker, where `vim.fn` is unavailable.
---@param opts { cwd?: string, sessions_dir?: string }|nil `sessions_dir` overrides config/env lookup (needed off the main thread)
---@return ConductorSession[]
function M.list_sessions(opts)
  opts = opts or {}
  local root = sessions_root(opts.sessions_dir and { sessions_dir = opts.sessions_dir } or nil)
  ---@type ConductorSession[]
  local sessions = {}

  for project_name, project_type in vim.fs.dir(root) do
    if project_type == 'directory' then
      local project_dir = root .. '/' .. project_name
      for file_name, file_type in vim.fs.dir(project_dir) do
        if file_type == 'file' and file_name:match '%.jsonl$' then
          local file = project_dir .. '/' .. file_name
          local stat = vim.uv.fs_stat(file)
          if stat then
            local cache_key = ('%d.%d:%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
            local cached = meta_cache[file]
            local meta
            if cached and cached.key == cache_key then
              meta = cached.meta
            else
              meta = log_parser.scan_meta(file)
              meta_cache[file] = { key = cache_key, meta = meta }
            end
            local cwd = meta.cwd or decode_cwd_dir(project_name)
            if not opts.cwd or vim.fs.normalize(cwd):lower() == vim.fs.normalize(opts.cwd):lower() then
              local first_line = meta.first_user_text and meta.first_user_text:gsub('\n.*', '') or '(empty session)'
              sessions[#sessions + 1] = {
                id = meta.id or file,
                path = file,
                name = meta.name or first_line,
                cwd = cwd,
                mtime = stat.mtime.sec,
                created = meta.created,
                last_activity = meta.last_activity,
                -- Prefer the in-file last-activity time (copy/move-proof) over the
                -- filesystem mtime, which a copy/move resets; fall back to mtime
                -- only when the session carries no parseable timestamp.
                sort_time = iso_to_epoch(meta.last_activity) or stat.mtime.sec,
                message_count = meta.message_count,
                forked = meta.forked,
                adapter = 'pi',
              }
            end
          end
        end
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.sort_time > b.sort_time
  end)
  return sessions
end

---Threadpool-safe entry point for `conductor.threadwork`: resolves
---`sessions_dir` on the main thread (config/env are unavailable in the
---worker) before dispatching, so the worker only ever does file I/O.
---@param opts { cwd?: string }|nil
---@param callback fun(ok: boolean, sessions_or_error: ConductorSession[]|string)
function M.list_sessions_async(opts, callback)
  opts = opts or {}
  local worker_opts = { cwd = opts.cwd, sessions_dir = sessions_root() }
  require('conductor.threadwork').call('conductor.adapters.pi', 'list_sessions', worker_opts, callback)
end

M.parse_log = log_parser.parse

---Threadpool-safe log parse: parsing multi-MB JSONL session files can take
---tens of milliseconds, so route it off the main thread too.
---@param path string
---@param callback fun(ok: boolean, result_or_error: { meta: ConductorSessionMeta, entries: ConductorLogEntry[] }|string)
function M.parse_log_async(path, callback)
  require('conductor.threadwork').call('conductor.log_parser', 'parse_pair', path, callback)
end

M.sessions_root = sessions_root

---File-level session operations (copy/move/delete/create/rename) backing the
---editable session browser.
M.fs = setmetatable({}, {
  __index = function(_, key)
    return require('conductor.adapters.pi_fs')[key]
  end,
})

M.spawn = function(opts)
  return require('conductor.adapters.pi_rpc').spawn(opts)
end

---Built-in slash commands / shell shortcuts for managed instances.
M.dispatch_input = function(instance, text)
  return require('conductor.adapters.pi_commands').dispatch(instance, text)
end

M.list_commands = function(instance, callback)
  return require('conductor.adapters.pi_commands').list_commands(instance, callback)
end

---@param session ConductorSession
---@return string[]
function M.resume_cmd(session)
  return { options().cmd, '--session', session.path }
end

return M
