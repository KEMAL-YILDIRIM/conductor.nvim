---Prompt-window status line: the session's model, thinking level, context
---usage and status, shown at the bottom of the chat input window.
---
---Two consumers share the same text:
---  * `M.expression()` — a plain window-local `statusline` set by the chat
---    shell (used when no statusline plugin is managing windows);
---  * `lua/lualine/extensions/conductor_input.lua` — a lualine extension for
---    the `conductor_input` filetype (lualine rewrites every window's
---    statusline, so a plain one would be overwritten).
---
---Both read the instance from the buffer's `b:conductor_instance_id`, so the
---line follows whichever session is swapped into the shared input window.
local M = {}

---Human-readable status labels (shared with the sidebar).
M.status_labels = {
  starting = 'starting',
  idle = 'idle',
  streaming = 'running',
  needs_input = 'waiting',
  error = 'error',
  exited = 'exited',
  readonly = 'read-only',
}

---Compact token count: 60000 → '60k', 1048576 → '1.0M'.
---@param count number
---@return string
local function short_count(count)
  if count >= 1000000 then
    return ('%.1fM'):format(count / 1000000)
  elseif count >= 1000 then
    return ('%dk'):format(math.floor(count / 1000 + 0.5))
  end
  return tostring(math.floor(count))
end

---Render an info field: `nil` = still loading, `false` = absent.
---@param value any
---@param absent string
---@return string
local function info_text(value, absent)
  if value == nil then
    return '…'
  elseif value == false then
    return absent
  end
  return value
end

---@param context { tokens: number|nil, window: number|nil, percent: number|nil }|false|nil
---@return string
local function context_text(context)
  if context == nil then
    return '…'
  elseif context == false or not context.window then
    return '—'
  elseif not context.tokens then
    -- Unknown right after a compaction until the next turn.
    return ('? / %s'):format(short_count(context.window))
  end
  local percent = context.percent or (context.tokens / context.window * 100)
  return ('%d%% · %s / %s'):format(math.floor(percent + 0.5), short_count(context.tokens), short_count(context.window))
end

---Escape `%` so text is shown literally inside a statusline format string.
---@param text string
---@return string
local function escape(text)
  return (text:gsub('%%', '%%%%'))
end

---@param instance ConductorInstance
---@return string
function M.status_label(instance)
  if instance.status == 'exited' and instance.exit_code then
    return ('exited (%d)'):format(instance.exit_code)
  end
  return M.status_labels[instance.status] or instance.status
end

---Managed instance shown in `bufnr` (defaults to the current buffer).
---@param bufnr integer|nil
---@return ConductorInstance|nil
function M.instance_for(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local id = vim.b[bufnr].conductor_instance_id
  if not id then
    return nil
  end
  return require('conductor.supervisor').instances[id]
end

---Detail fields of the session in `bufnr`.
---@param bufnr integer|nil
---@return { label: string, value: string }[]
function M.details(bufnr)
  local instance = M.instance_for(bufnr)
  if not instance then
    return {}
  end
  local info = instance.info or {}
  return {
    { label = 'model', value = info_text(info.model, 'none') },
    { label = 'thinking', value = info_text(info.thinking, '—') },
    { label = 'context', value = context_text(info.context) },
  }
end

---Plain-text details, e.g. 'model claude-opus · thinking high · context 30% · 60k / 200k'.
---Not statusline-escaped.
---@param bufnr integer|nil
---@return string
function M.details_text(bufnr)
  local parts = {}
  for _, detail in ipairs(M.details(bufnr)) do
    parts[#parts + 1] = detail.label .. ' ' .. detail.value
  end
  return table.concat(parts, ' · ')
end

---Status label of the buffer's instance ('' when none). Not escaped.
---@param bufnr integer|nil
---@return string
function M.status(bufnr)
  local instance = M.instance_for(bufnr)
  return instance and M.status_label(instance) or ''
end

---Statusline format for the input window, evaluated per redraw via
---`%{%v:lua...%}` in the context of the window being drawn.
---@return string
function M.render()
  local bufnr = vim.api.nvim_get_current_buf()
  local instance = M.instance_for(bufnr)
  if not instance then
    return ' %f'
  end
  local parts = {}
  for _, detail in ipairs(M.details(bufnr)) do
    parts[#parts + 1] = ('%%#Comment#%s%%* %s'):format(detail.label, escape(detail.value))
  end
  return (' %s%%=%s '):format(table.concat(parts, ' %#Comment#·%* '), escape(M.status_label(instance)))
end

---Window-local `statusline` value for the chat input window.
---@return string
function M.expression()
  return "%{%v:lua.require'conductor.statusline'.render()%}"
end

---Redraw status lines (and nudge lualine, which caches them) so a changed
---model / context / status shows immediately instead of on lualine's timer.
function M.refresh()
  if package.loaded.lualine then
    pcall(require('lualine').refresh, { place = { 'statusline' } })
  end
  vim.cmd.redrawstatus { bang = true }
end

return M
