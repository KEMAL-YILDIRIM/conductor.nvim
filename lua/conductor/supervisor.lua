---Supervisor: owns managed agent instances, tracks their status, and
---broadcasts changes via the `User ConductorUpdate` autocmd event.
---
---Instance statuses:
---  starting     process spawned, no agent activity yet
---  idle         waiting for a prompt (fresh instance)
---  streaming    agent is working
---  needs_input  blocking ui_request pending, OR agent finished a turn
---  error        last turn ended with an error notification
---  exited       process terminated
local M = {}

---@class ConductorInstance
---@field id integer
---@field name string
---@field adapter string
---@field cwd string|nil
---@field session_path string|nil
---@field status 'starting'|'idle'|'streaming'|'needs_input'|'error'|'exited'
---@field handle ConductorInstanceHandle|nil
---@field pending_ui table|nil the blocking extension_ui_request, if any
---@field log ConductorChatEntry[] accumulated conversation (for the chat buffer)
---@field partial string in-flight assistant text
---@field chat_bufnr integer|nil
---@field exit_code integer|nil
---@field info ConductorInstanceInfo details shown when selected in the sidebar

---Sidebar details, filled asynchronously by the adapter's `fetch_info`.
---`nil` = not fetched yet, `false` = the agent reported it as absent.
---@class ConductorInstanceInfo
---@field model string|false|nil e.g. 'anthropic/claude-opus-4-5'
---@field thinking string|false|nil thinking level, e.g. 'medium'
---@field context { tokens: number|nil, window: number|nil, percent: number|nil }|false|nil context window usage

---@type table<integer, ConductorInstance>
M.instances = {}
local next_id = 0

local function broadcast()
  vim.api.nvim_exec_autocmds('User', { pattern = 'ConductorUpdate', modeline = false })
end

---Notify listeners (sidebar, chat header) that instance state changed.
M.broadcast = broadcast

---@param instance ConductorInstance
---@param status string
local function set_status(instance, status)
  if instance.status ~= status then
    instance.status = status
    broadcast()
  end
end

