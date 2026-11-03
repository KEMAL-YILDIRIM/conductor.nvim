---Dedicated-tab helpers shared by the browser and the live sessions panel.
---Both panels live on their own tab so opening them never splits or resizes
---the user's working tab; closing them tears that tab down again when it holds
---nothing but conductor windows (or the blank scratch window `:tabnew` made).
local M = {}

---Open a fresh tab. Its single empty scratch window becomes the panel's main
---(right-hand) pane; the caller splits the panel off its left.
function M.open_dedicated()
  vim.cmd 'tabnew'
end

---A blank, unnamed, unmodified normal buffer — i.e. the `:tabnew` scratch.
---@param bufnr integer
---@return boolean
local function is_blank(bufnr)
  if vim.api.nvim_buf_get_name(bufnr) ~= '' or vim.bo[bufnr].buftype ~= '' or vim.bo[bufnr].modified then
    return false
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  return #lines == 1 and lines[1] == ''
end

---Close the tab containing `win` when every window in it is owned by the
---panel (per `is_owned`), a floating window, or the blank scratch. A live chat
---window keeps the tab alive (the caller then closes only its own windows, so
---the chat survives). Never closes the last tab.
---@param win integer|nil a panel window used to locate its tab
---@param is_owned fun(win: integer): boolean
---@return boolean closed whether the tab was closed (caller falls back otherwise)
function M.close_if_owned(win, is_owned)
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return false
  end
  if #vim.api.nvim_list_tabpages() < 2 then
    return false
  end
  local tab = vim.api.nvim_win_get_tabpage(win)
  for _, window in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local owned = is_owned(window)
      or vim.api.nvim_win_get_config(window).relative ~= ''
      or is_blank(vim.api.nvim_win_get_buf(window))
    if not owned then
      return false
    end
  end
  local ok = pcall(vim.cmd, ('tabclose %d'):format(vim.api.nvim_tabpage_get_number(tab)))
  return ok
end

return M
