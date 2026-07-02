---Per-instance chat buffer: renders the accumulated conversation log with
---live streaming updates. Opened in a split; prompt input via `i` keymap.
local M = {}

---@param instance ConductorInstance
---@return string[]
local function render_lines(instance)
  local lines = {}
  local function add(text)
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end

  add(('# %s  [%s]'):format(instance.name, instance.status))
  add ''
  for _, entry in ipairs(instance.log) do
    if entry.role == 'user' then
      add '## You'
      add(entry.text)
    elseif entry.role == 'assistant' then
      add '## Agent'
      add(entry.text)
    else
      add('> ' .. entry.text:gsub('\n', '\n> '))
    end
    add ''
  end
  if instance.partial ~= '' then
    add '## Agent'
    add(instance.partial)
  end
  return lines
end

---@param instance ConductorInstance
---@return boolean
local function buffer_valid(instance)
  return instance.chat_bufnr ~= nil and vim.api.nvim_buf_is_valid(instance.chat_bufnr)
end

---Re-render the chat buffer if it exists; follows tail if cursor was at end.
---@param instance ConductorInstance
function M.refresh(instance)
  if not buffer_valid(instance) then
    return
  end
  local bufnr = instance.chat_bufnr
  local lines = render_lines(instance)
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  -- Auto-scroll windows that are showing this buffer.
  for _, window in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.api.nvim_win_set_cursor(window, { #lines, 0 })
  end
end

---Prompt the user for input and send it to the instance.
---@param instance ConductorInstance
function M.input_prompt(instance)
  vim.ui.input({ prompt = ('%s> '):format(instance.name) }, function(text)
    if text and text ~= '' then
      require('conductor.supervisor').prompt(instance, text)
    end
  end)
end

---Open (or focus) the chat buffer for an instance.
---@param instance ConductorInstance
function M.open(instance)
  if buffer_valid(instance) then
    local windows = vim.fn.win_findbuf(instance.chat_bufnr)
    if #windows > 0 then
      vim.api.nvim_set_current_win(windows[1])
      return
    end
    vim.cmd('vsplit | buffer ' .. instance.chat_bufnr)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  instance.chat_bufnr = bufnr
  vim.api.nvim_buf_set_name(bufnr, ('conductor://chat/%d'):format(instance.id))
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = 'markdown'
  vim.bo[bufnr].modifiable = false

  local keymap_options = { buffer = bufnr, nowait = true }
  vim.keymap.set('n', 'i', function()
    M.input_prompt(instance)
  end, vim.tbl_extend('force', keymap_options, { desc = 'Conductor: send prompt' }))
  vim.keymap.set('n', '<C-c>', function()
    require('conductor.supervisor').abort(instance)
  end, vim.tbl_extend('force', keymap_options, { desc = 'Conductor: abort agent' }))
  vim.keymap.set('n', 'q', '<cmd>close<cr>', vim.tbl_extend('force', keymap_options, { desc = 'Conductor: close chat' }))

  vim.cmd 'vsplit'
  vim.api.nvim_win_set_buf(0, bufnr)
  M.refresh(instance)
end

return M
