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

---Build the session list from candidates + a liveness map, pruning dead ones.
---@param candidates { file: string, decoded: table }[]
---@param alive table<integer, boolean>
---@return ConductorExternalSession[]
local function build_sessions(candidates, alive)
  local sessions = {}
  for _, candidate in ipairs(candidates) do
    local decoded = candidate.decoded
    if alive[decoded.pid] then
      sessions[#sessions + 1] = {
        pid = decoded.pid,
        status = decoded.status or 'idle',
        session_file = decoded.sessionFile,
        name = decoded.sessionName or (decoded.sessionFile and vim.fn.fnamemodify(decoded.sessionFile, ':t:r') or ('pid %d'):format(decoded.pid)),
        cwd = decoded.cwd,
        updated_at = decoded.updatedAt,
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

---Path to the bundled pi extension (for installation instructions).
---@return string|nil
function M.extension_path()
  local source = debug.getinfo(1, 'S').source:sub(2)
  local plugin_root = vim.fs.normalize(vim.fn.fnamemodify(source, ':h:h:h'))
  local path = plugin_root .. '/pi-extension/conductor-presence.ts'
  return vim.uv.fs_stat(path) and path or nil
end

return M