---@param instance ConductorInstance
---@param event table normalized adapter event
local function on_event(instance, event)
  local chatlog = require 'conductor.chatlog'

  if event.type == 'agent_start' then
    instance.pending_ui = nil
    set_status(instance, 'streaming')
  elseif event.type == 'agent_end' then
    if instance.partial ~= '' then
      instance.log[#instance.log + 1] = { role = 'assistant', text = instance.partial }
      instance.partial = ''
    end
    if not instance.pending_ui then
      set_status(instance, 'needs_input')
    end
    chatlog.refresh(instance)
    M.refresh_info(instance)
  elseif event.type == 'text_start' then
    if instance.partial ~= '' then
      instance.log[#instance.log + 1] = { role = 'assistant', text = instance.partial }
      instance.partial = ''
    end
  elseif event.type == 'text_delta' then
    instance.partial = instance.partial .. event.text
    chatlog.refresh(instance)
  elseif event.type == 'tool_start' then
    if instance.partial ~= '' then
      instance.log[#instance.log + 1] = { role = 'assistant', text = instance.partial }
      instance.partial = ''
    end
    instance.log[#instance.log + 1] = { role = 'tool', text = event.name, summary = event.summary or '', running = true }
    chatlog.refresh(instance)
  elseif event.type == 'tool_end' then
    -- Find the most recent running tool entry for this tool.
    for index = #instance.log, 1, -1 do
      local entry = instance.log[index]
      if entry.role == 'tool' and entry.running and not entry.local_command and entry.text == event.name then
        entry.running = false
        entry.is_error = event.is_error
        entry.output = event.output or ''
        break
      end
    end
    chatlog.refresh(instance)
  elseif event.type == 'ui_request' then
    instance.pending_ui = event.request
    set_status(instance, 'needs_input')
    require('conductor.ui_dialog').show(instance)
  elseif event.type == 'notify' then
    local level = event.level == 'error' and vim.log.levels.ERROR or event.level == 'warning' and vim.log.levels.WARN or vim.log.levels.INFO
    vim.notify(('[%s] %s'):format(instance.name, event.message), level)
  elseif event.type == 'error' then
    instance.log[#instance.log + 1] = { role = 'system', text = '[error] ' .. event.message }
    set_status(instance, 'error')
    chatlog.refresh(instance)
  end
end

---Start the agent process for `instance` and wire its events / exit into it.
---Used both for a fresh spawn and for restarting an exited instance.
---@param instance ConductorInstance
---@param adapter table
---@param opts { session_path?: string, name?: string, ephemeral?: boolean }
---@return ConductorInstanceHandle|nil handle, string|nil error
local function start_process(instance, adapter, opts)
  local handle, spawn_error
  handle, spawn_error = adapter.spawn {
    cwd = instance.cwd,
    session_path = opts.session_path,
    name = opts.name,
    ephemeral = opts.ephemeral,
    on_event = function(event)
      on_event(instance, event)
    end,
    on_exit = function(code)
      -- A late exit from a previous process must not clobber a restarted one.
      if instance.handle ~= handle then
        return
      end
      instance.exit_code = code
      instance.handle = nil
      instance.pending_ui = nil
      set_status(instance, 'exited')
    end,
  }
  return handle, spawn_error
end

---Spawn a new managed instance.
---@param opts { adapter?: string, cwd?: string, session_path?: string, name?: string, ephemeral?: boolean }
---@return ConductorInstance|nil instance, string|nil error
function M.spawn(opts)
  opts = opts or {}
  local interface = require 'conductor.adapters.interface'
  local adapter_name = opts.adapter or require('conductor.config').options.default_adapter
  local adapter = interface.get(adapter_name)
  if not adapter.spawn then
    return nil, ('adapter %q does not support managed instances'):format(adapter_name)
  end

  next_id = next_id + 1
  ---@type ConductorInstance
  local instance = {
    id = next_id,
    name = opts.name or ('%s #%d'):format(adapter_name, next_id),
    adapter = adapter_name,
    cwd = opts.cwd or vim.fn.getcwd(),
    session_path = opts.session_path,
    status = 'starting',
    handle = nil,
    pending_ui = nil,
    log = {},
    partial = '',
    chat_bufnr = nil,
    exit_code = nil,
    info = {},
  }

  local handle, spawn_error = start_process(instance, adapter, opts)
  if not handle then
    return nil, spawn_error
  end

  instance.handle = handle
  M.instances[instance.id] = instance
  set_status(instance, 'idle')

  -- Warm the slash-command cache so `/` completion and unknown-command
  -- detection are ready by the time the user types.
  if adapter.list_commands then
    adapter.list_commands(instance, function() end)
  end
  M.refresh_info(instance)

  -- When attaching to an existing session, preload its on-disk history so the
  -- chat view shows the prior conversation instead of starting blank. Only the
  -- entries already flushed to the log file are available; anything the running
  -- agent emits afterwards streams in through on_event as usual.
  if opts.session_path then
    M.load_history(instance)
  end

  return instance
end

---Restart the agent process of an exited instance, resuming its session file.
---Keeps the instance id, chat log and chat buffer. No-op if it is still alive.
---@param instance ConductorInstance
---@return boolean ok
function M.restart(instance)
  if instance.handle then
    return true
  end
  if not instance.session_path then
    vim.notify('conductor: instance has exited and has no session file to resume', vim.log.levels.ERROR)
    return false
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)
  if not adapter.spawn then
    vim.notify(('conductor: adapter %q does not support managed instances'):format(instance.adapter), vim.log.levels.ERROR)
    return false
  end

  local handle, spawn_error = start_process(instance, adapter, { session_path = instance.session_path, name = instance.name })
  if not handle then
    vim.notify('conductor: restart failed: ' .. (spawn_error or 'unknown error'), vim.log.levels.ERROR)
    return false
  end

  instance.handle = handle
  instance.exit_code = nil
  instance.pending_ui = nil
  if instance.partial ~= '' then
    instance.log[#instance.log + 1] = { role = 'assistant', text = instance.partial }
    instance.partial = ''
  end
  set_status(instance, 'idle')
  if adapter.list_commands then
    adapter.list_commands(instance, function() end)
  end
  require('conductor.chatlog').refresh(instance)
  M.refresh_info(instance)
  return true
end

---Re-fetch the sidebar details (model, thinking level, context usage) through
---the adapter's optional `fetch_info`. Each partial reply is merged into
---`instance.info` and broadcast so the sidebar redraws.
---@param instance ConductorInstance
function M.refresh_info(instance)
  if not instance.handle then
    return
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)
  if not adapter.fetch_info then
    return
  end
  adapter.fetch_info(instance, function(partial)
    instance.info = instance.info or {}
    for key, value in pairs(partial) do
      instance.info[key] = value
    end
    broadcast()
  end)
end

---Find a managed instance bound to `session_path`, if any.
---@param session_path string|nil
---@return ConductorInstance|nil
function M.find_by_session(session_path)
  if not session_path then
    return nil
  end
  for _, instance in pairs(M.instances) do
    if instance.session_path == session_path then
      return instance
    end
  end
  return nil
end

---Populate `instance.log` from the session file on disk (used when attaching to
---an existing session). No-op when the log already has entries.
---@param instance ConductorInstance
function M.load_history(instance)
  if not instance.session_path or #instance.log > 0 then
    return
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)

  local function apply(entries)
    -- Guard against a race where the agent streamed events before the parse
    -- finished: only seed history if the log is still empty.
    if #instance.log > 0 or type(entries) ~= 'table' then
      return
    end
    for _, entry in ipairs(entries) do
      instance.log[#instance.log + 1] = entry
    end
    require('conductor.chatlog').refresh(instance)
  end

  if adapter.parse_log_async then
    adapter.parse_log_async(instance.session_path, function(ok, result)
      if ok and type(result) == 'table' then
        apply(result.entries)
      end
    end)
  elseif adapter.parse_log then
    local _, entries = adapter.parse_log(instance.session_path)
    apply(entries)
  end
end

---Append an entry to the instance's chat log and refresh the view.
---@param instance ConductorInstance
---@param entry ConductorChatEntry
---@return ConductorChatEntry entry the appended entry (mutate it, then refresh)
function M.append(instance, entry)
  instance.log[#instance.log + 1] = entry
  require('conductor.chatlog').refresh(instance)
  return entry
end

---Append a system note (command result, status message) to the chat log.
---@param instance ConductorInstance
---@param text string
function M.note(instance, text)
  M.append(instance, { role = 'system', text = text })
end

---Clear the local chat log (after the agent switched to another session).
---@param instance ConductorInstance
function M.reset_log(instance)
  instance.log = {}
  instance.partial = ''
  require('conductor.chatlog').refresh(instance)
end

---Submit one piece of chat input: the adapter may intercept it (built-in slash
---command, shell shortcut, unknown command), otherwise it goes out as a prompt.
---@param instance ConductorInstance
---@param text string trimmed, non-empty input
---@return boolean consumed false when the input was refused and should stay editable
function M.submit(instance, text)
  -- An exited instance is transparently restarted on its session file.
  if not instance.handle and not M.restart(instance) then
    return false
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)
  if adapter.dispatch_input then
    local outcome, replacement = adapter.dispatch_input(instance, text)
    if outcome == 'handled' then
      return true
    elseif outcome == 'rejected' then
      return false
    end
    text = replacement or text
  end
  M.prompt(instance, text)
  return true
end

---Send a prompt to an instance; records it in the local log.
---@param instance ConductorInstance
---@param text string
function M.prompt(instance, text)
  if not instance.handle then
    vim.notify('conductor: instance has exited', vim.log.levels.ERROR)
    return
  end
  instance.log[#instance.log + 1] = { role = 'user', text = text }
  instance.handle.prompt(text, { streaming = instance.status == 'streaming' })
  set_status(instance, 'streaming')
  require('conductor.chatlog').refresh(instance)
end

---@param instance ConductorInstance
function M.abort(instance)
  if instance.handle then
    instance.handle.abort()
  end
end

---Kill the process and forget the instance.
---@param instance ConductorInstance
function M.remove(instance)
  if instance.handle then
    instance.handle.kill()
    instance.handle = nil
  end
  M.instances[instance.id] = nil
  broadcast()
end

---@return ConductorInstance[] sorted by id
function M.list()
  local list = {}
  for _, instance in pairs(M.instances) do
    list[#list + 1] = instance
  end
  table.sort(list, function(a, b)
    return a.id < b.id
  end)
  return list
end

---Number of instances currently needing user interaction.
---@return integer
function M.needs_input_count()
  local count = 0
  for _, instance in pairs(M.instances) do
    if instance.status == 'needs_input' then
      count = count + 1
    end
  end
  return count
end

return M
