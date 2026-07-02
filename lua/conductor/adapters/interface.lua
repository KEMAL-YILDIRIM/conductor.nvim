---Adapter contract for agent harnesses (pi, claude-code, opencode, ...).
---Phase 1 requires only session discovery, log parsing, and a resume command.
---Phase 2 will add: spawn(), attach(), events (status/needs-interaction).
---
---@class ConductorSession
---@field id string stable identifier (session uuid or file path)
---@field path string absolute path to the session log file
---@field name string display name (session name or first prompt excerpt)
---@field cwd string|nil project working directory the session belongs to
---@field mtime integer last-modified unix time (recency sort key)
---@field message_count integer
---@field adapter string adapter name owning this session
---
---@class ConductorAdapter
---@field name string
---@field list_sessions fun(opts?: { cwd?: string }): ConductorSession[] discover sessions (all projects, or filtered to cwd)
---@field parse_log fun(path: string): ConductorSessionMeta, ConductorLogEntry[] parse a session file for previews
---@field resume_cmd fun(session: ConductorSession): string[] argv to resume the session in a terminal

local M = {}

---@type table<string, ConductorAdapter>
M.adapters = {}

---@param adapter ConductorAdapter
function M.register(adapter)
  M.adapters[adapter.name] = adapter
end

---@param name string
---@return ConductorAdapter
function M.get(name)
  local adapter = M.adapters[name]
  if not adapter then
    error(('conductor: unknown adapter %q'):format(name))
  end
  return adapter
end

return M
