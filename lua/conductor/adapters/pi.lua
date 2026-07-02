---Pi coding agent adapter.
---Sessions live in ~/.pi/agent/sessions/--<encoded-cwd>--/<timestamp>_<uuid>.jsonl
local log_parser = require 'conductor.log_parser'

---@type ConductorAdapter
local M = { name = 'pi' }

---Metadata cache keyed by file path, invalidated by mtime.
---@type table<string, { mtime: integer, meta: ConductorSessionMeta }>
local meta_cache = {}

local function options()
  return require('conductor.config').options.adapters.pi
end

---Resolve the session storage root using pi's own precedence:
---1. explicit `adapters.pi.sessions_dir` config
---2. $PI_CODING_AGENT_DIR/sessions (pi's agent-dir redirect)
---3. ~/.pi/agent/sessions (pi default)
---@return string
local function sessions_root()
  local configured = options().sessions_dir
  if configured and configured ~= '' then
    return vim.fs.normalize(configured)
  end
  local agent_dir = vim.env.PI_CODING_AGENT_DIR
  if agent_dir and agent_dir ~= '' then
    return vim.fs.normalize(agent_dir .. '/sessions')
  end
  return vim.fs.normalize(vim.fn.expand '~/.pi/agent/sessions')
end

---Decode pi's directory encoding back to a readable path.
---Encoding: path separators (and drive colon) become '-', e.g.
---'C:/Users/me/proj' -> '--C--Users-me-proj' (best-effort; used for display only).
---@param dir_name string
---@return string
local function decode_cwd_dir(dir_name)
  local decoded = dir_name:gsub('^%-%-', ''):gsub('%-+$', ''):gsub('%-%-', ':/'):gsub('%-', '/')
  return decoded ~= '' and decoded or dir_name
end

---@param opts { cwd?: string }|nil
---@return ConductorSession[]
function M.list_sessions(opts)
  opts = opts or {}
  local root = sessions_root()
  ---@type ConductorSession[]
  local sessions = {}

  local project_dirs = vim.fn.glob(root .. '/*', true, true)
  for _, project_dir in ipairs(project_dirs) do
    if vim.fn.isdirectory(project_dir) == 1 then
      local files = vim.fn.glob(project_dir .. '/*.jsonl', true, true)
      for _, file in ipairs(files) do
        local stat = vim.uv.fs_stat(file)
        if stat then
          local cached = meta_cache[file]
          local meta
          if cached and cached.mtime == stat.mtime.sec then
            meta = cached.meta
          else
            meta = log_parser.scan_meta(file)
            meta_cache[file] = { mtime = stat.mtime.sec, meta = meta }
          end
          local cwd = meta.cwd or decode_cwd_dir(vim.fn.fnamemodify(project_dir, ':t'))
          if not opts.cwd or vim.fs.normalize(cwd):lower() == vim.fs.normalize(opts.cwd):lower() then
            local first_line = meta.first_user_text and meta.first_user_text:gsub('\n.*', '') or '(empty session)'
            sessions[#sessions + 1] = {
              id = meta.id or file,
              path = file,
              name = meta.name or first_line,
              cwd = cwd,
              mtime = stat.mtime.sec,
              message_count = meta.message_count,
              adapter = 'pi',
            }
          end
        end
      end
    end
  end

  table.sort(sessions, function(a, b)
    return a.mtime > b.mtime
  end)
  return sessions
end

M.parse_log = log_parser.parse

---@param session ConductorSession
---@return string[]
function M.resume_cmd(session)
  return { options().cmd, '--session', session.path }
end

return M
