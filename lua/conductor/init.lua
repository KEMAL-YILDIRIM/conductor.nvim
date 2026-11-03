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
    local subcommand = command.fargs[1] or 'browse'
    if subcommand == 'browse' then
      -- Session browser: list panel on the left (cwd sessions by default),
      -- conversation rendered in the main window on the right.
      require('conductor.browser').toggle()
    elseif subcommand == 'browse_all' then
      require('conductor.browser').toggle { cwd = false }
    elseif subcommand == 'sessions' then
      M.pick_sessions()
    elseif subcommand == 'here' then
      M.pick_sessions { cwd = vim.fn.getcwd() }
    elseif subcommand == 'panel' then
      require('conductor.sidebar').toggle()
    elseif subcommand == 'search' then
      require('conductor.search').open()
    elseif subcommand == 'new' then
      local name = command.fargs[2]
      -- Confirm the working directory before spawning: pre-fill the current
      -- cwd (editable) so it can be corrected without silently landing in the
      -- wrong project.
      vim.ui.input({ prompt = 'Location: ', default = vim.fn.getcwd(), completion = 'dir' }, function(location)
        if location == nil then
          return -- cancelled
        end
        local cwd = vim.fs.normalize(vim.fn.expand(vim.trim(location)))
        if cwd == '' then
          vim.notify('conductor: location must not be empty', vim.log.levels.ERROR)
          return
        end
        local instance, spawn_error = require('conductor.supervisor').spawn { name = name, name_explicit = name ~= nil, cwd = cwd }
        if instance then
          require('conductor.sidebar').open()
          require('conductor.chatlog').open(instance)
        else
          vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
        end
      end)
    else
      vim.notify(('conductor: unknown subcommand %q'):format(subcommand), vim.log.levels.ERROR)
    end
  end, {
    nargs = '*',
    complete = function()
      return { 'browse', 'browse_all', 'sessions', 'here', 'panel', 'new', 'search' }
    end,
    desc = 'Conductor: manage AI agent sessions',
  })

  -- Bring back the live sessions list from the last run (deferred so startup
  -- is not held up by the file read and history parses).
  vim.schedule(function()
    local ok, restore_error = pcall(require('conductor.persist').restore)
    if not ok then
      vim.notify('conductor: could not restore live sessions: ' .. tostring(restore_error), vim.log.levels.WARN)
    end
  end)
end

---Open the session picker (backend configurable: telescope or fzf-lua).
---@param opts { cwd?: string, adapter?: string, backend?: string }|nil
function M.pick_sessions(opts)
  require('conductor.picker').open(opts)
end

---Resume a session in a terminal (always opened in its own tab).
---@param session ConductorSession
function M.resume(session)
  local persist = require 'conductor.persist'
  local owner = persist.claimed_by(session.path)
  if owner then
    vim.notify('conductor: ' .. persist.claimed_message(owner), vim.log.levels.WARN)
    return
  end

  local adapter = interface.get(session.adapter)
  local argv = adapter.resume_cmd(session)
  local terminal_options = config.options.terminal

  -- 'external' backend: hand the resume command off to a user-supplied opener
  -- (e.g. spawn a new WezTerm tab) instead of taking over an nvim tab. Only
  -- fall back to an in-editor terminal if no handler is set or it fails.
  if terminal_options.backend == 'external' then
    local open = terminal_options.open
    if type(open) == 'function' then
      local ok, result = pcall(open, { argv = argv, cwd = session.cwd, session = session })
      if ok and result ~= false then
        return
      end
      vim.notify(
        'conductor: external terminal handler failed'
          .. (ok and '' or (': ' .. tostring(result)))
          .. '; falling back to nvim tab',
        vim.log.levels.WARN
      )
    else
      vim.notify(
        'conductor: terminal.backend is "external" but terminal.open is not set; '
          .. 'falling back to nvim tab',
        vim.log.levels.WARN
      )
    end
  end

  -- Open the resumed session on a dedicated tab so it never clutters the
  -- current (e.g. browser/sidebar) layout. The tab starts as a single empty
  -- scratch window that the terminal takes over.
  vim.cmd 'tabnew'

  if terminal_options.backend == 'snacks' then
    local ok, snacks = pcall(require, 'snacks')
    if ok then
      -- Use `terminal.open` (not the module's `__call`/`toggle`) so resuming
      -- always spawns a fresh terminal. `toggle` dedupes by cmd+cwd+env+count
      -- and would *hide* an already-open terminal for the same session,
      -- leaving the freshly created tab empty (the "stuck" symptom).
      --
      -- Force `position = 'current'` so the terminal replaces the scratch
      -- buffer *in place*, owning the whole tab. The previous approach opened
      -- a `position = 'right'` split and then closed the scratch window; that
      -- split-then-close raced Snacks' stacking/equalize and TermClose/Wipeout
      -- handlers, which is what left resume "stuck" in a half-torn layout.
      local win = vim.tbl_extend('force', terminal_options.snacks_win or {}, { position = 'current' })
      snacks.terminal.open(argv, {
        cwd = session.cwd,
        win = win,
        interactive = true,
      })
      return
    end
  end

  -- Fallback: native terminal reusing the new tab's window.
  vim.fn.jobstart(argv, { cwd = session.cwd, term = true })
  vim.cmd 'startinsert'
end

return M
