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
  -- Persist the live list first (no-op unless a session path/name changed),
  -- so a reboot or crash can restore it.
  local ok, persist_error = pcall(require('conductor.persist').save, M.list())
  if not ok then
    vim.notify_once('conductor: could not save live sessions: ' .. tostring(persist_error), vim.log.levels.WARN)
  end
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
  elseif event.type == 'user_message' then
    -- Echoed by the bridge: a prompt typed in the terminal, or one we sent.
    if instance.partial ~= '' then
      instance.log[#instance.log + 1] = { role = 'assistant', text = instance.partial }
      instance.partial = ''
    end
    instance.log[#instance.log + 1] = { role = 'user', text = event.text }
    chatlog.refresh(instance)
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
    -- A bridged session is written by the terminal pi: resync from its file so
    -- anything missed while attaching (or a turn already running) self-heals.
    if instance.handle and instance.handle.echoes_user_messages then
      M.load_history(instance, { force = true })
    end
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
    instance.log[#instance.log + 1] = { role = 'system', text = '[error] ' .. event.message, local_note = true }
    set_status(instance, 'error')
    chatlog.refresh(instance)
  elseif event.type == 'terminal_prompt_start' then
    -- Bridge only: a dialog is open in the terminal pi. It can only be
    -- answered there; show a transient note and flag the session.
    if instance.prompt_note then
      M.remove_entry(instance, instance.prompt_note)
    end
    local title = event.title and (' — ' .. event.title) or ''
    instance.prompt_note = {
      role = 'system',
      text = ('waiting in the terminal: %s%s (answer it in the terminal pi)'):format(event.kind or 'dialog', title),
      local_note = true,
      transient = true,
    }
    instance.log[#instance.log + 1] = instance.prompt_note
    if instance.status_before_prompt == nil then
      instance.status_before_prompt = instance.status
    end
    set_status(instance, 'needs_input')
    chatlog.refresh(instance)
  elseif event.type == 'terminal_prompt_end' then
    if instance.prompt_note then
      M.remove_entry(instance, instance.prompt_note)
      instance.prompt_note = nil
    end
    local before = instance.status_before_prompt
    instance.status_before_prompt = nil
    if before and instance.status == 'needs_input' then
      set_status(instance, before)
    end
    chatlog.refresh(instance)
  elseif event.type == 'bridge_reconnected' then
    -- The terminal pi switched sessions (/new, /fork, /clone from either
    -- side): follow it to the new session file.
    M.follow_session(instance)
  end
end

---Start the agent process for `instance` and wire its events / exit into it.
---Used both for a fresh spawn and for restarting an exited instance.
---@param instance ConductorInstance
---@param adapter table
---With `opts.bridge`, attaches to that running terminal pi instead of spawning.
---@param opts { session_path?: string, name?: string, ephemeral?: boolean, bridge?: string, pid?: integer }
---@return ConductorInstanceHandle|nil handle, string|nil error
local function start_process(instance, adapter, opts)
  local handle, spawn_error
  local function on_adapter_event(event)
    on_event(instance, event)
  end
  local function on_adapter_exit(code)
    -- A late exit from a previous process must not clobber a restarted one.
    if instance.handle ~= handle then
      return
    end
    instance.exit_code = code
    instance.handle = nil
    instance.pending_ui = nil
    set_status(instance, 'exited')
  end
  if opts.bridge then
    if not adapter.connect then
      return nil, ('adapter %q cannot attach to a running session'):format(instance.adapter)
    end
    handle, spawn_error = adapter.connect { bridge = opts.bridge, pid = opts.pid, on_event = on_adapter_event, on_exit = on_adapter_exit }
    return handle, spawn_error
  end
  handle, spawn_error = adapter.spawn {
    cwd = instance.cwd,
    session_path = opts.session_path,
    name = opts.name,
    ephemeral = opts.ephemeral,
    on_event = on_adapter_event,
    on_exit = on_adapter_exit,
  }
  return handle, spawn_error
end

---One session file, one pi process: the terminal pi that owns
---`session_path`, if any. With a `bridge` we attach to it; without one (old
---extension) the session can only be shown read-only.
---@param session_path string|nil
---@return { pid: integer, bridge: string|nil }|nil
local function resolve_live_owner(session_path)
  if not session_path then
    return nil
  end
  return require('conductor.external').find_live(session_path)
end

---@param pid integer
---@return string
local function readonly_message(pid)
  return ('this session is open in a terminal pi (pid %d) without the conductor bridge — showing it read-only. Update conductor-presence and restart that pi to attach live.'):format(
    pid
  )
end

---Stop the read-only file watcher, if any.
---@param instance ConductorInstance
local function stop_watch(instance)
  local watcher = instance.watcher
  instance.watcher = nil
  if watcher and not watcher:is_closing() then
    watcher:stop()
    watcher:close()
  end
end

---Show a session owned by a bridgeless terminal pi read-only: no process,
---history from the file, reloaded whenever the file changes.
---@param instance ConductorInstance
local function enter_readonly(instance)
  instance.readonly = true
  set_status(instance, 'readonly')
  M.load_history(instance, { force = true })
  if instance.watcher or not instance.session_path then
    return
  end
  local watcher = vim.uv.new_fs_poll()
  if not watcher then
    return
  end
  instance.watcher = watcher
  watcher:start(
    instance.session_path,
    1000,
    vim.schedule_wrap(function(poll_error)
      if poll_error or instance.watcher ~= watcher or not instance.readonly then
        return
      end
      M.load_history(instance, { force = true })
    end)
  )
end

---Leave read-only mode (a live process is taking over).
---@param instance ConductorInstance
local function leave_readonly(instance)
  instance.readonly = nil
  stop_watch(instance)
end

---Build a fresh instance record (not yet registered, no process).
---@param adapter_name string
---@param opts { cwd?: string, session_path?: string, name?: string }
---@return ConductorInstance
local function new_instance(adapter_name, opts)
  next_id = next_id + 1
  ---@type ConductorInstance
  return {
    id = next_id,
    name = opts.name or ('%s #%d'):format(adapter_name, next_id),
    -- true = a name the user/pi chose; false = derived (refreshed from the file).
    name_explicit = opts.name_explicit == true,
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
  -- One session, one Neovim: refuse a session another running Neovim holds.
  local persist = require 'conductor.persist'
  local owner = persist.claimed_by(opts.session_path)
  if owner then
    return nil, persist.claimed_message(owner)
  end

  local live = resolve_live_owner(opts.session_path)

  local instance = new_instance(adapter_name, opts)

  if live and not live.bridge then
    M.instances[instance.id] = instance
    enter_readonly(instance)
    vim.notify('conductor: ' .. readonly_message(live.pid), vim.log.levels.WARN)
    return instance
  end

  local handle, spawn_error = start_process(instance, adapter, vim.tbl_extend('force', opts, { bridge = live and live.bridge, pid = live and live.pid }))
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
---A session owned by a bridgeless terminal pi stays read-only (`opts.quiet`
---skips the warning, e.g. when merely reopening its chat).
---@param instance ConductorInstance
---@param opts { quiet?: boolean }|nil
---@return boolean ok
function M.restart(instance, opts)
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
  local persist = require 'conductor.persist'
  local owner = persist.claimed_by(instance.session_path)
  if owner then
    vim.notify('conductor: ' .. persist.claimed_message(owner), vim.log.levels.WARN)
    return false
  end

  local live = resolve_live_owner(instance.session_path)
  if live and not live.bridge then
    if not instance.readonly then
      enter_readonly(instance)
    end
    if not (opts and opts.quiet) then
      vim.notify('conductor: ' .. readonly_message(live.pid), vim.log.levels.WARN)
    end
    return false
  end

  local handle, spawn_error =
    start_process(instance, adapter, { session_path = instance.session_path, name = instance.name, bridge = live and live.bridge, pid = live and live.pid })
  if not handle then
    vim.notify('conductor: restart failed: ' .. (spawn_error or 'unknown error'), vim.log.levels.ERROR)
    return false
  end

  leave_readonly(instance)
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

local is_windows = vim.fn.has 'win32' == 1

---Canonical comparison key for a session file path. pi reports paths with
---backslashes while conductor builds them with forward slashes, and Windows
---paths are case-insensitive, so raw string equality misses the same file.
---@param path string|nil
---@return string|nil
function M.session_key(path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  local key = vim.fs.normalize(path)
  if is_windows then
    key = key:lower()
  end
  return key
end

---Recreate a persisted session as a stopped instance (no agent process). Its
---history is loaded from the session file; the first prompt restarts the agent.
---@param entry { adapter: string, cwd?: string, session_path: string, name?: string }
---@return ConductorInstance
function M.restore(entry)
  local instance = new_instance(entry.adapter, entry)
  -- The saved file doesn't record whether a name was chosen. A name equal to
  -- the session file's own name is a fallback, never a choice: let the
  -- history load replace it with the first question.
  local file_name = entry.session_path and vim.fn.fnamemodify(entry.session_path, ':t:r')
  instance.name_explicit = entry.name ~= nil and entry.name ~= file_name
  instance.status = 'idle'
  M.instances[instance.id] = instance
  broadcast()
  M.load_history(instance)
  return instance
end

---Find a managed instance bound to `session_path`, if any.
---@param session_path string|nil
---@return ConductorInstance|nil
function M.find_by_session(session_path)
  local key = M.session_key(session_path)
  if not key then
    return nil
  end
  for _, instance in pairs(M.instances) do
    if M.session_key(instance.session_path) == key then
      return instance
    end
  end
  return nil
end

---Re-insert conductor's own notes (command results, errors) into a log rebuilt
---from disk. Each note keeps its position relative to the user messages: it
---goes back right before the user message that followed it. Transient notes
---(an open terminal dialog) are dropped.
---@param old_log ConductorChatEntry[]
---@param entries ConductorChatEntry[]
---@return ConductorChatEntry[]
local function merge_local_notes(old_log, entries)
  local notes = {}
  local users = 0
  for _, entry in ipairs(old_log) do
    if entry.role == 'user' then
      users = users + 1
    elseif entry.local_note and not entry.transient then
      notes[#notes + 1] = { anchor = users, entry = entry }
    end
  end
  if #notes == 0 then
    return entries
  end
  local merged = {}
  local note_index = 1
  local seen = 0
  for _, entry in ipairs(entries) do
    if entry.role == 'user' then
      while notes[note_index] and notes[note_index].anchor <= seen do
        merged[#merged + 1] = notes[note_index].entry
        note_index = note_index + 1
      end
      seen = seen + 1
    end
    merged[#merged + 1] = entry
  end
  for index = note_index, #notes do
    merged[#merged + 1] = notes[index].entry
  end
  return merged
end

---Display name derived from a first user message: first line, max 60 chars
---(same rule as the sidebar's External section).
---@param text string
---@return string
local function name_from_text(text)
  local first_line = vim.trim((text:gsub('\n.*', '')))
  if vim.fn.strchars(first_line) > 60 then
    first_line = vim.fn.strcharpart(first_line, 0, 57) .. '…'
  end
  return first_line
end

---Refresh the instance name from parsed session metadata: the file's explicit
---name wins; otherwise a derived name follows the first user message.
---@param instance ConductorInstance
---@param meta ConductorSessionMeta|nil
local function refresh_name(instance, meta)
  if type(meta) ~= 'table' then
    return
  end
  local name
  if type(meta.name) == 'string' and meta.name ~= '' then
    name = meta.name
    instance.name_explicit = true
  elseif not instance.name_explicit and type(meta.first_user_text) == 'string' and meta.first_user_text ~= '' then
    name = name_from_text(meta.first_user_text)
  end
  if name and name ~= '' and name ~= instance.name then
    instance.name = name
    broadcast()
    require('conductor.chatlog').refresh(instance)
  end
end

---Populate `instance.log` from the session file on disk (used when attaching to
---an existing session). No-op when the log already has entries, unless
---`opts.force` (bridged sessions resync after each turn): then the log is
---replaced, provided nothing streamed in while the file was being parsed.
---@param instance ConductorInstance
---@param opts { force?: boolean }|nil
---Fill still-empty details (model, thinking level, context tokens) from the
---parsed session file, so a stopped (restored) instance shows them before its
---agent runs. Live `refresh_info` replies overwrite these; fields already set
---are left alone. The file has no context window size, so context carries
---tokens only until pi reports the window.
---@param instance ConductorInstance
---@param meta ConductorSessionMeta|nil
local function seed_info(instance, meta)
  if type(meta) ~= 'table' then
    return
  end
  instance.info = instance.info or {}
  local info = instance.info
  local changed = false
  if info.model == nil then
    info.model = meta.model or false
    changed = true
  end
  if info.thinking == nil then
    info.thinking = meta.thinking or false
    changed = true
  end
  if info.context == nil then
    info.context = meta.context_tokens and { tokens = meta.context_tokens } or false
    changed = true
  end
  if changed then
    broadcast()
  end
end

function M.load_history(instance, opts)
  local force = opts and opts.force
  if not instance.session_path or (#instance.log > 0 and not force) then
    return
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)
  local log_before = instance.log
  local length_before = #log_before

  local function apply(entries, meta)
    if type(entries) ~= 'table' then
      return
    end
    refresh_name(instance, meta)
    seed_info(instance, meta)
    if force then
      -- Skip if a new turn started or events arrived during the parse; the
      -- next agent_end resyncs again.
      if instance.log ~= log_before or #instance.log ~= length_before or instance.partial ~= '' or instance.status == 'streaming' then
        return
      end
      instance.log = merge_local_notes(log_before, entries)
      require('conductor.chatlog').refresh(instance)
      return
    end
    -- Guard against a race where the agent streamed events before the parse
    -- finished: only seed history if the log is still empty.
    if #instance.log > 0 then
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
        apply(result.entries, result.meta)
      end
    end)
  elseif adapter.parse_log then
    local meta, entries = adapter.parse_log(instance.session_path)
    apply(entries, meta)
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
  -- `local_note`: not in the session file; kept across resyncs from disk.
  M.append(instance, { role = 'system', text = text, local_note = true })
end

---Remove one entry (by identity) from the chat log.
---@param instance ConductorInstance
---@param target ConductorChatEntry
function M.remove_entry(instance, target)
  for index = #instance.log, 1, -1 do
    if instance.log[index] == target then
      table.remove(instance.log, index)
      return
    end
  end
end

---After an attached terminal pi switched sessions, ask it for its session file
---and, when it changed, reload the chat from the new file.
---@param instance ConductorInstance
function M.follow_session(instance)
  local handle = instance.handle
  if not handle or not handle.request then
    return
  end
  instance.prompt_note = nil
  instance.status_before_prompt = nil
  handle.request({ type = 'get_state' }, function(response)
    if response.success == false or type(response.data) ~= 'table' then
      return
    end
    local state = response.data
    local session_file = type(state.sessionFile) == 'string' and state.sessionFile or nil
    if session_file and M.session_key(session_file) ~= M.session_key(instance.session_path) then
      instance.session_path = session_file
      M.reset_log(instance)
      M.load_history(instance)
    end
    if type(state.sessionName) == 'string' and state.sessionName ~= '' then
      instance.name = state.sessionName
      instance.name_explicit = true
    end
    if instance.status == 'streaming' and state.isStreaming ~= true then
      set_status(instance, 'idle')
    end
    broadcast()
    M.refresh_info(instance)
  end)
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
  -- A bridged pi echoes the prompt back as a `user_message` event.
  if not instance.handle.echoes_user_messages then
    instance.log[#instance.log + 1] = { role = 'user', text = text }
  end
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
  stop_watch(instance)
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
