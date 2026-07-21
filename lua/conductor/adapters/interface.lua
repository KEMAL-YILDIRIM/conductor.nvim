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
---@field list_sessions_async nil|fun(opts?: { cwd?: string }, callback: fun(ok: boolean, sessions_or_error: ConductorSession[]|string)) same as list_sessions, off the main thread (conductor.threadwork); falls back to list_sessions when absent
---@field parse_log fun(path: string): ConductorSessionMeta, ConductorLogEntry[] parse a session file for previews
---@field parse_log_async nil|fun(path: string, callback: fun(ok: boolean, result_or_error: { meta: ConductorSessionMeta, entries: ConductorLogEntry[] }|string)) same as parse_log, off the main thread; falls back to parse_log when absent
---@field resume_cmd fun(session: ConductorSession): string[] argv to resume the session in a terminal
---@field spawn nil|fun(opts: { cwd?: string, session_path?: string, name?: string, ephemeral?: boolean, on_event: fun(event: table), on_exit: fun(code: integer) }): ConductorInstanceHandle
---@field sessions_root nil|fun(): string session storage root (required for fs ops)
---@field fs nil|{ copy: fun(root: string, session: ConductorSession, cwd: string, name?: string): boolean, string|nil, move: fun(root: string, session: ConductorSession, cwd: string): boolean, string|nil, delete: fun(path: string): boolean, string|nil, create: fun(root: string, cwd: string, name?: string): boolean, string|nil, rename: fun(path: string, name: string): boolean, string|nil } optional file-level session ops enabling the editable browser

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
