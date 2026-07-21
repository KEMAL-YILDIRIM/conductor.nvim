---File-level session operations for the pi adapter: copy/move/delete/create/
---rename session .jsonl files. Backs the editable session browser (oil-style
---`:w` apply). Mirrors pi's own directory encoding:
---  sessions/--<resolved cwd, [/\:] replaced by '-'>--/<timestamp>_<uuid>.jsonl
local M = {}

math.randomseed(tonumber(tostring(vim.uv.hrtime()):sub(-9)))

---@param count integer
---@return string
local function random_hex(count)
  local out = {}
  for index = 1, count do
    out[index] = ('%x'):format(math.random(0, 15))
  end
  return table.concat(out)
end

local function now_parts()
  local sec, usec = vim.uv.gettimeofday()
  return sec, math.floor(usec / 1000)
end

---UUIDv7-style id (millisecond timestamp + random), matching pi's session ids.
---@return string
local function uuid_v7()
  local sec, ms = now_parts()
  local time_hex = ('%012x'):format(sec * 1000 + ms)
  return ('%s-%s-7%s-%x%s-%s'):format(
    time_hex:sub(1, 8),
    time_hex:sub(9, 12),
    random_hex(3),
    math.random(8, 11),
    random_hex(3),
    random_hex(12)
  )
end

---@return string ISO timestamp with milliseconds (2026-04-28T07:59:58.199Z)
local function iso_now()
  local sec, ms = now_parts()
  return os.date('!%Y-%m-%dT%H:%M:%S', sec) .. ('.%03dZ'):format(ms)
end

---@return string filename-safe timestamp (2026-04-28T07-59-58-199Z)
local function file_timestamp()
  local sec, ms = now_parts()
  return os.date('!%Y-%m-%dT%H-%M-%S', sec) .. ('-%03dZ'):format(ms)
end

---OS-native absolute path as pi's `path.resolve` would produce it.
---@param cwd string
---@return string
local function native_path(cwd)
  local resolved = vim.fs.normalize(vim.fn.fnamemodify(vim.fs.normalize(cwd), ':p'))
  if vim.fn.has 'win32' == 1 then
    resolved = resolved:gsub('/', '\\')
    if not resolved:match '^%a:\\$' then
      resolved = resolved:gsub('[\\]+$', '')
    end
  elseif resolved ~= '/' then
    resolved = resolved:gsub('/+$', '')
  end
  return resolved
end

---Encode a project cwd into pi's session directory name.
---@param cwd string
---@return string
local function encode_cwd_dir(cwd)
  local safe = native_path(cwd):gsub('^[/\\]', ''):gsub('[/\\:]', '-')
  return '--' .. safe .. '--'
end

---@param path string
---@return string|nil content, string|nil error
local function read_file(path)
  local file, open_err = io.open(path, 'rb')
  if not file then
    return nil, open_err
  end
  local content = file:read '*a'
  file:close()
  return content
end

---Preserve a file's access/modification time across an edit so that renames
---and moves keep their place in the recency-sorted session list.
---@param path string
---@param mtime integer unix seconds
local function restore_mtime(path, mtime)
  if mtime then
    pcall(vim.uv.fs_utime, path, mtime, mtime)
  end
end

---@param path string
---@param content string
---@return boolean ok, string|nil error
local function write_file(path, content)
  local file, open_err = io.open(path, 'wb')
  if not file then
    return false, open_err
  end
  file:write(content)
  file:close()
  return true
end

---Split a session file into its decoded header entry and the raw remainder.
---@param content string
---@return table|nil header, string rest, string|nil error
local function split_header(content)
  local newline = content:find('\n', 1, true)
  local first = newline and content:sub(1, newline - 1) or content
  local rest = newline and content:sub(newline) or '\n'
  local ok, header = pcall(vim.json.decode, first)
  if not ok or type(header) ~= 'table' or header.type ~= 'session' then
    return nil, rest, 'not a pi session file: ' .. first:sub(1, 60)
  end
  return header, rest
end

---@param root string sessions root directory
---@param cwd string target project directory
---@return string dir absolute session directory (created if missing)
local function ensure_project_dir(root, cwd)
  local dir = root .. '/' .. encode_cwd_dir(cwd)
  vim.fn.mkdir(dir, 'p')
  return dir
end

