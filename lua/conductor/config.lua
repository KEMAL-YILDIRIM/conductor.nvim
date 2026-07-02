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
    ---Maximum number of log entries rendered in the previewer.
    preview_max_entries = 200,
    ---Truncate each preview message body to this many lines (0 = no limit).
    preview_max_lines_per_entry = 20,
  },
  terminal = {
    ---How to open the resumed session: 'snacks' (snacks.nvim terminal) or 'split'.
    backend = 'snacks',
    ---Options passed to Snacks.terminal win config.
    snacks_win = { position = 'right', width = 0.5 },
  },
}

M.options = vim.deepcopy(defaults)

---@param opts table|nil
function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

return M
