---Discovers externally-running agent sessions advertised via presence files
---written by the conductor-presence pi extension (pi-extension/ in this repo).
---Presence dir: ~/.pi/agent/conductor/presence/<pid>.json
local M = {}

---@class ConductorExternalSession
---@field pid integer
---@field status string 'idle'|'streaming'|'needs_input'
---@field session_file string|nil
---@field name string
---@field cwd string|nil
---@field updated_at string|nil
---@field bridge string|nil pipe of the conductor-presence bridge (live attach)
---@field mode string|nil pi run mode ('tui', 'rpc', ...); nil for old extensions

---vim.json.decode maps JSON null to vim.NIL, which is truthy in Lua. Coerce
---it to nil so `or` fallbacks work as intended.
local function nilable(value)
  if value == nil or value == vim.NIL then
    return nil
  end
  return value
end

---@return string
local function presence_dir()
  return vim.fs.normalize(vim.fn.expand '~/.pi/agent/conductor/presence')
end

---Read and decode all presence files. Cheap, synchronous (small JSON files).
---@return { file: string, decoded: table }[] candidates, integer[] pids
local function read_candidates()
  local files = vim.fn.glob(presence_dir() .. '/*.json', true, true)
  ---@type { file: string, decoded: table }[]
  local candidates = {}
  local pids = {}
  for _, file in ipairs(files) do
    local handle = io.open(file, 'r')
    if handle then
      local content = handle:read '*a'
      handle:close()
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and type(decoded) == 'table' and type(decoded.pid) == 'number' then
        candidates[#candidates + 1] = { file = file, decoded = decoded }
        pids[#pids + 1] = decoded.pid
      end
    end
  end
  return candidates, pids
end

---Cache of derived display names keyed by session file, invalidated by mtime.
---Avoids re-scanning each log on every 2s refresh.
local name_cache = {}

---Derive a human-friendly name for an unnamed session: prefer the first user
---prompt in its log (like the all-sessions pane), then the file basename, then
---the pid. Cached by file mtime+size to avoid rescanning on every refresh.
---@param session_file string|nil
---@param pid integer
---@return string
local function session_display_name(session_file, pid)
  if not session_file then
    return ('pid %d'):format(pid)
  end

  local stat = vim.uv.fs_stat(session_file)
  local cache_key = stat and ('%d.%d:%d'):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
  local cached = name_cache[session_file]
  if cached and cache_key and cached.key == cache_key then
    return cached.name
  end

  local name = vim.fn.fnamemodify(session_file, ':t:r')
  local ok, meta = pcall(require('conductor.log_parser').scan_meta, session_file)
  if ok and meta and type(meta.first_user_text) == 'string' and meta.first_user_text ~= '' then
    local first_line = meta.first_user_text:gsub('\n.*', '')
    if #first_line > 60 then
      first_line = first_line:sub(1, 57) .. '…'
    end
    name = first_line
  end

  if cache_key then
    name_cache[session_file] = { key = cache_key, name = name }
  end
  return name
end

---Build the session list from candidates + a liveness map, pruning dead ones.
---@param candidates { file: string, decoded: table }[]
---@param alive table<integer, boolean>
---@return ConductorExternalSession[]
local function build_sessions(candidates, alive)
  local sessions = {}
  for _, candidate in ipairs(candidates) do
    local decoded = candidate.decoded
    if alive[decoded.pid] then
      local session_file = nilable(decoded.sessionFile)
      local session_name = nilable(decoded.sessionName)
      sessions[#sessions + 1] = {
        pid = decoded.pid,
        status = nilable(decoded.status) or 'idle',
        session_file = session_file,
        name = session_name or session_display_name(session_file, decoded.pid),
        cwd = nilable(decoded.cwd),
        updated_at = nilable(decoded.updatedAt),
        bridge = nilable(decoded.bridge),
        mode = nilable(decoded.mode),
      }
    else
      -- Stale presence file from a crashed/killed process.
      vim.uv.fs_unlink(candidate.file)
    end
  end
  table.sort(sessions, function(a, b)
    return a.pid < b.pid
  end)
  return sessions
end

local cache = { at = 0, sessions = {}, refreshing = false }

---Return the last-known external session list without any blocking work.
---Callers that want fresh data should also kick off `M.refresh_async`.
---@return ConductorExternalSession[]
function M.list_cached()
  return cache.sessions
end

---Refresh the external session cache without ever blocking the UI thread.
---On Windows the liveness probe (`tasklist`) is spawned asynchronously; the
---cache and the optional `on_done` callback fire once it completes. Concurrent
---calls and calls within `interval_ms` of the last refresh are coalesced.
---@param opts { interval_ms?: integer, on_done?: fun(sessions: ConductorExternalSession[]) }|nil
function M.refresh_async(opts)
  opts = opts or {}
  local now = vim.uv.now()
  if cache.refreshing or now - cache.at <= (opts.interval_ms or 2000) then
    return
  end
  cache.refreshing = true

  local candidates, pids = read_candidates()

  local function finish(alive)
    cache.sessions = build_sessions(candidates, alive)
    cache.at = vim.uv.now()
    cache.refreshing = false
    if opts.on_done then
      opts.on_done(cache.sessions)
    end
  end

  if #pids == 0 then
    finish {}
    return
  end

  if vim.fn.has 'win32' == 1 then
    -- Single async tasklist call for all pids; never blocks the main loop.
    vim.system({ 'tasklist', '/NH', '/FO', 'CSV' }, { text = true }, function(result)
      local alive = {}
      if result.code == 0 and result.stdout then
        local running = {}
        for pid_string in result.stdout:gmatch '","(%d+)",' do
          running[tonumber(pid_string)] = true
        end
        for _, pid in ipairs(pids) do
          alive[pid] = running[pid] == true
        end
      end
      vim.schedule(function()
        finish(alive)
      end)
    end)
  else
    -- POSIX: signal-0 probe is a cheap syscall, safe to run inline.
    local alive = {}
    for _, pid in ipairs(pids) do
      alive[pid] = vim.uv.kill(pid, 0) == 0
    end
    finish(alive)
  end
end

---Synchronous liveness probe for one pid (explicit user actions only).
---@param pid integer
---@return boolean
local function pid_alive(pid)
  if vim.fn.has 'win32' == 1 then
    local ok, result = pcall(function()
      return vim.system({ 'tasklist', '/NH', '/FO', 'CSV', '/FI', 'PID eq ' .. pid }, { text = true }):wait(3000)
    end)
    return ok and result.code == 0 and (result.stdout or ''):find(('","%d",'):format(pid), 1, true) ~= nil
  end
  return vim.uv.kill(pid, 0) == 0
end

---Find a live, non-RPC pi process (a terminal session) that owns
---`session_path`, reading the presence files directly so it works even when
---the sidebar's cache is empty. Conductor's own RPC instances (`mode = 'rpc'`)
---are skipped; presence files from older extensions (no `mode`) count as
---terminal sessions.
---@param session_path string|nil
---@return { pid: integer, bridge: string|nil, mode: string|nil }|nil
function M.find_live(session_path)
  local supervisor = require 'conductor.supervisor'
  local key = supervisor.session_key(session_path)
  if not key then
    return nil
  end
  local candidates = read_candidates()
  for _, candidate in ipairs(candidates) do
    local decoded = candidate.decoded
    if supervisor.session_key(nilable(decoded.sessionFile)) == key and nilable(decoded.mode) ~= 'rpc' and pid_alive(decoded.pid) then
      return { pid = decoded.pid, bridge = nilable(decoded.bridge), mode = nilable(decoded.mode) }
    end
  end
  return nil
end

---Path to the bundled pi extension (for installation instructions).
---@return string|nil
function M.extension_path()
  local source = debug.getinfo(1, 'S').source:sub(2)
  local plugin_root = vim.fs.normalize(vim.fn.fnamemodify(source, ':h:h:h'))
  local path = plugin_root .. '/pi-extension/conductor-presence.ts'
  return vim.uv.fs_stat(path) and path or nil
end

return M
