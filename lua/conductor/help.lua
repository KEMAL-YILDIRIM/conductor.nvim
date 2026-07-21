---Floating keybinding cheatsheet for conductor buffers.
---
---Reads the buffer-local keymaps (which already carry a `desc`) and renders
---them in a centered float. Bound to `g?` in every conductor buffer; pressing
---`g?` again (or `q`/`<Esc>`) closes it, so the same shortcut toggles it.
local M = {}

---Tracks the open cheatsheet so `g?` can toggle it. `origin` is the buffer the
---help was opened from, letting a second `g?` press (from that buffer) close it.
local state = {
  winid = nil, ---@type integer|nil
  bufnr = nil, ---@type integer|nil
  origin = nil, ---@type integer|nil
}

local namespace = vim.api.nvim_create_namespace 'conductor_help'

local function window_valid()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

function M.close()
  if window_valid() then
    vim.api.nvim_win_close(state.winid, true)
  end
  state.winid = nil
  state.origin = nil
end

---Collect this buffer's normal-mode conductor keymaps, sorted by key.
---@param bufnr integer
---@return { lhs: string, desc: string }[]
local function collect_keymaps(bufnr)
  local toggle_key = require('conductor.config').options.keymaps.help.toggle
  local seen = {}
  local items = {}
  for _, mode in ipairs { 'n', 'i' } do
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      local desc = map.desc or ''
      -- Only surface documented conductor bindings; skip the help toggle
      -- itself and any undescribed maps.
      if desc:match '^Conductor:' and map.lhs ~= toggle_key and not seen[map.lhs] then
        seen[map.lhs] = true
        items[#items + 1] = { lhs = map.lhs, desc = desc:gsub('^Conductor:%s*', '') }
      end
    end
  end
  table.sort(items, function(a, b)
    return a.lhs < b.lhs
  end)
  return items
end

---Open the cheatsheet for the current buffer.
function M.open()
  local origin = vim.api.nvim_get_current_buf()
  local items = collect_keymaps(origin)

  local title = ' Conductor keybindings '
  local lines = {}
  local key_width = 0
  for _, item in ipairs(items) do
    key_width = math.max(key_width, #item.lhs)
  end
  if #items == 0 then
    lines[#lines + 1] = '  no keybindings'
  else
    for _, item in ipairs(items) do
      lines[#lines + 1] = ('  %-' .. key_width .. 's  %s'):format(item.lhs, item.desc)
    end
  end
  local toggle_key = require('conductor.config').options.keymaps.help.toggle or 'g?'
  key_width = math.max(key_width, #toggle_key)
  lines[#lines + 1] = ''
  lines[#lines + 1] = ('  %-' .. key_width .. 's  %s'):format(toggle_key, 'close this help')

  local width = #title
  for _, line in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  width = width + 2
  local height = #lines

  state.bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].bufhidden = 'wipe'
  vim.bo[state.bufnr].filetype = 'conductor'

  state.winid = vim.api.nvim_open_win(state.bufnr, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = title,
    title_pos = 'center',
  })
  state.origin = origin

  -- Highlight the key column.
  for line = 0, #items - 1 do
    vim.hl.range(state.bufnr, namespace, 'Special', { line, 0 }, { line, key_width + 2 })
  end

  local options = { buffer = state.bufnr, nowait = true }
  if toggle_key then
    vim.keymap.set('n', toggle_key, M.close, options)
  end
  vim.keymap.set('n', 'q', M.close, options)
  vim.keymap.set('n', '<Esc>', M.close, options)
  vim.api.nvim_create_autocmd({ 'BufLeave', 'WinLeave' }, {
    buffer = state.bufnr,
    once = true,
    callback = M.close,
  })
end

---Toggle the cheatsheet for the current buffer. Wire this to `g?`.
function M.toggle()
  local current = vim.api.nvim_get_current_buf()
  if window_valid() and (current == state.bufnr or current == state.origin) then
    M.close()
  else
    M.open()
  end
end

---Register the help toggle on a conductor buffer.
---@param bufnr integer
function M.attach(bufnr)
  require('conductor.config').map('help', 'toggle', 'n', M.toggle, {
    buffer = bufnr,
    nowait = true,
    desc = 'Conductor: toggle keybinding help',
  })
end

return M
