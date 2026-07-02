---Pi RPC transport: spawns `pi --mode rpc`, speaks JSONL over stdin/stdout,
---and translates pi's event stream into conductor's normalized events.
---Protocol reference: pi-coding-agent docs/rpc.md (strict LF-delimited JSONL).
local M = {}

local request_counter = 0

local function next_request_id()
  request_counter = request_counter + 1
  return ('conductor-%d'):format(request_counter)
end

---Summarize tool call arguments for display (best-effort, single line).
---@param args table|nil
---@return string
local function summarize_args(args)
  if type(args) ~= 'table' then
    return ''
  end
  local summary = args.command or args.path or args.pattern or ''
  if type(summary) ~= 'string' then
    return ''
  end
  summary = summary:gsub('\n.*', ' …')
  if #summary > 80 then
    summary = summary:sub(1, 77) .. '…'
  end
  return summary
end

---Translate one decoded pi RPC line into zero or more normalized events.
---@param decoded table
---@param emit fun(event: table)
---@param pending table<string, fun(response: table)>
local function translate(decoded, emit, pending)
  local kind = decoded.type

  if kind == 'response' then
    if decoded.id and pending[decoded.id] then
      local callback = pending[decoded.id]
      pending[decoded.id] = nil
      callback(decoded)
    end
    if decoded.success == false then
      emit { type = 'error', message = ('%s failed: %s'):format(decoded.command or '?', decoded.error or 'unknown error') }
    end
  elseif kind == 'agent_start' then
    emit { type = 'agent_start' }
  elseif kind == 'agent_end' then
    emit { type = 'agent_end' }
  elseif kind == 'message_update' then
    local delta = decoded.assistantMessageEvent
    if type(delta) == 'table' then
      if delta.type == 'text_start' then
        emit { type = 'text_start' }
      elseif delta.type == 'text_delta' and type(delta.delta) == 'string' then
        emit { type = 'text_delta', text = delta.delta }
      end
    end
  elseif kind == 'tool_execution_start' then
    emit { type = 'tool_start', name = decoded.toolName, summary = summarize_args(decoded.args) }
  elseif kind == 'tool_execution_end' then
    local output = ''
    if type(decoded.result) == 'table' and type(decoded.result.content) == 'table' then
      local parts = {}
      for _, block in ipairs(decoded.result.content) do
        if type(block) == 'table' and block.type == 'text' and type(block.text) == 'string' then
          parts[#parts + 1] = block.text
        end
      end
      output = table.concat(parts, '\n')
    end
    emit { type = 'tool_end', name = decoded.toolName, is_error = decoded.isError == true, output = output }
  elseif kind == 'extension_ui_request' then
    local method = decoded.method
    if method == 'notify' then
      emit { type = 'notify', message = decoded.message or '', level = decoded.notifyType or 'info' }
    elseif method == 'select' or method == 'confirm' or method == 'input' or method == 'editor' then
      emit { type = 'ui_request', request = decoded }
    end
    -- setStatus/setWidget/setTitle/set_editor_text are TUI cosmetics; ignored.
  elseif kind == 'auto_retry_start' then
    emit { type = 'notify', message = ('retrying (%d/%d): %s'):format(decoded.attempt or 0, decoded.maxAttempts or 0, decoded.errorMessage or ''), level = 'warning' }
  elseif kind == 'extension_error' then
    emit { type = 'notify', message = ('extension error: %s'):format(decoded.error or '?'), level = 'error' }
  end
end

---Spawn a managed pi RPC instance.
---@param opts { cwd?: string, session_path?: string, name?: string, ephemeral?: boolean, on_event: fun(event: table), on_exit: fun(code: integer) }
---@return ConductorInstanceHandle|nil handle, string|nil error
function M.spawn(opts)
  local pi_options = require('conductor.config').options.adapters.pi

  local argv = { pi_options.cmd, '--mode', 'rpc' }
  if opts.session_path then
    vim.list_extend(argv, { '--session', opts.session_path })
  end
  if opts.name then
    vim.list_extend(argv, { '--name', opts.name })
  end
  if opts.ephemeral then
    argv[#argv + 1] = '--no-session'
  end

  ---@type table<string, fun(response: table)>
  local pending = {}
  local stdout_buffer = ''

  local function emit(event)
    vim.schedule(function()
      opts.on_event(event)
    end)
  end

  local job_id = vim.fn.jobstart(argv, {
    cwd = opts.cwd,
    stdout_buffered = false,
    on_stdout = function(_, data)
      -- jobstart splits on newlines already, but partial lines arrive as
      -- unterminated fragments: data[1] continues the previous fragment.
      for index, chunk in ipairs(data) do
        if index == 1 then
          stdout_buffer = stdout_buffer .. chunk
        else
          local line = stdout_buffer
          stdout_buffer = chunk
          if line ~= '' then
            if line:sub(-1) == '\r' then
              line = line:sub(1, -2)
            end
            local ok, decoded = pcall(vim.json.decode, line)
            if ok and type(decoded) == 'table' then
              translate(decoded, emit, pending)
            end
          end
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        opts.on_exit(code)
      end)
    end,
  })

  if job_id <= 0 then
    return nil, ('failed to start %s (jobstart returned %d)'):format(pi_options.cmd, job_id)
  end

  local function send(command_table)
    vim.fn.chansend(job_id, vim.json.encode(command_table) .. '\n')
  end

  ---@type ConductorInstanceHandle
  local handle = {
    prompt = function(text, prompt_opts)
      prompt_opts = prompt_opts or {}
      local command = { type = 'prompt', message = text }
      if prompt_opts.streaming then
        command.streamingBehavior = 'steer'
      end
      send(command)
    end,
    respond_ui = function(payload)
      payload.type = 'extension_ui_response'
      send(payload)
    end,
    abort = function()
      send { type = 'abort' }
    end,
    kill = function()
      vim.fn.jobstop(job_id)
    end,
    get_state = function(callback)
      local id = next_request_id()
      pending[id] = callback
      send { id = id, type = 'get_state' }
    end,
  }

  return handle
end

return M
