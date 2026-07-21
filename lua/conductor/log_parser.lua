---Parses pi session JSONL files into clean conversation logs and metadata.
---Format reference: pi-coding-agent docs/session-format.md
local M = {}

---@class ConductorLogEntry
---@field role 'user'|'assistant'|'system'|'tool'
---@field text string message text, or tool name for role='tool'
---@field summary string|nil tool args one-liner (role='tool')
---@field output string|nil tool output (role='tool')
---@field is_error boolean|nil tool failed (role='tool')
---@field expanded boolean|nil tool output unfolded in a viewer
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

---Summarize tool-call arguments for display (best-effort, single line).
---@param args table|nil
---@return string
local function summarize_args(args)
  if type(args) ~= 'table' then
    return ''
  end
  local summary = args.command or args.path or args.pattern or args.url or ''
  if type(summary) ~= 'string' then
    return ''
  end
  summary = summary:gsub('\n.*', ' …')
  if #summary > 80 then
    summary = summary:sub(1, 77) .. '…'
  end
  return summary
end

---Parse a single session file.
---@param path string
---@return ConductorSessionMeta meta, ConductorLogEntry[] entries
function M.parse(path)
  ---@type ConductorSessionMeta
  local meta = { message_count = 0 }
  ---@type ConductorLogEntry[]
  local entries = {}

  ---Tool entries awaiting their toolResult, keyed by toolCallId.
  ---@type table<string, ConductorLogEntry>
  local tool_by_id = {}

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
            -- Tool calls become collapsible entries; output attaches on toolResult.
            if type(message.content) == 'table' then
              for _, block in ipairs(message.content) do
                if type(block) == 'table' and block.type == 'toolCall' then
                  local tool_entry = {
                    role = 'tool',
                    text = block.name or 'tool',
                    summary = summarize_args(block.arguments),
                    timestamp = entry.timestamp,
                  }
                  entries[#entries + 1] = tool_entry
                  if block.id then
                    tool_by_id[block.id] = tool_entry
                  end
                end
              end
            end
          elseif message.role == 'toolResult' then
            local tool_entry = message.toolCallId and tool_by_id[message.toolCallId]
            if tool_entry then
              tool_entry.output = content_to_text(message.content)
              tool_entry.is_error = message.isError == true
              tool_by_id[message.toolCallId] = nil
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

---Same as `M.parse`, but bundled into a single table so it round-trips
---through `conductor.threadwork`'s JSON envelope (which carries one result
---value, not Lua multi-returns).
---@param path string
---@return { meta: ConductorSessionMeta, entries: ConductorLogEntry[] }
function M.parse_pair(path)
  local meta, entries = M.parse(path)
  return { meta = meta, entries = entries }
end

---Cheap metadata-only scan for session listings.
---Streams the file but only JSON-decodes the header, session_info lines, and
---the first user message; messages are counted via string matching. This keeps
---listing hundreds of multi-megabyte session files fast.
---@param path string
---@return ConductorSessionMeta
function M.scan_meta(path)
  ---@type ConductorSessionMeta
  local meta = { message_count = 0 }

  local file = io.open(path, 'r')
  if not file then
    return meta
  end

  for line in file:lines() do
    if line ~= '' then
      if line:find('"type":"session"', 1, true) then
        local ok, entry = pcall(vim.json.decode, line)
        if ok and type(entry) == 'table' then
          meta.id = entry.id
          meta.cwd = entry.cwd
          meta.created = entry.timestamp
        end
      elseif line:find('"type":"session_info"', 1, true) then
        local ok, entry = pcall(vim.json.decode, line)
        if ok and type(entry) == 'table' and entry.name then
          meta.name = entry.name
        end
      elseif line:find('"type":"message"', 1, true) then
        if line:find('"role":"user"', 1, true) then
          meta.message_count = meta.message_count + 1
          if not meta.first_user_text then
            local ok, entry = pcall(vim.json.decode, line)
            if ok and type(entry) == 'table' and type(entry.message) == 'table' then
              local text = content_to_text(entry.message.content)
              if text ~= '' then
                meta.first_user_text = text
              end
            end
          end
        elseif line:find('"role":"assistant"', 1, true) then
          meta.message_count = meta.message_count + 1
        end
      end
    end
  end
  file:close()

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
    if entry.role == 'tool' then
      local label = entry.summary ~= '' and ('%s `%s`'):format(entry.text, entry.summary) or entry.text
      add(('> ▶ %s%s'):format(label, entry.is_error and ' ✗' or ''))
      add ''
      goto continue
    end
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
    ::continue::
  end

  return lines
end

return M
