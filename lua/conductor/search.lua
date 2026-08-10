---Cross-session grep: index every session log's *parsed* conversation text
---once (off the main thread), then live-filter it as you type in the picker.
---Selecting a match opens the session in the browser and jumps to the line.
---
---The index build (`M.scan_all`) runs inside `conductor.threadwork`'s libuv
---threadpool worker — a bare Lua state with only `vim.uv`/`vim.json`/`vim.fs`
---and stdlib. Keep the module top-level and `M.scan_all` free of `vim.fn`/
---`vim.api` and closures over editor state; all editor-facing code lives in
---functions only ever called on the main thread.
local M = {}

--- Worker side (threadwork) ---------------------------------------------------

---Plain-Lua line split (worker context has no guaranteed `vim.split`).
---@param text string
---@return string[]
local function split_lines(text)
  local out = {}
  for line in (text .. '\n'):gmatch '([^\n]*)\n' do
    out[#out + 1] = line
  end
  return out
end

---@param text string
---@return string
local function trim(text)
  return (text:gsub('^%s+', ''):gsub('%s+$', ''))
end

---Flatten every session's parsed conversation into a searchable corpus: one
---record per non-blank line of meaningful text (user/assistant/system bodies,
---plus tool name/summary/output). Runs on the threadpool via
---`conductor.threadwork`; the result is filtered live on the main thread.
---@param args { paths: string[] }
---@return { path: string, name: string, role: string, line: string }[]
function M.scan_all(args)
  local log_parser = require 'conductor.log_parser'
  local paths = (args and args.paths) or {}
  local corpus = {}
  local total_cap = 100000
  local per_file_cap = 3000

  for _, path in ipairs(paths) do
    if #corpus >= total_cap then
      break
    end
    local meta, entries = log_parser.parse(path)
    local name = meta.name
      or (meta.first_user_text and meta.first_user_text:gsub('\n.*', ''))
      or path:match '[^/\\]+$'
      or path
    local file_count = 0

    for _, entry in ipairs(entries) do
      -- Tool entries carry their meaningful text across name/summary/output.
      local pieces = entry.role == 'tool' and { entry.text, entry.summary, entry.output } or { entry.text }
      for _, piece in ipairs(pieces) do
        if type(piece) == 'string' and piece ~= '' then
          for _, line in ipairs(split_lines(piece)) do
            local text = trim(line)
            if text ~= '' then
              corpus[#corpus + 1] = { path = path, name = name, role = entry.role, line = text }
              file_count = file_count + 1
              if file_count >= per_file_cap or #corpus >= total_cap then
                break
              end
            end
          end
        end
        if file_count >= per_file_cap or #corpus >= total_cap then
          break
        end
      end
      if file_count >= per_file_cap or #corpus >= total_cap then
        break
      end
    end
  end

  return corpus
end

--- Main-thread presentation ---------------------------------------------------

---@class ConductorSearchRecord
---@field path string
---@field name string
---@field role string
---@field line string
---@field lower string cached lowercase of `line` (main-thread only)

---Substring-filter the corpus (case-insensitive), capped at `limit` hits.
---@param corpus ConductorSearchRecord[]
---@param query string
---@param limit integer
---@return ConductorSearchRecord[]
local function filter_corpus(corpus, query, limit)
  local needle = query:lower()
  local out = {}
  for _, record in ipairs(corpus) do
    if record.lower:find(needle, 1, true) then
      out[#out + 1] = record
      if #out >= limit then
        break
      end
    end
  end
  return out
end

---@param record ConductorSearchRecord
---@param by_path table<string, ConductorSession>
local function open_match(record, by_path)
  local session = by_path[record.path]
  if session then
    -- Jump to the matched *line* itself, so the browser lands on the exact
    -- message rather than the first occurrence of the raw query term.
    require('conductor.browser').reveal(session, record.line)
  end
end

---@param record ConductorSearchRecord
---@param by_path table<string, ConductorSession>
---@return string
local function display_name(record, by_path)
  local session = by_path[record.path]
  local name = (session and session.name) or record.name or ''
  return (name:gsub('\n', ' '))
end

---Live telescope picker. Opens immediately; `on_ready()` (returned) re-runs the
---dynamic finder once the corpus has been indexed.
---@param corpus ConductorSearchRecord[] filled in place by the caller
---@param by_path table<string, ConductorSession>
---@param adapter ConductorAdapter
---@return fun() on_ready
local function present_telescope(corpus, by_path, adapter)
  local pickers = require 'telescope.pickers'
  local finders = require 'telescope.finders'
  local sorters = require 'telescope.sorters'
  local actions = require 'telescope.actions'
  local action_state = require 'telescope.actions.state'
  local entry_display = require 'telescope.pickers.entry_display'
  local previewers = require 'telescope.previewers'
  local picker_core = require 'conductor.picker'

  local displayer = entry_display.create {
    separator = ' │ ',
    items = { { width = 30 }, { width = 9 }, { remaining = true } },
  }

  local finder = finders.new_dynamic {
    fn = function(prompt)
      if not prompt or prompt == '' then
        return {}
      end
      return filter_corpus(corpus, prompt, 500)
    end,
    entry_maker = function(record)
      local name = display_name(record, by_path)
      return {
        value = record,
        ordinal = record.line,
        path = record.path,
        display = function()
          return displayer {
            { name, 'TelescopeResultsIdentifier' },
            { record.role, 'TelescopeResultsComment' },
            { record.line, 'TelescopeResultsNormal' },
          }
        end,
      }
    end,
  }

  -- Substring matching already happened in `fn`; keep telescope from
  -- re-ranking/fuzzy-filtering (fall back to generic sorter if unavailable).
  local ok_sorter, sorter = pcall(function()
    return sorters.highlighter_only {}
  end)
  if not ok_sorter then
    sorter = require('telescope.config').values.generic_sorter {}
  end

  local ns = vim.api.nvim_create_namespace 'conductor_search_preview'

  local previewer = previewers.new_buffer_previewer {
    title = 'Conversation Log',
    get_buffer_by_name = function(_, entry)
      return entry.value.path
    end,
    define_preview = function(self, entry)
      local session = by_path[entry.value.path]
      if not session then
        return
      end
      local bufnr = self.state.bufnr
      local winid = self.state.winid
      local needle = entry.value.line
      picker_core.preview_lines_async(session, adapter, function(lines)
        if not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        picker_core.highlight_markdown_preview(bufnr)

        -- Scroll the preview to the matched line so its surrounding context is
        -- visible, and highlight it. Match on substring so trimmed/rendered
        -- variants of the corpus line still line up with the preview buffer.
        if needle and needle ~= '' then
          local target
          for lnum, line in ipairs(lines) do
            if line:find(needle, 1, true) then
              target = lnum
              break
            end
          end
          if target then
            pcall(vim.api.nvim_buf_add_highlight, bufnr, ns, 'TelescopePreviewMatch', target - 1, 0, -1)
            if winid and vim.api.nvim_win_is_valid(winid) then
              pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
              vim.api.nvim_win_call(winid, function()
                vim.cmd 'normal! zz'
              end)
            end
          end
        end
      end)
    end,
  }

  local picker = pickers.new({}, {
    prompt_title = 'Grep sessions (type to search)',
    finder = finder,
    sorter = sorter,
    previewer = previewer,
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local entry = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if entry then
          open_match(entry.value, by_path)
        end
      end)
      return true
    end,
  })
  picker:find()

  return function()
    pcall(function()
      picker:refresh(finder, { reset_prompt = false })
    end)
  end
end

---Live fzf-lua picker over the full indexed corpus (fzf does the filtering).
---Opened by `on_ready()` once the corpus is available.
---@param corpus ConductorSearchRecord[]
---@param by_path table<string, ConductorSession>
---@return fun() on_ready
local function present_fzf(corpus, by_path)
  return function()
    local fzf = require 'fzf-lua'
    ---@type table<string, ConductorSearchRecord>
    local by_line = {}
    local lines = {}
    for _, record in ipairs(corpus) do
      local name = display_name(record, by_path)
      local line = ('%-30s │ %-9s │ %s'):format(name:sub(1, 30), record.role, record.line)
      while by_line[line] do
        line = line .. ' '
      end
      by_line[line] = record
      lines[#lines + 1] = line
    end

    fzf.fzf_exec(lines, {
      prompt = 'Grep> ',
      actions = {
        ['default'] = function(selected)
          local record = selected and selected[1] and by_line[selected[1]]
          if record then
            open_match(record, by_path)
          end
        end,
      },
    })
  end
end

---Fallback when no picker backend is available: prompt once, then select.
---@param corpus ConductorSearchRecord[]
---@param by_path table<string, ConductorSession>
---@return fun() on_ready
local function present_select(corpus, by_path)
  return function()
    vim.ui.input({ prompt = 'Grep sessions: ' }, function(query)
      query = vim.trim(query or '')
      if query == '' then
        return
      end
      local matches = filter_corpus(corpus, query, 200)
      if #matches == 0 then
        vim.notify(('conductor: no matches for %q'):format(query), vim.log.levels.INFO)
        return
      end
      vim.ui.select(matches, {
        prompt = ('Grep sessions: %s'):format(query),
        format_item = function(record)
          return ('%s │ %s │ %s'):format(display_name(record, by_path), record.role, record.line)
        end,
      }, function(record)
        if record then
          open_match(record, by_path)
        end
      end)
    end)
  end
end

---Pick and open the presentation backend; returns its `on_ready` callback.
---@param corpus ConductorSearchRecord[]
---@param by_path table<string, ConductorSession>
---@param adapter ConductorAdapter
---@return fun() on_ready
local function present(corpus, by_path, adapter)
  local backend = require('conductor.config').options.picker.backend
  if backend == 'fzf-lua' and pcall(require, 'fzf-lua') then
    return present_fzf(corpus, by_path)
  end
  if pcall(require, 'telescope') then
    return present_telescope(corpus, by_path, adapter)
  end
  if pcall(require, 'fzf-lua') then
    return present_fzf(corpus, by_path)
  end
  return present_select(corpus, by_path)
end

---Open the live cross-session grep. Lists sessions, opens the picker, and
---indexes every session's parsed text off the main thread; the picker then
---filters that index live as you type.
---@param opts { adapter?: string }|nil
function M.open(opts)
  opts = opts or {}
  ---@type ConductorSearchRecord[] filled in place once indexing completes
  local corpus = {}
  ---@type table<string, ConductorSession>
  local by_path = {}

  require('conductor.picker').list_async({ adapter = opts.adapter }, function(sessions, adapter)
    local paths = {}
    for _, session in ipairs(sessions) do
      by_path[session.path] = session
      paths[#paths + 1] = session.path
    end
    if #paths == 0 then
      vim.notify('conductor: no sessions to search', vim.log.levels.INFO)
      return
    end

    -- Open the picker straight away (telescope shows an empty prompt); the
    -- index lands a moment later and the finder re-runs via `on_ready`.
    local on_ready = present(corpus, by_path, adapter)

    require('conductor.threadwork').call('conductor.search', 'scan_all', { paths = paths }, function(ok, result)
      if not ok then
        vim.notify('conductor: search index failed: ' .. tostring(result), vim.log.levels.ERROR)
        return
      end
      for _, record in ipairs(result) do
        record.lower = record.line:lower()
        corpus[#corpus + 1] = record
      end
      on_ready()
    end)
  end)
end

return M
