local M = {}

---@class ConductorConfig
local defaults = {
  ---Default adapter used by pickers and commands.
  default_adapter = 'pi',
  adapters = {
    pi = {
      ---Executable used to resume sessions.
      cmd = 'pi',
      ---Session storage root. Defaults to ~/.pi/agent/sessions.
      sessions_dir = nil,
    },
  },
  picker = {
    ---Picker backend: 'telescope' or 'fzf-lua'.
    backend = 'telescope',
    ---Maximum number of log entries rendered in the previewer.
    preview_max_entries = 200,
    ---Truncate each preview message body to this many lines (0 = no limit).
    preview_max_lines_per_entry = 20,
  },
  sidebar = {
    ---Sidebar width in columns.
    width = 36,
  },
  browser = {
    ---Session-list panel width in columns.
    width = 44,
  },
  terminal = {
    ---How to open the resumed session:
    ---  'snacks'   - snacks.nvim terminal in a new nvim tab
    ---  'split'    - native nvim terminal in a new nvim tab
    ---  'external' - hand off to `terminal.open` (e.g. a new WezTerm tab)
    backend = 'snacks',
    ---Options passed to Snacks.terminal win config.
    snacks_win = { position = 'right', width = 0.5 },
    ---Handler for the 'external' backend. Receives the resume command so you
    ---can launch it in whatever terminal you like. Return truthy to signal
    ---success; return falsy/nil (or error) to fall back to a native nvim tab.
    ---Example (new WezTerm tab):
    ---  open = function(o)
    ---    return vim.system(vim.list_extend(
    ---      { 'wezterm', 'cli', 'spawn', '--cwd', o.cwd, '--' }, o.argv)):wait().code == 0
    ---  end
    ---@type nil|fun(opts: { argv: string[], cwd: string|nil, session: ConductorSession }): boolean|nil
    open = nil,
  },
  ---Buffer-local keybindings, grouped by conductor context. Override any key by
  ---passing the same path in `setup()`; set a key to `false` to disable it.
  keymaps = {
    ---Session browser list panel (`:Conductor browse`).
    browser_list = {
      open = '<CR>', ---Open the session content in the main window.
      resume = 'gr', ---Resume the session in a terminal.
      attach = 'ga', ---Attach as a managed (headless RPC) instance.
      open_raw = 'go', ---Open the raw log file.
      toggle_cwd = 'gc', ---Toggle cwd-only / all-projects filter.
      refresh = 'gR', ---Refresh the session list.
      new = 'gn', ---Create a new session.
      close = 'q', ---Close the browser.
    },
    ---Session browser content window (parsed log view).
    browser_content = {
      toggle_tool = '<CR>', ---Toggle tool-call output under the cursor.
      next_tool = ']t', ---Jump to the next tool call.
      prev_tool = '[t', ---Jump to the previous tool call.
      close = 'q', ---Close the browser.
    },
    ---Live sessions sidebar (`:Conductor panel`).
    sidebar = {
      open_chat = '<CR>', ---Open the chat buffer for the instance under the cursor.
      prompt = 'p', ---Send a prompt without opening the chat.
      new = 'n', ---Create a new session.
      stop = 's', ---Stop the running agent.
      kill = 'x', ---Kill / remove the instance.
      close = 'q', ---Close the sidebar.
    },
    ---Chat log window.
    chat = {
      focus_input = 'i', ---Focus the input bar in insert mode.
      toggle_tool = '<CR>', ---Toggle tool-call output under the cursor.
      next_tool = ']t', ---Jump to the next tool call.
      prev_tool = '[t', ---Jump to the previous tool call.
      abort = '<C-c>', ---Abort the running agent.
      close = 'q', ---Close the chat view.
    },
    ---Chat input bar (normal + insert mode).
    input = {
      send = '<CR>', ---Send the prompt.
      newline = '<S-CR>', ---Insert a literal newline (insert mode).
      focus_log = '<C-k>', ---Focus the log window.
      abort = '<C-c>', ---Abort the running agent.
      close = 'q', ---Close the chat view (normal mode).
    },
    ---Keybinding cheatsheet, attached to every conductor buffer.
    help = {
      toggle = 'g?', ---Toggle the keybinding help float.
    },
  },
}

M.options = vim.deepcopy(defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

---Set a buffer-local conductor keymap for `context.action`, honoring user
---overrides. Passing a key of `false` (or `nil`) in config disables it.
---@param context string key group under `options.keymaps` (e.g. 'sidebar')
---@param action string action name within the group (e.g. 'close')
---@param mode string|string[] keymap mode(s)
---@param rhs string|function
---@param opts table keymap options (must include `buffer`); `desc` is required
function M.map(context, action, mode, rhs, opts)
  local group = M.options.keymaps[context]
  local lhs = group and group[action]
  if not lhs then
    return
  end
  vim.keymap.set(mode, lhs, rhs, opts)
end

return M
