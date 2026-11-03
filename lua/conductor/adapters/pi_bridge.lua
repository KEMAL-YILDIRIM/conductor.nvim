---Pi bridge transport: connects to the pipe advertised by the conductor-presence
---extension inside an already-running (terminal) pi, instead of spawning a
---second pi on the same session file. That pi stays the only writer.
---The wire format mirrors pi's RPC stream (LF-delimited JSON), so events go
---through pi_rpc's shared `translate`. See pi-extension/conductor-presence.ts.
local M = {}

local request_counter = 0

local function next_request_id()
  request_counter = request_counter + 1
  return ('conductor-bridge-%d'):format(request_counter)
end

---Connect to a terminal pi's bridge.
---@param opts { bridge: string, on_event: fun(event: table), on_exit: fun(code: integer) }
---@return ConductorInstanceHandle|nil handle, string|nil error
function M.connect(opts)
  local translate = require('conductor.adapters.pi_rpc').translate
  local pipe = vim.uv.new_pipe(false)
  if not pipe then
    return nil, 'could not create a pipe'
  end

  ---@type table<string, fun(response: table)>
  local pending = {}
  local buffer = ''
  local connected = false
  local closed = false
  local killed = false
  ---Writes issued before the connection completes.
  local queued = {}

  local function emit(event)
    vim.schedule(function()
      opts.on_event(event)
    end)
  end

  ---Close once; fail every waiting request; report the exit (unless killed).
  ---@param reason string|nil
  local function close(reason)
    if closed then
      return
    end
    closed = true
    if not pipe:is_closing() then
      pipe:close()
    end
    local waiting = pending
    pending = {}
    vim.schedule(function()
      for _, callback in pairs(waiting) do
        callback { success = false, error = 'bridge closed' }
      end
      if killed then
        return
      end
      if reason then
        opts.on_event { type = 'error', message = 'pi bridge: ' .. reason }
      end
      opts.on_exit(reason and 1 or 0)
    end)
  end

  local function handle_line(line)
    if line:sub(-1) == '\r' then
      line = line:sub(1, -2)
    end
    if line == '' then
      return
    end
    local ok, decoded = pcall(vim.json.decode, line)
    if ok and type(decoded) == 'table' then
      translate(decoded, emit, pending)
    end
  end

  local function send(command_table)
    if closed then
      return
    end
    local line = vim.json.encode(command_table) .. '\n'
    if connected then
      pipe:write(line)
    else
      queued[#queued + 1] = line
    end
  end

  pipe:connect(opts.bridge, function(connect_error)
    if connect_error then
      close(('could not connect to %s (%s) — is that pi still running?'):format(opts.bridge, connect_error))
      return
    end
    connected = true
    for _, line in ipairs(queued) do
      pipe:write(line)
    end
    queued = {}
    pipe:read_start(function(read_error, chunk)
      if read_error then
        close(read_error)
        return
      end
      if not chunk then
        -- The terminal pi exited or switched sessions.
        close(nil)
        return
      end
      -- Decode on the main loop: keeps line order and allows any API call.
      vim.schedule(function()
        buffer = buffer .. chunk
        local newline = buffer:find('\n', 1, true)
        while newline do
          local line = buffer:sub(1, newline - 1)
          buffer = buffer:sub(newline + 1)
          handle_line(line)
          newline = buffer:find('\n', 1, true)
        end
      end)
    end)
  end)

  ---@param command_table table
  ---@param callback fun(response: table)|nil
  ---@return string id
  local function request(command_table, callback)
    local id = next_request_id()
    if closed then
      if callback then
        vim.schedule(function()
          callback { success = false, error = 'bridge closed' }
        end)
      end
      return id
    end
    if callback then
      pending[id] = callback
    end
    command_table.id = id
    send(command_table)
    return id
  end

  ---@type ConductorInstanceHandle
  local handle = {
    -- The bridge echoes every user message (ours and terminal-typed) back as
    -- a `user_message` event, so the supervisor must not log prompts itself.
    echoes_user_messages = true,
    bridge = opts.bridge,
    prompt = function(text)
      -- The extension picks steer vs. a fresh turn from pi's own idle state.
      request({ type = 'prompt', message = text }, function(response)
        if response.success == false then
          opts.on_event { type = 'error', message = ('prompt failed: %s'):format(response.error or 'unknown error') }
        end
      end)
    end,
    respond_ui = function()
      -- Dialogs are answered in the terminal; nothing to send.
    end,
    abort = function()
      send { type = 'abort' }
    end,
    kill = function()
      -- Detach only: never stop the user's terminal pi.
      killed = true
      close(nil)
    end,
    get_state = function(callback)
      request({ type = 'get_state' }, callback)
    end,
    request = request,
  }

  return handle
end

return M
