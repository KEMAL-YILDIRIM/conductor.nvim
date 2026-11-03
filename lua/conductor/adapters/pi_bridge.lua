---Pi bridge transport: connects to the pipe advertised by the conductor-presence
---extension inside an already-running (terminal) pi, instead of spawning a
---second pi on the same session file. That pi stays the only writer.
---The wire format mirrors pi's RPC stream (LF-delimited JSON), so events go
---through pi_rpc's shared `translate`. See pi-extension/conductor-presence.ts.
---
---Session switches (/new, /fork, /clone — from Neovim or the terminal) replace
---the extension instance and its pipe. The old pipe announces
---`session_replaced` before closing; we then poll the presence file of the same
---pid for the new pipe and reconnect, keeping the same handle. Unanswered
---requests are re-sent on the new pipe, except prompts (never run twice).
local M = {}

local request_counter = 0

local function next_request_id()
  request_counter = request_counter + 1
  return ('conductor-bridge-%d'):format(request_counter)
end

---How long to wait for the replacement pipe after a session switch.
local RECONNECT_INTERVAL_MS = 200
local RECONNECT_ATTEMPTS = 50

---Connect to a terminal pi's bridge.
---@param opts { bridge: string, pid?: integer, on_event: fun(event: table), on_exit: fun(code: integer) }
---@return ConductorInstanceHandle|nil handle, string|nil error
function M.connect(opts)
  local translate = require('conductor.adapters.pi_rpc').translate

  ---@type table<string, fun(response: table)>
  local pending = {}
  ---Requests not answered yet, by id: re-sent after a reconnect.
  ---@type table<string, { seq: integer, line: string, resend: boolean, written: boolean }>
  local inflight = {}
  local sequence = 0
  local pipe ---@type uv.uv_pipe_t|nil
  local current_path = opts.bridge
  local connected = false
  local replacing = false
  local closed = false
  local killed = false
  local handle ---@type ConductorInstanceHandle

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
    connected = false
    if pipe and not pipe:is_closing() then
      pipe:close()
    end
    local waiting = pending
    pending = {}
    inflight = {}
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

  ---Write every unsent request (in send order) to the current pipe. After a
  ---reconnect, prompts that already went to the old pipe fail instead of
  ---being re-sent, since pi may already have run them.
  local function flush()
    if not connected or replacing or closed or not pipe then
      return
    end
    local ordered = {}
    for id, item in pairs(inflight) do
      if not item.written then
        ordered[#ordered + 1] = { id = id, item = item }
      end
    end
    table.sort(ordered, function(a, b)
      return a.item.seq < b.item.seq
    end)
    for _, entry in ipairs(ordered) do
      entry.item.written = true
      pipe:write(entry.item.line)
    end
  end

  ---Mark everything sent to the old pipe for re-sending (or fail it).
  local function requeue_after_switch()
    for id, item in pairs(inflight) do
      if item.written then
        if item.resend then
          item.written = false
        else
          inflight[id] = nil
          local callback = pending[id]
          pending[id] = nil
          if callback then
            vim.schedule(function()
              callback { success = false, error = 'session switched before it was answered' }
            end)
          end
        end
      end
    end
  end

  local function handle_line(line)
    if line:sub(-1) == '\r' then
      line = line:sub(1, -2)
    end
    if line == '' then
      return
    end
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok or type(decoded) ~= 'table' then
      return
    end
    if decoded.type == 'session_replaced' then
      replacing = true
      return
    end
    if decoded.type == 'response' and decoded.id then
      inflight[decoded.id] = nil
    end
    translate(decoded, emit, pending)
  end

  local open -- forward declaration (reconnect calls it again)

  ---Poll the pid's presence file until it advertises a new pipe.
  local function await_replacement()
    if not opts.pid then
      close 'session switched and the new pipe is unknown (no pid)'
      return
    end
    requeue_after_switch()
    local attempts = 0
    local timer = vim.uv.new_timer()
    local old_path = current_path
    timer:start(
      RECONNECT_INTERVAL_MS,
      RECONNECT_INTERVAL_MS,
      vim.schedule_wrap(function()
        if timer:is_closing() then
          return
        end
        attempts = attempts + 1
        local presence = require('conductor.external').read_presence(opts.pid)
        local new_path = presence and presence.bridge
        if closed or (new_path and new_path ~= old_path) or attempts >= RECONNECT_ATTEMPTS then
          timer:stop()
          timer:close()
          if closed then
            return
          end
          if new_path and new_path ~= old_path then
            open(new_path, true)
          else
            close 'the terminal pi did not come back after a session switch'
          end
        end
      end)
    )
  end

  ---@param path string
  ---@param is_reconnect boolean
  function open(path, is_reconnect)
    local this_pipe = vim.uv.new_pipe(false)
    if not this_pipe then
      close 'could not create a pipe'
      return
    end
    pipe = this_pipe
    connected = false
    local buffer = ''
    this_pipe:connect(path, function(connect_error)
      vim.schedule(function()
        if pipe ~= this_pipe or closed then
          if not this_pipe:is_closing() then
            this_pipe:close()
          end
          return
        end
        if connect_error then
          close(('could not connect to %s (%s) — is that pi still running?'):format(path, connect_error))
          return
        end
        current_path = path
        handle.bridge = path
        connected = true
        replacing = false
        flush()
        this_pipe:read_start(function(read_error, chunk)
          -- Process on the main loop, in order, so EOF follows the last data.
          vim.schedule(function()
            if pipe ~= this_pipe or closed then
              return
            end
            if read_error then
              close(read_error)
              return
            end
            if not chunk then
              connected = false
              if not this_pipe:is_closing() then
                this_pipe:close()
              end
              if replacing then
                await_replacement()
              else
                -- The terminal pi exited.
                close(nil)
              end
              return
            end
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
        if is_reconnect then
          opts.on_event { type = 'bridge_reconnected', bridge = path }
        end
      end)
    end)
  end

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
    sequence = sequence + 1
    inflight[id] = {
      seq = sequence,
      line = vim.json.encode(command_table) .. '\n',
      -- A prompt may already have started a turn: never send it twice.
      resend = command_table.type ~= 'prompt' and command_table.type ~= 'abort',
      written = false,
    }
    flush()
    return id
  end

  handle = {
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
      request { type = 'abort' }
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

  open(opts.bridge, false)
  return handle
end

return M