---Id of the last non-header entry in a session file (rename parentId).
---@param content string
---@return string|any parent entry id, or vim.NIL
local function last_entry_id(content)
  local parent = vim.NIL
  for line in content:gmatch '[^\n]+' do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' and entry.type ~= 'session' and entry.id then
      parent = entry.id
    end
  end
  return parent
end

---@param content string existing file content (for parentId chaining)
---@param name string
---@return string JSON line (no trailing newline)
local function session_info_line(content, name)
  return vim.json.encode {
    type = 'session_info',
    id = random_hex(8),
    parentId = last_entry_id(content),
    timestamp = iso_now(),
    name = name,
  }
end

---Copy a session into another project. The copy gets a fresh session id and
---its header cwd rewritten so pi lists and resumes it under the target project.
---@param root string
---@param session ConductorSession
---@param target_cwd string
---@param name string|nil rename the copy (appends a session_info entry)
---@return boolean ok, string|nil error
function M.copy(root, session, target_cwd, name)
  local content, read_err = read_file(session.path)
  if not content then
    return false, read_err
  end
  local header, rest, parse_err = split_header(content)
  if not header then
    return false, parse_err
  end
  header.id = uuid_v7()
  header.cwd = native_path(target_cwd)
  local out = vim.json.encode(header) .. rest
  if name and name ~= '' and name ~= session.name then
    if out:sub(-1) ~= '\n' then
      out = out .. '\n'
    end
    out = out .. session_info_line(out, name) .. '\n'
  end
  local dir = ensure_project_dir(root, target_cwd)
  local path = ('%s/%s_%s.jsonl'):format(dir, file_timestamp(), header.id)
  return write_file(path, out)
end

---Move a session to another project (same id and filename, rewritten cwd).
---@param root string
---@param session ConductorSession
---@param target_cwd string
---@return boolean ok, string|nil error
function M.move(root, session, target_cwd)
  local content, read_err = read_file(session.path)
  if not content then
    return false, read_err
  end
  local header, rest, parse_err = split_header(content)
  if not header then
    return false, parse_err
  end
  header.cwd = native_path(target_cwd)
  local dir = ensure_project_dir(root, target_cwd)
  local path = dir .. '/' .. vim.fn.fnamemodify(session.path, ':t')
  if vim.fs.normalize(path):lower() == vim.fs.normalize(session.path):lower() then
    return true
  end
  -- Preserve modification time so a move keeps its place in the recency sort.
  local stat = vim.uv.fs_stat(session.path)
  local ok, write_err = write_file(path, vim.json.encode(header) .. rest)
  if not ok then
    return false, write_err
  end
  if stat then
    restore_mtime(path, stat.mtime.sec)
  end
  vim.uv.fs_unlink(session.path)
  return true
end

---@param path string session file path
---@return boolean ok, string|nil error
function M.delete(path)
  local ok, unlink_err = vim.uv.fs_unlink(path)
  if not ok then
    return false, unlink_err
  end
  return true
end

---Create a fresh empty session in the given project.
---@param root string
---@param cwd string
---@param name string|nil display name (session_info entry)
---@return boolean ok, string|nil error
function M.create(root, cwd, name)
  local id = uuid_v7()
  local timestamp = iso_now()
  local lines = {
    vim.json.encode { type = 'session', version = 3, id = id, timestamp = timestamp, cwd = native_path(cwd) },
  }
  if name and name ~= '' then
    lines[#lines + 1] = vim.json.encode {
      type = 'session_info',
      id = random_hex(8),
      parentId = vim.NIL,
      timestamp = timestamp,
      name = name,
    }
  end
  local dir = ensure_project_dir(root, cwd)
  local path = ('%s/%s_%s.jsonl'):format(dir, file_timestamp(), id)
  return write_file(path, table.concat(lines, '\n') .. '\n')
end

---Rename a session by appending a session_info entry (pi's own mechanism).
---@param path string session file path
---@param name string
---@return boolean ok, string|nil error
function M.rename(path, name)
  local content, read_err = read_file(path)
  if not content then
    return false, read_err
  end
  -- Preserve modification time so a rename keeps its place in the recency sort.
  local stat = vim.uv.fs_stat(path)
  local info = session_info_line(content, name)
  local file, open_err = io.open(path, 'ab')
  if not file then
    return false, open_err
  end
  if #content > 0 and content:sub(-1) ~= '\n' then
    file:write '\n'
  end
  file:write(info .. '\n')
  file:close()
  if stat then
    restore_mtime(path, stat.mtime.sec)
  end
  return true
end

return M
