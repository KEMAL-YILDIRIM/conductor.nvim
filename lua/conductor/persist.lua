---Persist the live sessions list across Neovim restarts.
---
---State file: `stdpath('data')/conductor/live_sessions.json`, shared by every
---running Neovim. Each entry records which Neovim owns it (pid + RPC server
---address), so concurrent Neovims merge their lists instead of overwriting each
---other, and a session already open in another live Neovim is refused.
---
---An entry whose owner is no longer running is an orphan (e.g. after a reboot or
---crash): it is kept on save and claimed by the next Neovim that restores.
local M = {}

---@class ConductorPersistOwner
---@field pid integer
---@field server string|nil `v:servername` of the owning Neovim

---@class ConductorPersistEntry
---@field adapter string
---@field cwd string|nil
---@field session_path string
---@field name string|nil
---@field owner ConductorPersistOwner

local FORMAT_VERSION = 1

---JSON of this Neovim's own entries at the last write; skips no-op writes.
local last_signature = vim.json.encode {}

---@return string
function M.file_path()
  return vim.fs.joinpath(vim.fn.stdpath 'data', 'conductor', 'live_sessions.json')
end

---@return boolean
local function enabled()
  local sidebar_options = require('conductor.config').options.sidebar
  return sidebar_options.persist ~= false
end

---Comparable form of a session path (shared with the supervisor/sidebar).
---@param path string
---@return string|nil
local function path_key(path)
  return require('conductor.supervisor').session_key(path)
end

---@return ConductorPersistOwner
local function self_owner()
  local server = vim.v.servername
  return { pid = vim.fn.getpid(), server = server ~= '' and server or nil }
end

---@param owner ConductorPersistOwner|nil
---@return boolean
local function is_self(owner)
  local me = self_owner()
  return type(owner) == 'table' and owner.pid == me.pid and owner.server == me.server
end

---Is the Neovim that owns an entry still running? Prefers connecting to its RPC
---server (a dead server refuses the connection, and survives PID reuse after a
---reboot); falls back to a PID probe when no server address was recorded.
---@param owner ConductorPersistOwner|nil
---@param cache table<string, boolean>|nil memo for one read pass
---@return boolean
local function owner_alive(owner, cache)
  if type(owner) ~= 'table' or type(owner.pid) ~= 'number' then
    return false
  end
  if is_self(owner) then
    return true
  end
  local cache_key = ('%d|%s'):format(owner.pid, owner.server or '')
  if cache and cache[cache_key] ~= nil then
    return cache[cache_key]
  end

  local alive
  if type(owner.server) == 'string' and owner.server ~= '' then
    local mode = owner.server:match '^[%w%.%-]+:%d+$' and 'tcp' or 'pipe'
    local ok, channel = pcall(vim.fn.sockconnect, mode, owner.server, { rpc = true })
    alive = ok and type(channel) == 'number' and channel > 0
    if alive then
      pcall(vim.fn.chanclose, channel)
    end
  else
    local ok, result = pcall(vim.uv.kill, owner.pid, 0)
    alive = ok and result == 0
  end

  if cache then
    cache[cache_key] = alive
  end
  return alive
end

---@return ConductorPersistEntry[]
local function read_entries()
  local file = io.open(M.file_path(), 'rb')
  if not file then
    return {}
  end
  local content = file:read '*a'
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= 'table' or type(decoded.sessions) ~= 'table' then
    return {}
  end
  local entries = {}
  for _, entry in ipairs(decoded.sessions) do
    if type(entry) == 'table' and type(entry.session_path) == 'string' and type(entry.adapter) == 'string' then
      entries[#entries + 1] = {
        adapter = entry.adapter,
        cwd = type(entry.cwd) == 'string' and entry.cwd or nil,
        session_path = entry.session_path,
        name = type(entry.name) == 'string' and entry.name or nil,
        owner = type(entry.owner) == 'table' and entry.owner or {},
      }
    end
  end
  return entries
end

---Atomic write: temp file + rename, so a concurrent reader never sees a torn file.
---@param entries ConductorPersistEntry[]
local function write_entries(entries)
  local path = M.file_path()
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  local temporary_path = ('%s.%d.tmp'):format(path, vim.fn.getpid())
  local file = io.open(temporary_path, 'wb')
  if not file then
    return
  end
  file:write(vim.json.encode { version = FORMAT_VERSION, sessions = entries })
  file:close()
  local ok = vim.uv.fs_rename(temporary_path, path)
  if not ok then
    os.remove(temporary_path)
  end
end

---Save this Neovim's live sessions, merged with the other Neovims' entries.
---Cheap when nothing persisted changed (status-only updates skip the write).
---@param instances ConductorInstance[]
function M.save(instances)
  if not enabled() then
    return
  end
  local owner = self_owner()
  local mine = {}
  local my_keys = {}
  for _, instance in ipairs(instances) do
    local key = instance.session_path and path_key(instance.session_path)
    if key and not my_keys[key] then
      my_keys[key] = true
      mine[#mine + 1] = {
        adapter = instance.adapter,
        cwd = instance.cwd,
        session_path = instance.session_path,
        name = instance.name,
        owner = owner,
      }
    end
  end

  local signature = vim.json.encode(mine)
  if signature == last_signature then
    return
  end

  -- Keep every other Neovim's entries (live or orphaned) unless this Neovim
  -- now holds that session; drop entries whose session file is gone.
  local merged = {}
  for _, entry in ipairs(read_entries()) do
    if not is_self(entry.owner) and not my_keys[path_key(entry.session_path)] and vim.uv.fs_stat(entry.session_path) then
      merged[#merged + 1] = entry
    end
  end
  vim.list_extend(merged, mine)
  write_entries(merged)
  last_signature = signature
end

---If another running Neovim owns `session_path`, return its owner.
---@param session_path string|nil
---@return ConductorPersistOwner|nil
function M.claimed_by(session_path)
  if not enabled() or not session_path then
    return nil
  end
  local key = path_key(session_path)
  if not key then
    return nil
  end
  local cache = {}
  for _, entry in ipairs(read_entries()) do
    if path_key(entry.session_path) == key and not is_self(entry.owner) and owner_alive(entry.owner, cache) then
      return entry.owner
    end
  end
  return nil
end

---User-facing message for a session owned by another Neovim.
---@param owner ConductorPersistOwner
---@return string
function M.claimed_message(owner)
  return ('session is already open in another Neovim (pid %d); a session can only be open in one Neovim at a time'):format(owner.pid)
end

---Recreate the saved sessions as stopped instances (no agent process): the
---first prompt restarts the agent on its session file. Entries owned by
---another running Neovim, or whose session file is gone, are skipped.
function M.restore()
  if not enabled() then
    return
  end
  local supervisor = require 'conductor.supervisor'
  local cache = {}
  for _, entry in ipairs(read_entries()) do
    local foreign_live = not is_self(entry.owner) and owner_alive(entry.owner, cache)
    if not foreign_live and vim.uv.fs_stat(entry.session_path) and not supervisor.find_by_session(entry.session_path) then
      pcall(supervisor.restore, entry)
    end
  end
end

return M
