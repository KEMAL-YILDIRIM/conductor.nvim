---conductor.nvim — manage AI agent sessions from Neovim.
---Phase 1: session discovery + telescope picker with conversation-log preview + resume in terminal.
local M = {}

local config = require 'conductor.config'
local interface = require 'conductor.adapters.interface'

---@param opts table|nil
function M.setup(opts)
  config.setup(opts)
  interface.register(require 'conductor.adapters.pi')

  vim.api.nvim_create_user_command('Conductor', function(command)
    local subcommand = command.fargs[1] or 'sessions'
    if subcommand == 'sessions' then
      M.pick_sessions()
    elseif subcommand == 'here' then
      M.pick_sessions { cwd = vim.fn.getcwd() }
    elseif subcommand == 'panel' then
      require('conductor.sidebar').toggle()
    elseif subcommand == 'new' then
      local name = command.fargs[2]
      local instance, spawn_error = require('conductor.supervisor').spawn { name = name }
      if instance then
        require('conductor.sidebar').open()
        require('conductor.chatlog').open(instance)
      else
        vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
      end
    else
      vim.notify(('conductor: unknown subcommand %q'):format(subcommand), vim.log.levels.ERROR)
    end
  end, {
    nargs = '*',
    complete = function()
      return { 'sessions', 'here', 'panel', 'new' }
    end,
    desc = 'Conductor: manage AI agent sessions',
  })
end

---Open the telescope session picker.
---@param opts { cwd?: string, adapter?: string }|nil
function M.pick_sessions(opts)
  local ok, telescope = pcall(require, 'telescope')
  if not ok then
    vim.notify('conductor: telescope.nvim is required for the session picker', vim.log.levels.ERROR)
    return
  end
  telescope.extensions.conductor.sessions(opts)
end

---Resume a session in a terminal.
---@param session ConductorSession
function M.resume(session)
  local adapter = interface.get(session.adapter)
  local argv = adapter.resume_cmd(session)
  local terminal_options = config.options.terminal

  if terminal_options.backend == 'snacks' then
    local ok, snacks = pcall(require, 'snacks')
    if ok then
      snacks.terminal(argv, {
        cwd = session.cwd,
        win = terminal_options.snacks_win,
        interactive = true,
      })
      return
    end
  end

  -- Fallback: plain split terminal.
  vim.cmd 'vsplit'
  vim.fn.jobstart(argv, { cwd = session.cwd, term = true })
  vim.cmd 'startinsert'
end

return M
