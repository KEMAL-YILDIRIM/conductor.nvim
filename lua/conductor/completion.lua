---`/` command completion for the chat input bar.
---
---Uses blink.cmp when it is installed (one menu, no path/buffer noise: the
---input buffer has its own `conductor_input` filetype, restricted to the
---conductor source). Otherwise falls back to Neovim's built-in popup via
---`omnifunc`, opened automatically after a leading `/`.
local M = {}

M.FILETYPE = 'conductor_input'

---@param bufnr integer
---@return ConductorInstance|nil
local function instance_for(bufnr)
  local ok, id = pcall(vim.api.nvim_buf_get_var, bufnr, 'conductor_instance_id')
  if not ok then
    return nil
  end
  return require('conductor.supervisor').instances[id]
end

---The `/query` being typed: only on the first line, from column 0 to the
---cursor, with no whitespace yet (arguments are not completed).
---@param line string
---@param row integer 1-based cursor row
---@param col integer 0-based cursor byte column
---@return string|nil query text after the slash
function M.slash_query(line, row, col)
  if row ~= 1 then
    return nil
  end
  local before = line:sub(1, col)
  if before:sub(1, 2) == '//' then
    return nil
  end
  return before:match '^/(%S*)$'
end

---Completion items for the instance shown in `bufnr`. Calls back
---synchronously when the command list is cached.
---@param bufnr integer
---@param callback fun(items: ConductorCommandItem[])
function M.items(bufnr, callback)
  local instance = instance_for(bufnr)
  if not instance then
    callback {}
    return
  end
  local adapter = require('conductor.adapters.interface').get(instance.adapter)
  if not adapter.list_commands then
    callback {}
    return
  end
  adapter.list_commands(instance, callback)
end

---Synchronous variant: the cached list, or whatever is available right now.
---@param bufnr integer
---@return ConductorCommandItem[]
local function items_now(bufnr)
  local result = {}
  M.items(bufnr, function(items)
    result = items
  end)
  return result
end

---@param item ConductorCommandItem
---@return string
local function abbreviation(item)
  return '/' .. item.name .. (item.args and (' ' .. item.args) or '')
end

---`omnifunc` for the input buffer (`<C-x><C-o>`, and the native auto-trigger).
---@param findstart integer
---@param base string
---@return integer|table
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  if findstart == 1 then
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_get_current_line()
    if M.slash_query(line, cursor[1], cursor[2]) then
      return 0
    end
    return -3 -- cancel silently
  end
  local wanted = base:sub(2)
  local matches = {}
  for _, item in ipairs(items_now(bufnr)) do
    if vim.startswith(item.name, wanted) then
      matches[#matches + 1] = {
        word = '/' .. item.name,
        abbr = abbreviation(item),
        menu = '[' .. item.source .. ']',
        info = item.description ~= '' and item.description or nil,
      }
    end
  end
  return matches
end

---Whether a conductor completion menu (blink or native) is open.
---@return boolean
local function menu_visible()
  local ok, blink = pcall(require, 'blink.cmp')
  if ok and package.loaded['blink.cmp'] and blink.is_menu_visible and blink.is_menu_visible() then
    return true
  end
  return vim.fn.pumvisible() == 1
end

---If a completion menu is open, accept the selected item and return true.
---Used by the input bar's `<CR>` so accepting never sends the prompt.
---@return boolean
function M.accept_if_open()
  local ok, blink = pcall(require, 'blink.cmp')
  if ok and package.loaded['blink.cmp'] and blink.is_menu_visible and blink.is_menu_visible() then
    blink.select_and_accept()
    return true
  end
  if vim.fn.pumvisible() == 1 then
    vim.api.nvim_feedkeys(vim.keycode '<C-y>', 'n', false)
    return true
  end
  return false
end

---If a completion menu is open, close it and return true.
---@return boolean
function M.close_if_open()
  if not menu_visible() then
    return false
  end
  local ok, blink = pcall(require, 'blink.cmp')
  if ok and package.loaded['blink.cmp'] and blink.is_menu_visible and blink.is_menu_visible() then
    blink.hide()
  end
  if vim.fn.pumvisible() == 1 then
    vim.api.nvim_feedkeys(vim.keycode '<C-e>', 'n', false)
  end
  return true
end

local blink_state = nil ---@type 'registered'|'unavailable'|nil

---Register the conductor source with blink.cmp once. Restricts the
---`conductor_input` filetype to that source unless the user configured it.
---@return boolean registered
local function register_blink()
  if blink_state then
    return blink_state == 'registered'
  end
  blink_state = 'unavailable'
  local ok, blink = pcall(require, 'blink.cmp')
  if not ok or type(blink.add_source_provider) ~= 'function' then
    return false
  end
  local config_ok, config = pcall(require, 'blink.cmp.config')
  if not config_ok or type(config.sources) ~= 'table' then
    return false
  end
  local registered = pcall(function()
    if config.sources.providers.conductor == nil then
      blink.add_source_provider('conductor', { name = 'Conductor', module = 'conductor.blink' })
    end
    if config.sources.per_filetype[M.FILETYPE] == nil then
      config.sources.per_filetype[M.FILETYPE] = { 'conductor' }
    end
  end)
  if registered then
    blink_state = 'registered'
  end
  return registered
end

---Open the native popup after a leading `/` while there is still something
---to complete (an exact, non-prefix match does not reopen it after accepting).
---@param bufnr integer
local function native_auto_trigger(bufnr)
  if vim.fn.pumvisible() == 1 then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)
  local query = M.slash_query(vim.api.nvim_get_current_line(), cursor[1], cursor[2])
  if not query then
    return
  end
  for _, item in ipairs(items_now(bufnr)) do
    if vim.startswith(item.name, query) and item.name ~= query then
      vim.api.nvim_feedkeys(vim.keycode '<C-x><C-o>', 'n', false)
      return
    end
  end
end

---Set up completion on a chat input buffer.
---@param bufnr integer
function M.attach(bufnr)
  vim.bo[bufnr].omnifunc = "v:lua.require'conductor.completion'.omnifunc"
  if not require('conductor.config').options.chat.slash_completion then
    return
  end
  if register_blink() then
    return
  end
  -- No blink: native popup. `popup` (info float) needs a recent Neovim.
  if not pcall(function()
    vim.bo[bufnr].completeopt = 'menuone,noinsert,popup'
  end) then
    pcall(function()
      vim.bo[bufnr].completeopt = 'menuone,noinsert'
    end)
  end
  vim.api.nvim_create_autocmd('TextChangedI', {
    buffer = bufnr,
    callback = function()
      native_auto_trigger(bufnr)
    end,
  })
end

return M
