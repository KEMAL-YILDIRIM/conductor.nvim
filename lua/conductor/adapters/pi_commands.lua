---Pi built-in slash commands for managed (RPC) sessions.
---
---pi only runs its built-in commands (`/model`, `/compact`, ...) in its terminal
---interface; sent as a `prompt` they would reach the model as plain text. Most
---have a dedicated RPC request, so this module intercepts them (plus `!cmd`
---shell shortcuts) before the input reaches `handle.prompt`.
---
---Skills (`/skill:name`), prompt templates and extension commands are handled
---by pi itself and pass through untouched. Their names come from pi's
---`get_commands`, cached per instance, which also feeds `/` completion.
local M = {}

---@class ConductorCommandItem
---@field name string command name without the leading `/`
---@field args string|nil argument hint, e.g. '[provider/model]'
---@field description string
---@field source 'builtin'|'prompt'|'skill'|'extension'

---Commands discovered via `get_commands`, keyed by instance id. `nil` = not
---fetched yet (dispatch then lets unknown names through to pi).
---@type table<integer, ConductorCommandItem[]>
local discovered = {}

---Callbacks waiting for an in-flight `get_commands`, keyed by instance id.
---@type table<integer, fun(items: ConductorCommandItem[])[]>
local waiting = {}

local function supervisor()
  return require 'conductor.supervisor'
end

---@param instance ConductorInstance
---@param text string
local function note(instance, text)
  supervisor().note(instance, text)
end

---@param message string
local function warn(message)
  vim.notify('conductor: ' .. message, vim.log.levels.WARN)
end

---JSON null decodes to `vim.NIL`; render it (and nil) as '?'.
---@param value any
---@return string
local function show(value)
  if value == nil or value == vim.NIL then
    return '?'
  end
  return tostring(value)
end

---Send a request; failures are reported into the chat, successes go to
---`on_success` with the reply's `data` table (empty when absent / null).
---@param instance ConductorInstance
---@param command table
---@param on_success fun(data: table)
local function request(instance, command, on_success)
  if not instance.handle or not instance.handle.request then
    note(instance, '[error] instance has exited')
    return
  end
  local command_type = command.type
  instance.handle.request(command, function(response)
    if response.success == false then
      note(instance, ('[error] %s failed: %s'):format(command_type, response.error or 'unknown error'))
      return
    end
    on_success(type(response.data) == 'table' and response.data or {})
  end)
end

---Re-read pi's state after a session switch (new/fork/clone) so the instance
---points at the right session file.
---@param instance ConductorInstance
---@param after fun(state: table)|nil
local function sync_state(instance, after)
  request(instance, { type = 'get_state' }, function(state)
    instance.session_path = type(state.sessionFile) == 'string' and state.sessionFile or nil
    if type(state.sessionName) == 'string' and state.sessionName ~= '' then
      instance.name = state.sessionName
      instance.name_explicit = true
    end
    supervisor().broadcast()
    supervisor().refresh_info(instance)
    if after then
      after(state)
    end
  end)
end

---@param model table
---@return string
local function model_label(model)
  return ('%s/%s'):format(show(model.provider), show(model.id))
end

