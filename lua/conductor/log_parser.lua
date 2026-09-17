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

---@class ConductorBranchLeaf
---@field id string tip entry id
---@field timestamp string|nil ISO timestamp of the tip
---@field active boolean whether this leaf is the current (rendered) conversation
---@field text string short excerpt of the branch's diverging user prompt
---@field fork_id string|nil id of the nearest main-branch message this tip split
---   from (nil on the active/main tip); groups tips that diverged together
---@field fork_text string|nil excerpt of that fork-point message

---@class ConductorSessionMeta
---@field id string|nil
---@field name string|nil display name from session_info entries
---@field cwd string|nil
---@field created string|nil ISO timestamp of the session header (start time)
---@field last_activity string|nil ISO timestamp of the most recent entry (last-used time)
---@field message_count integer user+assistant messages on the active branch
---@field first_user_text string|nil
---@field branch_count integer number of conversation tips (1 = linear session)
---@field leaves ConductorBranchLeaf[]|nil branch tips, newest first (present when branch_count > 1)
---@field forked boolean|nil cheap listing-time flag: session has >1 branch tip

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

---True when a parentId links into the message DAG (a real string id, not
---JSON null / missing, which pi writes on header/metadata entries).
---@param parent_id any
---@return boolean
local function is_link(parent_id)
  return type(parent_id) == 'string'
end

---Resolve the active conversation path through a session's parentId DAG.
---pi appends sibling entries at a shared parentId when a message is edited or
---retried ("rewind"), so a forked file holds several conversation tips. The
---live conversation is the branch touched most recently, i.e. the message leaf
---(no message child) with the newest timestamp; walking its parentId chain to
---the root yields the set of entries to render.
---@param decoded table[] entries in file order
---@param target_leaf string|nil render this tip instead of the newest one
---@return table<string, boolean> on_path set of entry ids on the active branch
---@return ConductorBranchLeaf[] leaves branch tips, newest first
local function resolve_active_path(decoded, target_leaf)
  local by_id = {}
  for _, entry in ipairs(decoded) do
    if entry.id then
      by_id[entry.id] = entry
    end
  end

  -- Nearest message ancestor of a message, skipping metadata entries
  -- (session_info/model_change/…) that pi threads into the parentId chain —
  -- otherwise a rename between two messages would look like a fork.
  local is_msg_parent = {}
  for _, entry in ipairs(decoded) do
    if entry.type == 'message' then
      local cursor = is_link(entry.parentId) and by_id[entry.parentId] or nil
      while cursor do
        if cursor.type == 'message' then
          is_msg_parent[cursor.id] = true
          break
        end
        cursor = is_link(cursor.parentId) and by_id[cursor.parentId] or nil
      end
    end
  end

  -- Closest user-prompt excerpt above a tip — a best-effort branch label.
  local function branch_label(leaf)
    local cursor = leaf
    while cursor do
      if cursor.type == 'message' and type(cursor.message) == 'table' and cursor.message.role == 'user' then
        local text = content_to_text(cursor.message.content)
        if text ~= '' then
          return (text:gsub('\n.*', ''))
        end
      end
      cursor = is_link(cursor.parentId) and by_id[cursor.parentId] or nil
    end
    return ''
  end

  -- First line of the nearest message with text at/above `entry` (for labelling
  -- a fork point; the fork message itself may be a text-less tool turn).
  local function fork_excerpt(entry)
    local cursor = entry
    while cursor do
      if cursor.type == 'message' and type(cursor.message) == 'table' then
        local text = content_to_text(cursor.message.content)
        if text ~= '' then
          return (text:gsub('\n.*', ''))
        end
      end
      cursor = is_link(cursor.parentId) and by_id[cursor.parentId] or nil
    end
    return ''
  end

  ---@type ConductorBranchLeaf[]
  local leaves = {}
  for _, entry in ipairs(decoded) do
    if entry.type == 'message' and entry.id and not is_msg_parent[entry.id] then
      leaves[#leaves + 1] = {
        id = entry.id,
        timestamp = entry.timestamp,
        active = false,
        text = branch_label(entry),
        _entry = entry,
      }
    end
  end
  table.sort(leaves, function(a, b)
    return (a.timestamp or '') > (b.timestamp or '')
  end)

  local on_path = {}
  -- Render the requested tip when it still exists, else the newest one.
  local active = leaves[1]
  if target_leaf then
    for _, leaf in ipairs(leaves) do
      if leaf.id == target_leaf then
        active = leaf
        break
      end
    end
  end
  if active then
    active.active = true
    local cursor = active._entry
    while cursor do
      if cursor.id then
        on_path[cursor.id] = true
      end
      cursor = is_link(cursor.parentId) and by_id[cursor.parentId] or nil
    end
  end

  -- Fork point of each non-active tip relative to the active (main) branch: the
  -- nearest ancestor message that lies on the active path. `fork_text` is that
  -- message's excerpt — it tells the reader where the branch split from main,
  -- and `fork_id` groups tips that diverged at the same point.
  for _, leaf in ipairs(leaves) do
    if not leaf.active then
      local cursor = is_link(leaf._entry.parentId) and by_id[leaf._entry.parentId] or nil
      while cursor do
        if cursor.type == 'message' and on_path[cursor.id] then
          leaf.fork_id = cursor.id
          leaf.fork_text = fork_excerpt(cursor)
          break
        end
        cursor = is_link(cursor.parentId) and by_id[cursor.parentId] or nil
      end
    end
  end

  for _, leaf in ipairs(leaves) do
    leaf._entry = nil
  end
  return on_path, leaves
