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

---Check liveness for a set of pids in one shot.
---@param pids integer[]
---@return table<integer, boolean>
local function alive_map(pids)
  local alive = {}
  if #pids == 0 then
    return alive
  end
  if vim.fn.has 'win32' == 1 then
    -- Single tasklist call for all pids (per-pid calls are too slow to poll).
    local result = vim.system({ 'tasklist', '/NH', '/FO', 'CSV' }, { text = true }):wait()
    if result.code == 0 and result.stdout then
      local running = {}
      for pid_string in result.stdout:gmatch '","(%d+)",' do
        running[tonumber(pid_string)] = true
      end
      for _, pid in ipairs(pids) do
        alive[pid] = running[pid] == true
      end
    end
  else
    for _, pid in ipairs(pids) do
      alive[pid] = vim.uv.kill(pid, 0) == 0
    end
  end
  return alive
end

---List live external sessions; prunes presence files of dead processes.
---@return ConductorExternalSession[]
function M.list()
  local sessions = {}
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

  local alive = alive_map(pids)
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

---Cached external list refreshed at most every `interval_ms`.
local cache = { at = 0, sessions = {} }
---@param interval_ms integer|nil default 2000
---@return ConductorExternalSession[]
function M.list_cached(interval_ms)
  local now = vim.uv.now()
  if now - cache.at > (interval_ms or 2000) then
    cache.sessions = M.list()
    cache.at = now
  end
  return cache.sessions
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