---@param models table[]
---@param on_choice fun(model: table)
local function select_model(models, on_choice)
  vim.ui.select(models, {
    prompt = 'Model',
    format_item = function(model)
      if type(model.name) == 'string' and model.name ~= model.id then
        return ('%s  (%s)'):format(model_label(model), model.name)
      end
      return model_label(model)
    end,
  }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

---@param instance ConductorInstance
---@param argument string
local function run_model(instance, argument)
  request(instance, { type = 'get_available_models' }, function(data)
    local models = type(data.models) == 'table' and data.models or {}
    local function apply(model)
      request(instance, { type = 'set_model', provider = model.provider, modelId = model.id }, function()
        note(instance, 'model: ' .. model_label(model))
        supervisor().refresh_info(instance)
      end)
    end
    if argument == '' then
      select_model(models, apply)
      return
    end
    local wanted = argument:lower()
    local matches = {}
    for _, model in ipairs(models) do
      local label = model_label(model):lower()
      if label == wanted or show(model.id):lower() == wanted then
        apply(model)
        return
      end
      local name = type(model.name) == 'string' and model.name:lower() or ''
      if label:find(wanted, 1, true) or name:find(wanted, 1, true) then
        matches[#matches + 1] = model
      end
    end
    if #matches == 1 then
      apply(matches[1])
    elseif #matches == 0 then
      note(instance, ('no model matches %q'):format(argument))
    else
      select_model(matches, apply)
    end
  end)
end

---@param instance ConductorInstance
---@param argument string
local function run_thinking(instance, argument)
  request(instance, { type = 'get_available_thinking_levels' }, function(data)
    local levels = type(data.levels) == 'table' and data.levels or {}
    local function apply(level)
      request(instance, { type = 'set_thinking_level', level = level }, function()
        note(instance, 'thinking level: ' .. level)
        supervisor().refresh_info(instance)
      end)
    end
    if argument == '' then
      vim.ui.select(levels, { prompt = 'Thinking level' }, function(choice)
        if choice then
          apply(choice)
        end
      end)
    elseif vim.tbl_contains(levels, argument) then
      apply(argument)
    else
      note(instance, ('thinking level %q is not available (choose: %s)'):format(argument, table.concat(levels, ', ')))
    end
  end)
end

---@param instance ConductorInstance
---@param argument string
local function run_compact(instance, argument)
  local command = { type = 'compact' }
  if argument ~= '' then
    command.customInstructions = argument
  end
  note(instance, 'compacting context…')
  request(instance, command, function(result)
    note(instance, ('context compacted: %s → %s tokens'):format(show(result.tokensBefore), show(result.estimatedTokensAfter)))
    supervisor().refresh_info(instance)
  end)
end

---@param instance ConductorInstance
local function run_new(instance)
  request(instance, { type = 'new_session' }, function(data)
    if data.cancelled == true then
      note(instance, 'new session cancelled by an extension')
      return
    end
    supervisor().reset_log(instance)
    sync_state(instance, function()
      note(instance, 'started a new session')
    end)
  end)
end

---@param instance ConductorInstance
---@param argument string
local function run_name(instance, argument)
  if argument == '' then
    request(instance, { type = 'get_state' }, function(state)
      note(instance, 'session name: ' .. (type(state.sessionName) == 'string' and state.sessionName or '(none)'))
    end)
    return
  end
  request(instance, { type = 'set_session_name', name = argument }, function()
    instance.name = argument
    instance.name_explicit = true
    supervisor().broadcast()
    note(instance, 'renamed to ' .. argument)
  end)
end

---@param instance ConductorInstance
local function run_session(instance)
  request(instance, { type = 'get_session_stats' }, function(stats)
    local tokens = type(stats.tokens) == 'table' and stats.tokens or {}
    local lines = {
      'session: ' .. (type(stats.sessionFile) == 'string' and stats.sessionFile or '(not saved)'),
      ('messages: %s user · %s assistant · %s tool calls'):format(show(stats.userMessages), show(stats.assistantMessages), show(stats.toolCalls)),
      ('tokens: %s in · %s out · %s cache read · %s cache write · %s total'):format(
        show(tokens.input),
        show(tokens.output),
        show(tokens.cacheRead),
        show(tokens.cacheWrite),
        show(tokens.total)
      ),
      ('cost: $%.4f'):format(tonumber(stats.cost) or 0),
    }
    local context = stats.contextUsage
    if type(context) == 'table' then
      lines[#lines + 1] = ('context: %s / %s tokens (%s%%)'):format(show(context.tokens), show(context.contextWindow), show(context.percent))
    end
    note(instance, table.concat(lines, '\n'))
  end)
end

---@param instance ConductorInstance
local function run_fork(instance)
  request(instance, { type = 'get_fork_messages' }, function(data)
    local messages = type(data.messages) == 'table' and data.messages or {}
    if #messages == 0 then
      note(instance, 'nothing to fork from yet')
      return
    end
    vim.ui.select(messages, {
      prompt = 'Fork from message',
      format_item = function(message)
        local first_line = (show(message.text):gsub('\n.*', ' …'))
        return first_line
      end,
    }, function(choice)
      if not choice then
        return
      end
      request(instance, { type = 'fork', entryId = choice.entryId }, function(result)
        if result.cancelled == true then
          note(instance, 'fork cancelled by an extension')
          return
        end
        -- Reload the (shorter) forked history from disk. No chat note here:
        -- load_history only seeds an *empty* log.
        supervisor().reset_log(instance)
        sync_state(instance, function()
          supervisor().load_history(instance)
          vim.notify(('[%s] forked — edit the message and send it'):format(instance.name), vim.log.levels.INFO)
          local text = type(result.text) == 'string' and result.text or show(choice.text)
          require('conductor.chatlog').set_input(instance, text)
        end)
      end)
    end)
  end)
end

---@param instance ConductorInstance
local function run_clone(instance)
  request(instance, { type = 'clone' }, function(result)
    if result.cancelled == true then
      note(instance, 'clone cancelled by an extension')
      return
    end
    sync_state(instance, function()
      note(instance, 'cloned the session; you are now working in the copy')
    end)
  end)
end

---@param instance ConductorInstance
---@param argument string
local function run_export(instance, argument)
  local command = { type = 'export_html' }
  if argument ~= '' then
    local path = vim.fn.expand(argument)
    -- pi resolves relative paths against its own cwd; make that explicit.
    if vim.fn.isabsolutepath(path) == 0 and instance.cwd then
      path = vim.fs.joinpath(instance.cwd, path)
    end
    command.outputPath = path
  end
  request(instance, command, function(data)
    note(instance, 'exported to ' .. show(data.path))
  end)
end

---@param instance ConductorInstance
local function run_copy(instance)
  request(instance, { type = 'get_last_assistant_text' }, function(data)
    if type(data.text) ~= 'string' then
      note(instance, 'no assistant reply to copy')
      return
    end
    vim.fn.setreg('+', data.text)
    vim.fn.setreg('"', data.text)
    vim.notify(('[%s] copied the last reply'):format(instance.name), vim.log.levels.INFO)
  end)
end

local run_help -- defined below (needs the BUILTINS list)

---Run a `!cmd` / `!!cmd` shell shortcut as a collapsible tool entry.
---@param instance ConductorInstance
---@param command_text string
---@param exclude_from_context boolean
local function run_bash(instance, command_text, exclude_from_context)
  local summary = command_text:gsub('\n.*', ' …')
  local entry = supervisor().append(instance, {
    role = 'tool',
    text = exclude_from_context and 'bash (not sent to model)' or 'bash',
    summary = summary,
    running = true,
    expanded = true,
    -- Keeps the agent's own `bash` tool_end events from matching this entry.
    local_command = true,
  })
  if not instance.handle or not instance.handle.request then
    entry.running, entry.is_error, entry.output = false, true, 'instance has exited'
    require('conductor.chatlog').refresh(instance)
    return
  end
  local command = { type = 'bash', command = command_text }
  if exclude_from_context then
    command.excludeFromContext = true
  end
  instance.handle.request(command, function(response)
    entry.running = false
    if response.success == false then
      entry.is_error = true
      entry.output = response.error or 'unknown error'
    else
      local data = type(response.data) == 'table' and response.data or {}
      local output = type(data.output) == 'string' and data.output or ''
      local exit_code = tonumber(data.exitCode)
      if data.truncated == true and type(data.fullOutputPath) == 'string' then
        output = output .. '\n[output truncated — full log: ' .. data.fullOutputPath .. ']'
      end
      if data.cancelled == true then
        output = output .. '\n[cancelled]'
      elseif exit_code and exit_code ~= 0 then
        output = output .. ('\n[exit code %d]'):format(exit_code)
      end
      entry.output = vim.trim(output)
      entry.is_error = data.cancelled == true or (exit_code ~= nil and exit_code ~= 0)
    end
    require('conductor.chatlog').refresh(instance)
  end)
end

---Built-in commands conductor implements over RPC. `busy` = refused while the
---agent is replying (they switch or rewrite the session under it).
---@type { name: string, args?: string, description: string, busy?: boolean, run: fun(instance: ConductorInstance, argument: string) }[]
local BUILTINS = {
  { name = 'model', args = '[provider/model]', description = 'Select a model', busy = true, run = run_model },
  { name = 'thinking', args = '[level]', description = 'Set the thinking level', run = run_thinking },
  { name = 'compact', args = '[instructions]', description = 'Compact the context, optionally with custom instructions', busy = true, run = run_compact },
  { name = 'new', description = 'Start a new session', busy = true, run = run_new },
  { name = 'name', args = '[name]', description = 'Set the session name, or show it when omitted', run = run_name },
  { name = 'session', description = 'Show session information and statistics', run = run_session },
  { name = 'fork', description = 'Create a new session from an earlier user message', busy = true, run = run_fork },
  { name = 'clone', description = 'Duplicate the session at its current position', busy = true, run = run_clone },
  { name = 'export', args = '[path]', description = 'Export the session as HTML', run = run_export, bridge_unavailable = true },
  { name = 'copy', description = 'Copy the last assistant reply', run = run_copy },
  {
    name = 'help',
    description = 'List the available commands',
    run = function(instance)
      run_help(instance)
    end,
  },
}

---@type table<string, table>
local BUILTINS_BY_NAME = {}
for _, builtin in ipairs(BUILTINS) do
  BUILTINS_BY_NAME[builtin.name] = builtin
end

---pi terminal-only commands with no RPC equivalent: refused instead of being
---sent to the model as text.
---@type table<string, true>
local UNAVAILABLE = {}
for _, name in ipairs {
  'settings',
  'scoped-models',
  'login',
  'logout',
  'llama',
  'resume',
  'tree',
  'import',
  'share',
  'bug',
  'trust',
  'reload',
  'hotkeys',
  'changelog',
  'quit',
} do
  UNAVAILABLE[name] = true
end

---@param list ConductorCommandItem[]|nil
---@return ConductorCommandItem[]
local function with_builtins(list)
  local items = {}
  for _, builtin in ipairs(BUILTINS) do
    items[#items + 1] = { name = builtin.name, args = builtin.args, description = builtin.description, source = 'builtin' }
  end
  for _, item in ipairs(list or {}) do
    items[#items + 1] = item
  end
  return items
end

function run_help(instance)
  local lines = { 'built-in commands:' }
  for _, builtin in ipairs(BUILTINS) do
    lines[#lines + 1] = ('  /%s%s — %s'):format(builtin.name, builtin.args and (' ' .. builtin.args) or '', builtin.description)
  end
  lines[#lines + 1] = '  !cmd — run a shell command (!!cmd keeps its output from the model)'
  local list = discovered[instance.id]
  if list and #list > 0 then
    lines[#lines + 1] = 'pi commands:'
    for _, item in ipairs(list) do
      local description = item.description ~= '' and (' — ' .. item.description) or ''
      lines[#lines + 1] = ('  /%s [%s]%s'):format(item.name, item.source, description)
    end
  end
  lines[#lines + 1] = 'start a message with // to send a literal /word to the model'
  note(instance, table.concat(lines, '\n'))
end

---Commands available to an instance (built-ins first, then pi's discovered
---commands). Calls back synchronously when already cached; otherwise fetches
---`get_commands` once, sharing the request between concurrent callers.
---@param instance ConductorInstance
---@param callback fun(items: ConductorCommandItem[])
function M.list_commands(instance, callback)
  local cached = discovered[instance.id]
  if cached then
    callback(with_builtins(cached))
    return
  end
  if not instance.handle or not instance.handle.request then
    callback(with_builtins(nil))
    return
  end
  if waiting[instance.id] then
    table.insert(waiting[instance.id], callback)
    return
  end
  waiting[instance.id] = { callback }
  instance.handle.request({ type = 'get_commands' }, function(response)
    local list = nil
    if response.success ~= false and type(response.data) == 'table' and type(response.data.commands) == 'table' then
      list = {}
      for _, command in ipairs(response.data.commands) do
        if type(command) == 'table' and type(command.name) == 'string' then
          list[#list + 1] = {
            name = command.name,
            description = type(command.description) == 'string' and command.description or '',
            source = type(command.source) == 'string' and command.source or 'extension',
          }
        end
      end
      discovered[instance.id] = list
    end
    local callbacks = waiting[instance.id] or {}
    waiting[instance.id] = nil
    for _, waiting_callback in ipairs(callbacks) do
      waiting_callback(with_builtins(list))
    end
  end)
end

---Route one line of user input.
---  'handled'      conductor ran it (built-in command or shell shortcut)
---  'rejected'     refused with a warning; the caller keeps the text editable
---  'passthrough'  send to pi as a prompt (second return = replacement text)
---@param instance ConductorInstance
---@param text string trimmed input
---@return 'handled'|'rejected'|'passthrough' outcome, string|nil replacement
function M.dispatch(instance, text)
  local bridged = instance.handle and instance.handle.bridge ~= nil
  local bang, shell_command = text:match '^(!!?)%s*(.-)%s*$'
  if bang then
    if bridged then
      warn '!command is not available for a session attached to a terminal pi — run it in the terminal'
      return 'rejected'
    end
    if shell_command == '' then
      warn 'empty shell command'
      return 'rejected'
    end
    run_bash(instance, shell_command, bang == '!!')
    return 'handled'
  end

  -- `//word` escapes a literal leading slash.
  if text:sub(1, 2) == '//' then
    return 'passthrough', text:sub(2)
  end

  local name, rest = text:match '^/([%w][%w%-_:%.]*)(.*)$'
  -- Not a command token (e.g. a path like `/home/user`): plain prompt.
  if not name or (rest ~= '' and not rest:match '^%s') then
    return 'passthrough'
  end
  local argument = vim.trim(rest)

  local builtin = BUILTINS_BY_NAME[name]
  if builtin and builtin.bridge_unavailable and bridged then
    warn(('/%s is not available for a session attached to a terminal pi — run it in the terminal'):format(name))
    return 'rejected'
  end
  if builtin then
    if builtin.busy and instance.status == 'streaming' then
      warn(('/%s is not available while the agent is replying — stop it first (<C-c>)'):format(name))
      return 'rejected'
    end
    builtin.run(instance, argument)
    return 'handled'
  end

  -- pi's own commands come before the terminal-only list: an extension may
  -- register one of those names (e.g. `/llama`).
  local list = discovered[instance.id]
  for _, item in ipairs(list or {}) do
    if item.name == name then
      return 'passthrough'
    end
  end

  if UNAVAILABLE[name] then
    warn(('/%s only works in pi\'s terminal interface, not in a managed session'):format(name))
    return 'rejected'
  end

  if list == nil then
    -- Command list not loaded yet: let pi decide rather than guess.
    return 'passthrough'
  end
  warn(('unknown command /%s — /help lists commands; start with // to send it as text'):format(name))
  return 'rejected'
end

---Fetch the details shown for the selected session in the live sessions
---sidebar. Silent (background refresh): failures leave the fields untouched
---instead of writing errors into the chat. Calls back once per reply with a
---partial update; `false` marks a field pi reported as absent.
---@param instance ConductorInstance
---@param callback fun(partial: ConductorInstanceInfo)
function M.fetch_info(instance, callback)
  local handle = instance.handle
  if not handle or not handle.request then
    return
  end
  handle.request({ type = 'get_state' }, function(response)
    if response.success == false or type(response.data) ~= 'table' then
      return
    end
    local state = response.data
    -- A fresh (`n` / `:Conductor new`) instance has no session file until pi
    -- reports one; record it so the sidebar can dedupe it against its own
    -- presence entry in the External section.
    if not instance.session_path and type(state.sessionFile) == 'string' and state.sessionFile ~= '' then
      instance.session_path = state.sessionFile
    end
    callback {
      model = type(state.model) == 'table' and model_label(state.model) or false,
      thinking = type(state.thinkingLevel) == 'string' and state.thinkingLevel or false,
    }
  end)
  handle.request({ type = 'get_session_stats' }, function(response)
    if response.success == false or type(response.data) ~= 'table' then
      return
    end
    local usage = response.data.contextUsage
    if type(usage) ~= 'table' then
      callback { context = false }
      return
    end
    -- `tokens` / `percent` are null right after a compaction (unknown until
    -- the next turn); tonumber(vim.NIL) yields nil.
    callback {
      context = {
        tokens = tonumber(usage.tokens),
        window = tonumber(usage.contextWindow),
        percent = tonumber(usage.percent),
      },
    }
  end)
end

return M
