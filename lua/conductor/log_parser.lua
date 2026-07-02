---Parses pi session JSONL files into clean conversation logs and metadata.
---Format reference: pi-coding-agent docs/session-format.md
local M = {}

---@class ConductorLogEntry
---@field role 'user'|'assistant'|'system'
---@field text string
---@field timestamp string|nil ISO timestamp

---@class ConductorSessionMeta
---@field id string|nil
---@field name string|nil display name from session_info entries
---@field cwd string|nil
---@field created string|nil ISO timestamp
---@field message_count integer user+assistant messages
---@field first_user_text string|nil

---Extract plain text from a message content field (string or content-block array).
---Skips thinking blocks, tool calls, and image data.
---@param content string|table|nil
---@return string
local function content_to_text(content)
  if type(content) == 'string' then
    return content
  end
  if type(content) ~= 'table' then
    return ''
  end
  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == 'table' then
      if block.type == 'text' and type(block.text) == 'string' then
        parts[#parts + 1] = block.text
      elseif block.type == 'image' then
        parts[#parts + 1] = '[image]'
      end
      -- thinking / toolCall blocks intentionally skipped
    end
  end
  return table.concat(parts, '\n')
end

---Parse a single session file.
---@param path string
---@return ConductorSessionMeta meta, ConductorLogEntry[] entries
function M.parse(path)
  ---@type ConductorSessionMeta
  local meta = { message_count = 0 }
  ---@type ConductorLogEntry[]
  local entries = {}

  local file = io.open(path, 'r')
  if not file then
    return meta, entries
  end

  for line in file:lines() do
    if line ~= '' then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == 'table' then
        if entry.type == 'session' then
          meta.id = entry.id
          meta.cwd = entry.cwd
          meta.created = entry.timestamp
        elseif entry.type == 'session_info' and entry.name then
          meta.name = entry.name
        elseif entry.type == 'message' and type(entry.message) == 'table' then
          local message = entry.message
          if message.role == 'user' then
            local text = content_to_text(message.content)
            if text ~= '' then
              meta.message_count = meta.message_count + 1
              meta.first_user_text = meta.first_user_text or text
              entries[#entries + 1] = { role = 'user', text = text, timestamp = entry.timestamp }
            end
          elseif message.role == 'assistant' then
            local text = content_to_text(message.content)
            if message.stopReason == 'error' and message.errorMessage then
              text = text ~= '' and (text .. '\n[error] ' .. message.errorMessage) or ('[error] ' .. message.errorMessage)
            end
            if text ~= '' then
              meta.message_count = meta.message_count + 1
              entries[#entries + 1] = { role = 'assistant', text = text, timestamp = entry.timestamp }
            end
          end
        elseif entry.type == 'compaction' and entry.summary then
          entries[#entries + 1] = { role = 'system', text = '[compaction]\n' .. entry.summary, timestamp = entry.timestamp }
        end
      end
    end
  end
  file:close()

  return meta, entries
end

---Cheap metadata-only scan (stops early once name + first message are known).
---@param path string
---@return ConductorSessionMeta
function M.scan_meta(path)
  local meta, _ = M.parse(path)
  return meta
end

---Render parsed entries as display lines for a preview buffer.
---@param meta ConductorSessionMeta
---@param entries ConductorLogEntry[]
---@param opts { max_entries?: integer, max_lines_per_entry?: integer }|nil
---@return string[] lines
function M.render_preview(meta, entries, opts)
  opts = opts or {}
  local max_entries = opts.max_entries or 200
  local max_lines = opts.max_lines_per_entry or 20

  local lines = {}
  local function add(text)
    for _, split_line in ipairs(vim.split(text, '\n', { plain = true })) do
      lines[#lines + 1] = split_line
    end
  end

  add(('# %s'):format(meta.name or meta.first_user_text and meta.first_user_text:gsub('\n.*', '') or 'unnamed session'))
  if meta.cwd then
    add(('cwd: %s'):format(meta.cwd))
  end
  add(('messages: %d'):format(meta.message_count))
  add ''

  local start_index = 1
  if #entries > max_entries then
    start_index = #entries - max_entries + 1
    add(('… %d earlier entries omitted …'):format(start_index - 1))
    add ''
  end

  for index = start_index, #entries do
    local entry = entries[index]
    local label = entry.role == 'user' and '## You' or entry.role == 'assistant' and '## Agent' or '## System'
    add(label)
    local body_lines = vim.split(entry.text, '\n', { plain = true })
    if max_lines > 0 and #body_lines > max_lines then
      for line_index = 1, max_lines do
        add(body_lines[line_index])
      end
      add(('… (%d more lines)'):format(#body_lines - max_lines))
    else
      for _, body_line in ipairs(body_lines) do
        add(body_line)
      end
    end
    add ''
  end

  return lines
end

return M
