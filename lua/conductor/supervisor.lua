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

---@type table<integer, ConductorInstance>
M.instances = {}
local next_id = 0

local function broadcast()
  vim.api.nvim_exec_autocmds('User', { pattern = 'ConductorUpdate', modeline = false })
end

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
      if entry.role == 'tool' and entry.running and entry.text == event.name then
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
  }

  local handle, spawn_error = adapter.spawn {
    cwd = instance.cwd,
    session_path = opts.session_path,
    name = opts.name,
    ephemeral = opts.ephemeral,
    on_event = function(event)
      on_event(instance, event)
    end,
    on_exit = function(code)
      instance.exit_code = code
      instance.handle = nil
      set_status(instance, 'exited')
    end,
  }
  if not handle then
    return nil, spawn_error
  end

  instance.handle = handle
  M.instances[instance.id] = instance
  set_status(instance, 'idle')
  return instance
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