end

---Parse a single session file.
---@param path string
---@param opts { target_leaf?: string }|nil render a specific branch tip (leaf
---id) instead of the newest one; the active flag in `meta.leaves` follows it.
---@return ConductorSessionMeta meta, ConductorLogEntry[] entries
function M.parse(path, opts)
  ---@type ConductorSessionMeta
  local meta = { message_count = 0, branch_count = 1 }
  ---@type ConductorLogEntry[]
  local entries = {}

  ---Tool entries awaiting their toolResult, keyed by toolCallId.
  ---@type table<string, ConductorLogEntry>
  local tool_by_id = {}

  local file = io.open(path, 'r')
  if not file then
    return meta, entries
  end

  -- Pass 1: decode every line so the parentId DAG can be resolved before we
  -- render (a session may fork into several branches; only one is live).
  local decoded = {}
  for line in file:lines() do
    if line ~= '' then
      local ok, entry = pcall(vim.json.decode, line)
      if ok and type(entry) == 'table' then
        decoded[#decoded + 1] = entry
        -- Newest entry timestamp = last-activity (see scan_meta); tracked here so
        -- the content path reports the same copy/move-proof time as the listing.
        if type(entry.timestamp) == 'string' and (not meta.last_activity or entry.timestamp > meta.last_activity) then
          meta.last_activity = entry.timestamp
        end
      end
    end
  end
  file:close()

  local on_path, leaves = resolve_active_path(decoded, opts and opts.target_leaf)
  meta.branch_count = #leaves > 0 and #leaves or 1
  if #leaves > 1 then
    meta.leaves = leaves
  end

  -- Pass 2: render only the active branch, in file (chronological) order.
  for _, entry in ipairs(decoded) do
    do
        if entry.type == 'session' then
          meta.id = entry.id
          meta.cwd = entry.cwd
          meta.created = entry.timestamp
        elseif entry.type == 'session_info' and entry.name then
          meta.name = entry.name
        elseif entry.type == 'message' and type(entry.message) == 'table' and (on_path[entry.id] or #leaves == 0) then
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

  -- Cheap fork detection: a rewind/edit appends a sibling message at a shared
  -- parentId, so two message lines carrying the same parentId means the file
  -- forks. String-matched (no full decode) to keep listing fast. Validated on
  -- 558 real sessions: 0 false positives, 1 false negative vs the DAG parser.
  local msg_parent_seen = {}

  for line in file:lines() do
    if line ~= '' then
      -- Last-activity = the newest entry timestamp. ISO-8601 UTC strings sort
      -- lexicographically the same as chronologically, so a string max suffices
      -- (cheap: matched without decoding the line). Copy/move-proof, unlike mtime.
      local ts = line:match '"timestamp":"([^"]+)"'
      if ts and (not meta.last_activity or ts > meta.last_activity) then
        meta.last_activity = ts
      end
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
        local pid = line:match '"parentId":"([^"]+)"'
        if pid then
          if msg_parent_seen[pid] then
            meta.forked = true
          else
            msg_parent_seen[pid] = true
          end
        end
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
      if entry.output and entry.output ~= '' then
        add '```'
        local output_lines = vim.split(entry.output, '\n', { plain = true })
        if max_lines > 0 and #output_lines > max_lines then
          for line_index = 1, max_lines do
            add(output_lines[line_index])
          end
          add(('… (%d more lines)'):format(#output_lines - max_lines))
        else
          for _, output_line in ipairs(output_lines) do
            add(output_line)
          end
        end
        add '```'
      end
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
