---Adapter contract for agent harnesses (pi, claude-code, opencode, ...).
---Phase 1: session discovery, log parsing, resume command.
---Phase 2: spawn() — managed headless instances emitting normalized events.
---
---Normalized events passed to spawn's on_event callback:
---  { type = 'agent_start' }                          agent begins processing
---  { type = 'agent_end' }                            agent finished, awaiting user
---  { type = 'text_start' }                           assistant text block begins
---  { type = 'text_delta', text = string }            streaming assistant text
---  { type = 'tool_start', name, summary }            tool execution begins
---  { type = 'tool_end', name, is_error }             tool execution finished
---  { type = 'ui_request', request }                  blocking dialog — needs user interaction
---  { type = 'notify', message, level }               fire-and-forget notification
---  { type = 'error', message }                       command/stream error
---
---@class ConductorInstanceHandle
---@field prompt fun(text: string, opts?: { streaming?: boolean })
---@field respond_ui fun(payload: table) answer a ui_request (payload includes request id)
---@field abort fun()
---@field kill fun()
---@field get_state fun(callback: fun(response: table))
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
---@field spawn nil|fun(opts: { cwd?: string, session_path?: string, name?: string, ephemeral?: boolean, on_event: fun(event: table), on_exit: fun(code: integer) }): ConductorInstanceHandle

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
