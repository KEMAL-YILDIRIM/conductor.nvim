---Session browser: persistent left panel listing sessions (cwd by default),
---navigation renders the conversation in the main window on the right with
---collapsible tool-call entries. Forked sessions (pi rewind/edit) show a `▸⑂`
---disclosure badge; `<Tab>` expands their branch tips as nested, selectable
---child rows *in the list*, grouped under a `⑂ split after: …` label showing
---the main-branch message each set diverged from (the newest/main tip is the
---trunk, tagged `(main)`). Moving the cursor onto a tip previews it in the
---content pane and scrolls to where it split from main (its diverging prompt);
---`<CR>` opens it (`gb` in the content pane is a switch fallback). Selection
---renders a tip via `log_parser`'s `target_leaf` + `state.branch_choice`.
---
---The list panel is editable oil.nvim-style: each session line carries a
---concealed `/id` token, project directories are unindented header lines.
---Expanded branch rows carry a concealed `~NNN` token instead (parse_line
---returns 'branch'; the `:w` diff ignores them).
---Saving the buffer (`:w`) diffs it against the last render and applies the
---changes to disk (create / copy / move / rename / delete sessions).
local M = {}

local state = {
  list_buf = nil, ---@type integer|nil
  list_win = nil, ---@type integer|nil
  content_buf = nil, ---@type integer|nil
  content_win = nil, ---@type integer|nil
  sessions = {}, ---@type ConductorSession[]
  adapter = nil, ---@type ConductorAdapter|nil
  cwd_filter = nil, ---@type string|nil nil = all projects
  ---Maps list-buffer line numbers to session indexes.
  line_to_session = {}, ---@type table<integer, integer>
  ---Snapshot of the last render: edit id -> session (oil-style `:w` diffing).
  edit_index = {}, ---@type table<string, ConductorSession>
  ---Snapshot of the last render: rendered header text -> exact original cwd.
  ---Lets an *unchanged* header map straight back to the cwd it was rendered
  ---from, instead of round-tripping through `vim.fn.expand` (which mangles
  ---`~`, spaces and shell metacharacters and spuriously flags every session
  ---in the group as "moved").
  header_index = {}, ---@type table<string, string>
  ---Maps content-buffer line numbers to entry indexes (tool entries only).
  tool_lines = {}, ---@type table<integer, integer>
  ---Parsed entries cache keyed by path (expanded flags persist while browsing).
  entry_cache = {}, ---@type table<string, { mtime: integer, meta: ConductorSessionMeta, entries: ConductorLogEntry[], leaf: string|nil }>
  ---Chosen branch tip per session path; nil = newest (default). Lets a forked
  ---session render an abandoned/alternative branch instead of the live one.
  branch_choice = {}, ---@type table<string, string>
  ---Forked-session paths whose branch tips are expanded (listed) in the left
  ---panel, so tips can be browsed/selected without opening the content pane.
  branch_expanded = {}, ---@type table<string, boolean>
  ---Cached branch tips per path (mtime-checked), populated on first expand.
  branch_leaves = {}, ---@type table<string, { mtime: integer, leaves: ConductorBranchLeaf[] }>
  ---List-row token (`~NNN`) -> the branch it selects. Rebuilt every render.
  branch_index = {}, ---@type table<string, { path: string, leaf: string, newest: boolean }>
  current_path = nil, ---@type string|nil
  preview_generation = 0,
  ---Bumped on every refresh_sessions() call; guards against a stale async
  ---list_sessions_async response landing after a newer refresh started.
  list_generation = 0,
  loading_sessions = false,
  ---Bumped on every show_session() call; guards against a stale async
  ---parse_log_async response landing after the user picked another session.
  content_generation = 0,
}

local namespace = vim.api.nvim_create_namespace 'conductor_browser'
---Separate namespace for the selected-row wash so it can be redrawn on every
---cursor move without touching the (expensive) list render's extmarks.
local cursor_namespace = vim.api.nvim_create_namespace 'conductor_browser_cursor'

---Paint the current list row with the selected-row wash. Driven by an extmark
---(not the built-in 'cursorline') because `line_hl_group` stripes otherwise win
---the priority tie and hide CursorLine on striped rows. Higher priority than
---the stripes guarantees the selected row is always visible.
local function highlight_cursor_line()
  if state.list_buf == nil or not vim.api.nvim_buf_is_valid(state.list_buf) then
    return
  end
  vim.api.nvim_buf_clear_namespace(state.list_buf, cursor_namespace, 0, -1)
  if state.list_win == nil or not vim.api.nvim_win_is_valid(state.list_win) then
    return
  end
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  vim.api.nvim_buf_set_extmark(state.list_buf, cursor_namespace, row - 1, 0, {
    line_hl_group = 'ConductorBrowserCursorLine',
    priority = 200,
  })
end

---Define the zebra-stripe highlight as a subtle tint of `Normal` (lighter on
---dark themes, darker on light themes) so alternating session rows are easy to
---scan, plus `ConductorBrowserCursorLine` — a distinct, subtle cyan wash for
---the selected row so it stands out from the stripes without being vibrant.
---Both use `default = true` so user-provided groups win; re-run on ColorScheme
---so they track the active theme.
local function ensure_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = 'Normal', link = false })
  local bg = normal.bg

  ---Split a 0xRRGGBB integer into r, g, b components.
  local function split(color)
    return math.floor(color / 0x10000) % 0x100, math.floor(color / 0x100) % 0x100, color % 0x100
  end
  local function clamp(v)
    return math.max(0, math.min(255, math.floor(v + 0.5)))
  end
  ---Blend `accent` into `base` by `alpha` (0..1 = accent weight).
  local function blend(base, accent, alpha)
    local br, bg_, bb = split(base)
    local ar, ag, ab = split(accent)
    return clamp(br + (ar - br) * alpha) * 0x10000
      + clamp(bg_ + (ag - bg_) * alpha) * 0x100
      + clamp(bb + (ab - bb) * alpha)
  end

  local stripe, cursor
  if type(bg) == 'number' then
    local r, g, b = split(bg)
    local luminance = 0.299 * r + 0.587 * g + 0.114 * b
    -- Stripe: nudge Normal a touch lighter (dark themes) / darker (light).
    local delta = luminance < 128 and 14 or -14
    stripe = clamp(r + delta) * 0x10000 + clamp(g + delta) * 0x100 + clamp(b + delta)
    -- Selected row: a subtle cyan wash blended into Normal (distinct, not vibrant).
    cursor = blend(bg, 0x2fb6c9, 0.26)
  end
  vim.api.nvim_set_hl(0, 'ConductorBrowserStripe', { bg = stripe, default = true })
  vim.api.nvim_set_hl(0, 'ConductorBrowserCursorLine', { bg = cursor, default = true })
end

---Fold expression for the list panel: each project header starts a fold that
---contains its indented session lines. Blank separator lines between groups
---are left at level 0 so groups stay visually distinct when unfolded.
---Wired up via `vim.wo.foldexpr = "v:lua.require'conductor.browser'.foldexpr()"`.
---`foldexpr`/`foldtext` are window-local and *inherited by new splits*, so a
---window spawned off the browser carries these until overridden. Guard on the
---conductor filetype so a leak into another buffer never folds by our rules.
---@return string
function M.foldexpr()
  if vim.bo.filetype ~= 'conductor' then
    return '0' -- leaked into a non-conductor window: defer to its own folding
  end
  local lnum = vim.v.lnum
  local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ''
  if line:match '^%s*$' then
    return '0' -- blank separator between project groups
  end
  if line:match '^%s' then
    return '1' -- indented session line: inside the current group's fold
  end
  return '>1' -- unindented project header: opens a new fold
end

---Foldtext for a collapsed project group: the header path plus a session count.
---@return string
function M.foldtext()
  if vim.bo.filetype ~= 'conductor' then
    return vim.fn.foldtext() -- leaked into a non-conductor window: default text
  end
  local start_line = vim.v.foldstart
  local end_line = vim.v.foldend
  local header = vim.api.nvim_buf_get_lines(0, start_line - 1, start_line, false)[1] or ''
  local count = end_line - start_line -- lines below the header are session lines
  local suffix = count == 1 and ' (1 session)' or (' (%d sessions)'):format(count)
  return header .. suffix
end

local function win_valid(window)
  return window ~= nil and vim.api.nvim_win_is_valid(window)
end

local function buf_valid(buffer)
  return buffer ~= nil and vim.api.nvim_buf_is_valid(buffer)
end

--- Session list (left panel) ------------------------------------------------

---Case-insensitive path key for grouping/diffing.
---@param path string|nil
---@return string
local function path_key(path)
  return path and vim.fs.normalize(path):lower() or ''
end

---Whether the current adapter supports file-level session editing.
---@return boolean
local function editable()
  return state.adapter ~= nil and state.adapter.fs ~= nil and state.adapter.sessions_root ~= nil
end

---Branch tips for a forked session, newest first. Parses the log on the main
---thread (a deliberate, infrequent expand action) and caches by mtime.
---@param session ConductorSession
---@return ConductorBranchLeaf[]
local function branch_leaves_for(session)
  local stat = vim.uv.fs_stat(session.path)
  local mtime = stat and stat.mtime.sec or 0
  local cached = state.branch_leaves[session.path]
  if cached and cached.mtime == mtime then
    return cached.leaves
  end
  local leaves = {}
  if state.adapter and state.adapter.parse_log then
    local meta = state.adapter.parse_log(session.path)
    leaves = (meta and meta.leaves) or {}
  end
  state.branch_leaves[session.path] = { mtime = mtime, leaves = leaves }
  return leaves
end

local function render_list()
  if not buf_valid(state.list_buf) then
    return
  end
  local picker = require 'conductor.picker'
  local lines = {}
  ---@type { line: integer, group: string }[]
  local highlights = {}
  ---@type { line: integer, start: integer, stop: integer }[] lines (0-based)
  ---whose `/id ` token gets concealed, with the concealed span's columns
  local conceal_lines = {}
  ---@type integer[] lines (0-based) that get the alternating zebra-stripe tint
  local stripe_lines = {}
  ---@type { line: integer, col: integer }[] forked-session rows (0-based) +
  ---name-start column that get the `⑂` badge in front of the name
  local branch_badge_lines = {}
  local branch_seq = 0
  state.line_to_session = {}
  state.edit_index = {}
  state.header_index = {}
  state.branch_index = {}

  if state.loading_sessions and #state.sessions == 0 then
    lines[#lines + 1] = '  loading sessions…'
    highlights[#highlights + 1] = { line = 0, group = 'Comment' }
  elseif #state.sessions == 0 then
    lines[#lines + 1] = '  no sessions found'
    highlights[#highlights + 1] = { line = 0, group = 'Comment' }
  else
    -- Group sessions by project directory, preserving list order (mtime-sorted).
    ---@type { cwd: string, indexes: integer[] }[]
    local groups = {}
    local group_by_cwd = {}
    for index, session in ipairs(state.sessions) do
      local key = path_key(session.cwd)
      local group = group_by_cwd[key]
      if not group then
        group = { cwd = session.cwd or '', indexes = {} }
        group_by_cwd[key] = group
        groups[#groups + 1] = group
      end
      group.indexes[#group.indexes + 1] = index
    end

    -- The 2 leading spaces are structural: the `^%s` header/session test in
    -- parse_line/foldexpr needs them. They're fully concealed (together with
    -- the `/id ` token) so the name sits at column 0 and the zebra stripe /
    -- selected-row wash fill the row edge-to-edge without a left gap.
    local indent = '  '
    local stripe_toggle = false
    for group_index, group in ipairs(groups) do
      if group_index > 1 then
        lines[#lines + 1] = ''
      end
      local header = group.cwd ~= '' and picker.shorten_cwd(group.cwd) or '(unknown project)'
      if group.cwd ~= '' then
        state.header_index[header] = group.cwd
      end
      lines[#lines + 1] = header
      highlights[#highlights + 1] = { line = #lines - 1, group = 'Directory' }
      for _, index in ipairs(group.indexes) do
        local session = state.sessions[index]
        local edit_id = ('%03d'):format(index)
        state.edit_index[edit_id] = session
        lines[#lines + 1] = ('%s/%s %s'):format(indent, edit_id, session.name:gsub('\n', ' '))
        state.line_to_session[#lines] = index
        -- Conceal the whole `  /id ` prefix so the name renders at column 0.
        conceal_lines[#conceal_lines + 1] = { line = #lines - 1, start = 0, stop = #indent + 2 + #edit_id }
        -- Forked sessions get a `⑂` badge in front of the name (inline virtual
        -- text at the name's start column, so the editable row text stays clean
        -- for `:w` rename diffing). The `  /id ` prefix before it is concealed.
        if session.forked then
          local expanded = state.branch_expanded[session.path]
          branch_badge_lines[#branch_badge_lines + 1] = {
            line = #lines - 1,
            col = #indent + 2 + #edit_id,
            text = (expanded and '▾' or '▸') .. '⑂ ',
          }
        end
        if stripe_toggle then
          stripe_lines[#stripe_lines + 1] = #lines - 1
        end
        stripe_toggle = not stripe_toggle
        -- Expanded forked session: list its branch tips as nested, selectable
        -- child rows (parsed on demand), grouped by the point they split from
        -- the main branch so the divergence is obvious. Every child row (and
        -- the inert group labels) carries a concealed `  ~NNN ` token so
        -- parse_line returns 'branch' and the editable `:w` diff ignores them.
        if session.forked and state.branch_expanded[session.path] then
          local active_leaf = state.branch_choice[session.path]
          local function truncate(text, max)
            text = (text ~= nil and text ~= '') and text or '(no prompt)'
            if #text > max then
              text = text:sub(1, max - 1) .. '…'
            end
            return text
          end
          ---Emit a concealed-token row (`indent` prefix hidden, `visible` shown).
          ---When `target` is given the row is a selectable branch tip.
          local function emit_row(visible, target)
            branch_seq = branch_seq + 1
            local token = ('%03d'):format(branch_seq)
            if target then
              state.branch_index[token] = target
            end
            lines[#lines + 1] = ('%s~%s %s'):format(indent, token, visible)
            conceal_lines[#conceal_lines + 1] = { line = #lines - 1, start = 0, stop = #indent + 1 + #token + 1 }
          end
          local function tip_row(leaf, is_main, deeper)
            local viewing = (active_leaf == nil and leaf.active) or active_leaf == leaf.id
            local marker = viewing and '●' or '○'
            local when = leaf.timestamp and (' · ' .. picker.relative_time_iso(leaf.timestamp)) or ''
            local tag = is_main and '  (main)' or ''
            emit_row(('%s%s %s%s%s'):format(deeper and '        ' or '    ', marker, truncate(leaf.text, 40), when, tag), {
              path = session.path,
              leaf = leaf.id,
              newest = leaf.active,
              -- Selecting a non-main tip scrolls the content pane to this tip's
              -- diverging prompt (where it split from the main branch).
              jump = (not leaf.active) and leaf.text ~= '' and leaf.text or nil,
            })
          end

          local tips = branch_leaves_for(session)
          if tips[1] then
            tip_row(tips[1], true, false) -- the main / newest tip = the trunk
          end
          -- Group the remaining tips by their fork point, preserving order.
          local order, groups = {}, {}
          for i = 2, #tips do
            local key = tips[i].fork_id or ''
            if not groups[key] then
              groups[key] = { fork_text = tips[i].fork_text, tips = {} }
              order[#order + 1] = key
            end
            local g = groups[key]
            g.tips[#g.tips + 1] = tips[i]
          end
          for _, key in ipairs(order) do
            local g = groups[key]
            emit_row(('    ⑂ split after: %s'):format(truncate(g.fork_text, 36)))
            for _, leaf in ipairs(g.tips) do
              tip_row(leaf, false, true)
            end
          end
        end
      end
    end
  end

  -- Rewriting every line discards the window's folds and Neovim rebuilds them
  -- from foldexpr; in a live UI (Neovim 0.12) the group around the cursor can
  -- come back closed despite foldlevel=99. So remember which project groups
  -- the user folded (by header text) and restore exactly those afterwards.
  local fold_win = win_valid(state.list_win) and vim.api.nvim_win_get_buf(state.list_win) == state.list_buf and state.list_win or nil
  local folded_headers = {}
  if fold_win then
    vim.api.nvim_win_call(fold_win, function()
      local line_count = vim.api.nvim_buf_line_count(state.list_buf)
      local lnum = 1
      while lnum <= line_count do
        local fold_start = vim.fn.foldclosed(lnum)
        if fold_start ~= -1 then
          folded_headers[vim.fn.getline(fold_start)] = true
          lnum = vim.fn.foldclosedend(lnum) + 1
        else
          lnum = lnum + 1
        end
      end
    end)
  end

  vim.bo[state.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
  if not editable() then
    vim.bo[state.list_buf].modifiable = false
  end

  if fold_win then
    vim.api.nvim_win_call(fold_win, function()
      vim.cmd 'normal! zX' -- recompute folds and re-apply foldlevel (all open)
      for lnum, line in ipairs(lines) do
        if folded_headers[line] and line:match '^%S' then
          vim.cmd(('silent! %dfoldclose'):format(lnum))
        end
      end
    end)
  end
  vim.bo[state.list_buf].modified = false

  vim.api.nvim_buf_clear_namespace(state.list_buf, namespace, 0, -1)
  for _, highlight in ipairs(highlights) do
    vim.hl.range(state.list_buf, namespace, highlight.group, { highlight.line, 0 }, { highlight.line, -1 })
  end
  -- Zebra stripes: tint alternating session rows across the full window width
  -- (line_hl_group fills past EOL) for easier row scanning. Priority is kept
  -- below CursorLine's built-in DECOR_PRIORITY_BASE (0x1000 = 4096) so the
  -- selected-row wash still shows on top of a striped row.
  for _, line in ipairs(stripe_lines) do
    vim.api.nvim_buf_set_extmark(state.list_buf, namespace, line, 0, {
      line_hl_group = 'ConductorBrowserStripe',
      priority = 100,
    })
  end
  -- Disclosure `▸⑂`/`▾⑂` badge in front of forked-session names (inline virt
  -- text only, so the editable row text stays clean for `:w` rename diffing).
  for _, badge in ipairs(branch_badge_lines) do
    vim.api.nvim_buf_set_extmark(state.list_buf, namespace, badge.line, badge.col, {
      virt_text = { { badge.text, 'Comment' } },
      virt_text_pos = 'inline',
      priority = 120,
    })
  end
  -- Conceal the `/007 ` id token so only the padding + session name shows.
  for _, conceal in ipairs(conceal_lines) do
    vim.api.nvim_buf_set_extmark(state.list_buf, namespace, conceal.line, conceal.start, {
      end_col = conceal.stop,
      conceal = '',
    })
  end

  if win_valid(state.list_win) then
    local scope = state.cwd_filter and 'cwd' or 'all projects'
    local status = state.loading_sessions and ' %#Comment#(loading…)' or (editable() and ' %#Comment#(:w applies)' or '')
    vim.wo[state.list_win].winbar = ('%%#Title# Sessions — %s%s'):format(scope, status)
  end

  -- Re-anchor the selected-row wash after the list is rebuilt.
  highlight_cursor_line()
end

---Reload the session list off the main thread (conductor.threadwork), so
---scanning hundreds of session files never blocks the UI. Shows a "loading…"
---placeholder immediately; the list panel updates in place once the
---threadpool result lands. Guarded by `list_generation` so a stale response
---from an earlier refresh (e.g. rapid gc/gR presses) can't clobber a newer one.
---@param on_done fun()|nil called after the list panel is (re)rendered with fresh data
local function refresh_sessions(on_done)
  state.list_generation = state.list_generation + 1
  local generation = state.list_generation
  state.loading_sessions = true
  render_list()

  local picker = require 'conductor.picker'
  picker.list_async({ cwd = state.cwd_filter }, function(sessions, adapter)
    if generation ~= state.list_generation then
      return -- superseded by a later refresh
    end
    state.sessions, state.adapter = sessions, adapter
    state.loading_sessions = false
    render_list()
    if on_done then
      on_done()
    end
  end)
end

---Parse a list-buffer line. Indented lines are sessions, unindented non-empty
---lines are project headers.
---@param line string
---@return 'session'|'header'|'blank' kind, string|nil edit_id, string text (session name or header path)
local function parse_line(line)
  if line:match '^%s*$' then
    return 'blank', nil, ''
  end
  if line:match '^%s' then
    local branch_id = line:match '^%s*~(%d+)'
    if branch_id then
      return 'branch', branch_id, '' -- expanded branch tip row (non-editable)
    end
    local edit_id, name = line:match '^%s*/(%d+)%s?(.*)$'
    if edit_id then
      return 'session', edit_id, vim.trim(name)
    end
    return 'session', nil, vim.trim(line) -- new session (no id token)
  end
  return 'header', nil, vim.trim(line)
end

---@return ConductorSession|nil
local function session_at_cursor()
  if not win_valid(state.list_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local line = vim.api.nvim_buf_get_lines(state.list_buf, row - 1, row, false)[1] or ''
  local kind, id = parse_line(line)
  if kind == 'session' and id then
    return state.edit_index[id]
  end
  -- On an expanded branch row, g-actions (resume/attach/…) target its parent.
  if kind == 'branch' then
    local target = state.branch_index[id]
    if target then
      for _, session in ipairs(state.sessions) do
        if session.path == target.path then
          return session
        end
      end
    end
  end
  return nil
end

---Resolve the (session, branch tip) the cursor points at. On a plain session
---row the tip is nil (newest / default render); on an expanded branch row it is
---that tip's leaf id (nil when the row is the newest tip). The third value is
---the tip's diverging-prompt text (nil for the main tip / session rows) so the
---caller can scroll the content pane to the split. Returns nil when the cursor
---is not on a selectable row.
---@return ConductorSession|nil session, string|nil leaf, string|nil jump
local function branch_target_at_cursor()
  if not win_valid(state.list_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
  local line = vim.api.nvim_buf_get_lines(state.list_buf, row - 1, row, false)[1] or ''
  local kind, id = parse_line(line)
  if kind == 'branch' then
    local target = state.branch_index[id]
    if target then
      for _, session in ipairs(state.sessions) do
        if session.path == target.path then
          return session, (not target.newest) and target.leaf or nil, target.jump
        end
      end
    end
    return nil
  end
  if kind == 'session' and id then
    return state.edit_index[id], nil
  end
  return nil
end

--- Oil-style apply on :w ----------------------------------------------------

---Expand a header line back into an absolute project path. An *unchanged*
---header maps straight back to the exact cwd it was rendered from (see
---`state.header_index`); only headers the user actually typed/edited fall
---through to `vim.fn.expand`. This keeps `~`, spaces and shell metacharacters
---from breaking the round-trip and spuriously flagging whole groups as moved.
---@param header string
---@return string|nil
local function header_to_cwd(header)
  if header == '' or header == '(unknown project)' then
    return nil
  end
  local exact = state.header_index[header]
  if exact then
    return vim.fs.normalize(exact)
  end
  return vim.fs.normalize(vim.fn.expand(header))
end

---Name as it appears in the rendered list buffer (newlines flattened,
---surrounding whitespace trimmed). collect_ops must compare against this,
---not the raw name, or unchanged lines look like renames.
---@param session ConductorSession
---@return string
local function display_name(session)
  return vim.trim((session.name:gsub('\n', ' ')))
end

---Diff the buffer against the last-rendered snapshot.
---@return table[] ops, string|nil error
local function collect_ops()
  local buffer_lines = vim.api.nvim_buf_get_lines(state.list_buf, 0, -1, false)
  ---@type table<string, { cwd: string|nil, name: string }[]> occurrences per edit id
  local seen = {}
  local ops = {}
  local current_cwd = nil ---@type string|nil

  for _, line in ipairs(buffer_lines) do
    local kind, edit_id, text = parse_line(line)
    if kind == 'header' then
      current_cwd = header_to_cwd(text)
    elseif kind == 'session' then
      if edit_id then
        if not state.edit_index[edit_id] then
          return {}, ('unknown session id /%s'):format(edit_id)
        end
        seen[edit_id] = seen[edit_id] or {}
        seen[edit_id][#seen[edit_id] + 1] = { cwd = current_cwd, name = text }
      else
        if not current_cwd then
          return {}, ('new session %q needs a project header above it'):format(text)
        end
        ops[#ops + 1] = { kind = 'create', cwd = current_cwd, name = text }
      end
    end
  end

  for edit_id, session in pairs(state.edit_index) do
    local occurrences = seen[edit_id]
    if not occurrences then
      ops[#ops + 1] = { kind = 'delete', session = session }
    else
      -- The occurrence still in the session's original project (if any) is the
      -- original; every other occurrence is a copy.
      local original_index = 1
      for index, occurrence in ipairs(occurrences) do
        if path_key(occurrence.cwd) == path_key(session.cwd) then
          original_index = index
          break
        end
      end
      for index, occurrence in ipairs(occurrences) do
        if index == original_index then
          if occurrence.name ~= '' and occurrence.name ~= display_name(session) then
            ops[#ops + 1] = { kind = 'rename', session = session, name = occurrence.name }
          end
          if occurrence.cwd and path_key(occurrence.cwd) ~= path_key(session.cwd) then
            ops[#ops + 1] = { kind = 'move', session = session, cwd = occurrence.cwd }
          end
        else
          ops[#ops + 1] = {
            kind = 'copy',
            session = session,
            cwd = occurrence.cwd or session.cwd,
            name = occurrence.name ~= display_name(session) and occurrence.name or nil,
          }
        end
      end
    end
  end

  return ops
end

---@param op table
---@return string
local function describe_op(op)
  local picker = require 'conductor.picker'
  if op.kind == 'create' then
    return ('CREATE %q in %s'):format(op.name ~= '' and op.name or 'unnamed', picker.shorten_cwd(op.cwd))
  elseif op.kind == 'delete' then
    return ('DELETE %q'):format(op.session.name)
  elseif op.kind == 'rename' then
    return ('RENAME %q -> %q'):format(op.session.name, op.name)
  elseif op.kind == 'move' then
    return ('MOVE %q -> %s'):format(op.session.name, picker.shorten_cwd(op.cwd))
  end
  return ('COPY %q -> %s%s'):format(op.session.name, picker.shorten_cwd(op.cwd), op.name and (' as %q'):format(op.name) or '')
end

---Apply buffer edits to disk (BufWriteCmd handler).
local function apply_edits()
  if not editable() then
    vim.notify('conductor: adapter does not support session editing', vim.log.levels.WARN)
    return
  end
  local ops, parse_err = collect_ops()
  if parse_err then
    vim.notify('conductor: ' .. parse_err, vim.log.levels.ERROR)
    return
  end
  if #ops == 0 then
    vim.bo[state.list_buf].modified = false
    return
  end

  local summary = {}
  for index, op in ipairs(ops) do
    summary[index] = '  ' .. describe_op(op)
  end
  local choice = vim.fn.confirm(('Apply %d change(s)?\n%s'):format(#ops, table.concat(summary, '\n')), '&Yes\n&No', 2)
  if choice ~= 1 then
    return
  end

  local fs = state.adapter.fs
  local root = state.adapter.sessions_root()
  -- Order: create/copy/rename first, then move, then delete — renames must hit
  -- the file before a move relocates it.
  local order = { create = 1, copy = 1, rename = 1, move = 2, delete = 3 }
  table.sort(ops, function(a, b)
    return order[a.kind] < order[b.kind]
  end)

  local errors = {}
  for _, op in ipairs(ops) do
    local ok, op_err
    if op.kind == 'create' then
      ok, op_err = fs.create(root, op.cwd, op.name ~= '' and op.name or nil)
    elseif op.kind == 'copy' then
      ok, op_err = fs.copy(root, op.session, op.cwd, op.name)
    elseif op.kind == 'rename' then
      ok, op_err = fs.rename(op.session.path, op.name)
    elseif op.kind == 'move' then
      ok, op_err = fs.move(root, op.session, op.cwd)
    elseif op.kind == 'delete' then
      ok, op_err = fs.delete(op.session.path)
    end
    if not ok then
      errors[#errors + 1] = ('%s: %s'):format(describe_op(op), op_err or 'unknown error')
    end
  end

  if #errors > 0 then
    vim.notify('conductor: some changes failed\n' .. table.concat(errors, '\n'), vim.log.levels.ERROR)
  end
  state.entry_cache = {}
  refresh_sessions()
end

--- Content rendering (main panel) -------------------------------------------

---Cached parse for `session.path`, if any (regardless of freshness). A cache
---entry is only valid for the currently-chosen branch tip, so switching
---branches re-parses rather than serving the previously-rendered branch.
---@param session ConductorSession
---@return { mtime: integer, meta: ConductorSessionMeta, entries: ConductorLogEntry[], leaf: string|nil }|nil
local function cached_entries(session)
  local stat = vim.uv.fs_stat(session.path)
  local mtime = stat and stat.mtime.sec or 0
  local cached = state.entry_cache[session.path]
  if cached and cached.mtime == mtime and cached.leaf == state.branch_choice[session.path] then
    return cached
  end
  return nil
end

---Parse a session log off the main thread (conductor.threadwork) when the
---adapter supports it; large multi-MB logs can take tens of ms to parse.
---Serves from cache (mtime-checked) without touching the thread pool at all.
---@param session ConductorSession
---@param callback fun(meta: ConductorSessionMeta, entries: ConductorLogEntry[])
local function parsed_entries_async(session, callback)
  local cached = cached_entries(session)
  if cached then
    callback(cached.meta, cached.entries)
    return
  end

  local stat = vim.uv.fs_stat(session.path)
  local mtime = stat and stat.mtime.sec or 0
  local leaf = state.branch_choice[session.path]

  -- A chosen (non-newest) branch parses on the main thread: it is a deliberate,
  -- infrequent action, and the adapter's async transport only ever renders the
  -- newest tip. Small cost, and it keeps the async path (below) unchanged.
  if leaf then
    local meta, entries = state.adapter.parse_log(session.path, { target_leaf = leaf })
    state.entry_cache[session.path] = { mtime = mtime, meta = meta, entries = entries, leaf = leaf }
    callback(meta, entries)
    return
  end

  if not state.adapter.parse_log_async then
    local meta, entries = state.adapter.parse_log(session.path)
    state.entry_cache[session.path] = { mtime = mtime, meta = meta, entries = entries, leaf = nil }
    callback(meta, entries)
    return
  end

  state.adapter.parse_log_async(session.path, function(ok, result_or_error)
    if not ok then
      vim.notify('conductor: ' .. tostring(result_or_error), vim.log.levels.ERROR)
      callback({ message_count = 0 }, {})
      return
    end
    state.entry_cache[session.path] = { mtime = mtime, meta = result_or_error.meta, entries = result_or_error.entries, leaf = nil }
    callback(result_or_error.meta, result_or_error.entries)
  end)
end

---@param meta ConductorSessionMeta
---@param entries ConductorLogEntry[]
---@param session ConductorSession
---@return string[] lines, table<integer, integer> tool_lines
---Expand any *tool* entry whose visible-when-collapsed text does not already
---contain `query` but whose folded `output` (or `summary`) does, so a match the
---cross-session grep found inside collapsed tool output becomes visible after a
---`reveal`. Case-insensitive substring, mirroring the search index.
---@param entries ConductorLogEntry[]
---@param query string
local function expand_matching_tools(entries, query)
  local needle = query:lower()
  if needle == '' then
    return
  end
  for _, entry in ipairs(entries) do
    if entry.role == 'tool' and not entry.expanded then
      local output = entry.output or ''
      local summary = entry.summary or ''
      if output:lower():find(needle, 1, true) or summary:lower():find(needle, 1, true) then
        entry.expanded = true
      end
    end
  end
end

local function render_content_lines(meta, entries, session)
  local lines = {}
  local tool_lines = {}
  local function add(text)
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
      lines[#lines + 1] = line
    end
  end

  local picker = require 'conductor.picker'
  -- Relative label from an in-file ISO timestamp (copy/move-proof), falling back
  -- to the filesystem mtime only when the session carries no such timestamp.
  local function when(iso)
    local label = iso and picker.relative_time_iso(iso) or ''
    return label ~= '' and label or picker.relative_time(session.mtime)
  end
  add(('# %s'):format(session.name))
  add(('created %s · updated %s · %d msg'):format(when(meta.created), when(meta.last_activity), meta.message_count))
  if meta.cwd then
    add(('cwd: %s'):format(meta.cwd))
  end
  add ''

  for index, entry in ipairs(entries) do
    if entry.role == 'user' then
      add '## You'
      add(entry.text)
      add ''
    elseif entry.role == 'assistant' then
      add '## Agent'
      add(entry.text)
      add ''
    elseif entry.role == 'tool' then
      local marker = entry.expanded and '▼' or '▶'
      local label = (entry.summary and entry.summary ~= '') and ('%s `%s`'):format(entry.text, entry.summary) or entry.text
      add(('> %s %s%s'):format(marker, label, entry.is_error and ' ✗' or ''))
      tool_lines[#lines] = index
      if entry.expanded and entry.output and entry.output ~= '' then
        add '```'
        add(entry.output)
        add '```'
      end
      add ''
    else
      add('> ' .. entry.text:gsub('\n', '\n> '))
      add ''
    end
  end
  return lines, tool_lines
end

local function toggle_tool_at_cursor()
  if not state.current_path then
    return
  end
  local cached = state.entry_cache[state.current_path]
  if not cached then
    return
  end
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local entry_index = state.tool_lines[cursor_row]
  if not entry_index then
    for row = cursor_row - 1, 1, -1 do
      if state.tool_lines[row] then
        entry_index = state.tool_lines[row]
        break
      end
    end
  end
  local entry = entry_index and cached.entries[entry_index]
  if not entry or entry.role ~= 'tool' then
    return
  end
  entry.expanded = not entry.expanded
  -- Re-render, keeping the cursor on the toggled tool line.
  local session
  for _, candidate in ipairs(state.sessions) do
    if candidate.path == state.current_path then
      session = candidate
      break
    end
  end
  if not session then
    return
  end
  local lines, tool_lines = render_content_lines(cached.meta, cached.entries, session)
  state.tool_lines = tool_lines
  vim.bo[state.content_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.content_buf, 0, -1, false, lines)
  vim.bo[state.content_buf].modifiable = false
  for row, index in pairs(tool_lines) do
    if index == entry_index then
      vim.api.nvim_win_set_cursor(0, { row, 0 })
      break
    end
  end
end

---@param direction 1|-1
local function jump_tool(direction)
  local cursor_row = vim.api.nvim_win_get_cursor(0)[1]
  local best
  for row in pairs(state.tool_lines) do
    if direction == 1 and row > cursor_row and (not best or row < best) then
      best = row
    elseif direction == -1 and row < cursor_row and (not best or row > best) then
      best = row
    end
  end
  if best then
    vim.api.nvim_win_set_cursor(0, { best, 0 })
  end
end

---The session currently rendered in the content panel, if any.
---@return ConductorSession|nil
local function current_session()
  if not state.current_path then
    return nil
  end
  for _, candidate in ipairs(state.sessions) do
    if candidate.path == state.current_path then
      return candidate
    end
  end
  return nil
end

-- Forward declaration: assigned after show_session (which it calls to re-render).
local switch_branch

local function ensure_content_buf()
  if buf_valid(state.content_buf) then
    return
  end
  state.content_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(state.content_buf, 'conductor://browser')
  vim.bo[state.content_buf].buftype = 'nofile'
  vim.bo[state.content_buf].bufhidden = 'hide'
  vim.bo[state.content_buf].swapfile = false
  vim.bo[state.content_buf].filetype = 'markdown'
  vim.bo[state.content_buf].modifiable = false

  local config = require 'conductor.config'
  local options = { buffer = state.content_buf, nowait = true }
  config.map('browser_content', 'toggle_tool', 'n', toggle_tool_at_cursor, vim.tbl_extend('force', options, { desc = 'Conductor: toggle tool output' }))
  config.map('browser_content', 'next_tool', 'n', function()
    jump_tool(1)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: next tool call' }))
  config.map('browser_content', 'prev_tool', 'n', function()
    jump_tool(-1)
  end, vim.tbl_extend('force', options, { desc = 'Conductor: previous tool call' }))
  config.map('browser_content', 'switch_branch', 'n', function()
    switch_branch()
  end, vim.tbl_extend('force', options, { desc = 'Conductor: switch branch' }))
  config.map('browser_content', 'close', 'n', function()
    M.close()
  end, vim.tbl_extend('force', options, { desc = 'Conductor: close browser' }))

  require('conductor.help').attach(state.content_buf)
end

---Find (or create) the main window to the right of the list panel.
local function ensure_content_win()
  if win_valid(state.content_win) then
    return
  end
  -- Prefer an existing non-list window in the current tab.
  local current = vim.api.nvim_get_current_win()
  if win_valid(state.list_win) then
    vim.api.nvim_set_current_win(state.list_win)
    vim.cmd 'wincmd l'
    local candidate = vim.api.nvim_get_current_win()
    -- Never adopt a live chat shell window as the preview pane: doing so would
    -- clobber the running chat with a static log. Open a fresh split instead.
    if candidate ~= state.list_win and not require('conductor.chatlog').is_shell_window(candidate) then
      state.content_win = candidate
    else
      vim.cmd 'rightbelow vsplit'
      state.content_win = vim.api.nvim_get_current_win()
    end
  else
    state.content_win = current
  end
  -- `current` was captured before we hopped to `state.list_win` (possibly in
  -- another tab). When this runs from the async refresh callback the user may
  -- have since closed that window, so only restore focus if it is still valid.
  if win_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

---@param buffer_lines string[]
local function set_content_lines(buffer_lines)
  vim.bo[state.content_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.content_buf, 0, -1, false, buffer_lines)
  vim.bo[state.content_buf].modifiable = false
end

---Scroll the content window to the first line containing `query` and centre it,
---*without* changing the focused window (so it works from a list-cursor hover).
---Best-effort: a miss leaves the view untouched.
---@param query string
local function scroll_content_to(query)
  if not win_valid(state.content_win) or not buf_valid(state.content_buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(state.content_buf, 0, -1, false)
  for i, line in ipairs(lines) do
    if line ~= '' and line:find(query, 1, true) then
      pcall(vim.api.nvim_win_set_cursor, state.content_win, { i, 0 })
      vim.api.nvim_win_call(state.content_win, function()
        vim.cmd 'normal! zz'
      end)
      return
    end
  end
end

---Render a session into the main panel. Parsing happens off the main thread
---(see `parsed_entries_async`); a lightweight placeholder is shown
---immediately so switching sessions never stalls the UI, and the real
---content replaces it once ready. `content_generation` guards against a
---stale async parse (e.g. from a big log) landing after the cursor has since
---moved to a different session.
---@param session ConductorSession
---@param on_ready fun()|nil called once the *final* content is rendered (cached or async)
---@param session ConductorSession
---@param on_ready fun()|nil
---@param expand_query string|nil when set, tool entries whose folded output/
---  summary contain it are expanded before render so a grep match is visible.
local function show_session(session, on_ready, expand_query)
  ensure_content_buf()
  ensure_content_win()

  state.content_generation = state.content_generation + 1
  local generation = state.content_generation
  state.current_path = session.path
  state.tool_lines = {}

  local picker = require 'conductor.picker'
  local cached = cached_entries(session)
  if cached then
    if expand_query then
      expand_matching_tools(cached.entries, expand_query)
    end
    local lines, tool_lines = render_content_lines(cached.meta, cached.entries, session)
    state.tool_lines = tool_lines
    set_content_lines(lines)
  else
    local loading_when = session.last_activity and picker.relative_time_iso(session.last_activity) or ''
    if loading_when == '' then
      loading_when = picker.relative_time(session.mtime)
    end
    set_content_lines { ('# %s'):format(session.name), ('%s · loading…'):format(loading_when) }
  end

  if win_valid(state.content_win) then
    vim.api.nvim_win_set_buf(state.content_win, state.content_buf)
    vim.wo[state.content_win].wrap = true
    vim.wo[state.content_win].linebreak = true
    vim.wo[state.content_win].number = false
    vim.wo[state.content_win].relativenumber = false
    vim.wo[state.content_win].signcolumn = 'no'
    vim.wo[state.content_win].conceallevel = 2
  end

  if cached then
    if on_ready then
      on_ready()
    end
    return
  end

  parsed_entries_async(session, function(meta, entries)
    if generation ~= state.content_generation or state.current_path ~= session.path then
      return -- superseded by a newer show_session() call
    end
    if expand_query then
      expand_matching_tools(entries, expand_query)
    end
    local lines, tool_lines = render_content_lines(meta, entries, session)
    state.tool_lines = tool_lines
    set_content_lines(lines)
    if on_ready then
      on_ready()
    end
  end)
end

---Render branch tip `leaf_id` for `session`. Choosing the newest tip clears
---the override so the fast async path resumes serving it; any other tip is
---pinned (`branch_choice`) so re-renders keep showing it.
---@param session ConductorSession
---@param leaf_id string
local function apply_branch(session, leaf_id)
  local cached = state.entry_cache[session.path]
  local newest = cached and cached.meta and cached.meta.leaves and cached.meta.leaves[1]
  state.branch_choice[session.path] = (newest and leaf_id == newest.id) and nil or leaf_id
  show_session(session)
end

---Pick which branch tip (rewind/edit fork) fills the content panel. No-op for
---linear sessions. Assigns the forward-declared `switch_branch` upvalue.
function switch_branch()
  local session = current_session()
  if not session then
    return
  end
  local cached = state.entry_cache[session.path]
  local leaves = cached and cached.meta and cached.meta.leaves
  if not leaves or #leaves < 2 then
    vim.notify('conductor: session has a single branch', vim.log.levels.INFO)
    return
  end
  vim.ui.select(leaves, {
    prompt = 'Switch branch:',
    format_item = function(leaf)
      local excerpt = (leaf.text ~= nil and leaf.text ~= '') and leaf.text or '(no prompt)'
      return ('%s %s'):format(leaf.active and '●' or '○', excerpt)
    end,
  }, function(choice)
    if not choice then
      return
    end
    apply_branch(session, choice.id)
  end)
end

---Move the content-window cursor to the first occurrence of `query`, enabling
---search highlight so `n`/`N` continue from there. Best-effort: a miss is a
---no-op (the session content is still shown).
---@param query string
local function jump_to_query(query)
  if not win_valid(state.content_win) then
    return
  end
  vim.api.nvim_set_current_win(state.content_win)
  local pattern = '\\V' .. vim.fn.escape(query, '\\')
  pcall(vim.api.nvim_win_set_cursor, state.content_win, { 1, 0 })
  if vim.fn.search(pattern, 'cW') > 0 then
    vim.fn.setreg('/', pattern)
    vim.v.hlsearch = 1
    vim.cmd 'normal! zz'
  end
end

---Position the list cursor on `session`, if it is present in the current list.
---@param session ConductorSession
local function locate_in_list(session)
  if not win_valid(state.list_win) then
    return
  end
  for line, index in pairs(state.line_to_session) do
    local candidate = state.sessions[index]
    if candidate and candidate.path == session.path then
      pcall(vim.api.nvim_win_set_cursor, state.list_win, { line, 0 })
      return
    end
  end
end

local function preview_debounced()
  state.preview_generation = state.preview_generation + 1
  local generation = state.preview_generation
  vim.defer_fn(function()
    if generation ~= state.preview_generation or not win_valid(state.list_win) then
      return
    end
    local session, leaf, jump = branch_target_at_cursor()
    if session then
      -- Only re-render when the target (session *or* branch tip) changed.
      if session.path == state.current_path and state.branch_choice[session.path] == leaf then
        return
      end
      state.branch_choice[session.path] = leaf
      -- On a branch tip, scroll to where it split from main once rendered.
      show_session(session, jump and function()
        scroll_content_to(jump)
      end or nil)
    end
  end, 80)
end

--- List panel setup ----------------------------------------------------------

---Project directory for the group the cursor currently sits in: scan upward
---from the cursor for the nearest header line. Falls back to the active
---cwd filter, then Neovim's cwd, so a new session always has a sane default.
---@return string
local function cwd_at_cursor()
  if win_valid(state.list_win) and buf_valid(state.list_buf) then
    local row = vim.api.nvim_win_get_cursor(state.list_win)[1]
    local lines = vim.api.nvim_buf_get_lines(state.list_buf, 0, row, false)
    for i = #lines, 1, -1 do
      local kind, _, text = parse_line(lines[i])
      if kind == 'header' then
        local cwd = header_to_cwd(text)
        if cwd then
          return cwd
        end
      end
    end
  end
  return state.cwd_filter or vim.fn.getcwd()
end

---Create a new session interactively: prompt for a name, then show the
---target project directory pre-filled and editable so it can be confirmed
---or corrected before the file is written. This is the discoverable
---counterpart to editing the buffer directly and saving with `:w`.
local function create_new_session()
  if not editable() then
    vim.notify('conductor: adapter does not support session editing', vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = 'New session name (optional): ' }, function(name)
    if name == nil then
      return -- cancelled
    end
    name = vim.trim(name)
    vim.ui.input({ prompt = 'Location: ', default = cwd_at_cursor(), completion = 'dir' }, function(location)
      if location == nil then
        return -- cancelled
      end
      local cwd = vim.fs.normalize(vim.fn.expand(vim.trim(location)))
      if cwd == '' then
        vim.notify('conductor: location must not be empty', vim.log.levels.ERROR)
        return
      end
      -- Spawn a managed instance (headless RPC) and open its chat, mirroring
      -- `:Conductor new`. This both creates the session *and* attaches to it,
      -- instead of only writing an empty file to disk.
      local instance, spawn_error = require('conductor.supervisor').spawn {
        adapter = state.adapter.name,
        cwd = cwd,
        name = name ~= '' and name or nil,
      }
      if not instance then
        vim.notify('conductor: ' .. (spawn_error or 'spawn failed'), vim.log.levels.ERROR)
        return
      end
      state.entry_cache = {}
      refresh_sessions()
      -- Replace the browser's log-preview pane in place with the live chat
      -- (log + prompt) rather than bolting on a new split. The list stays on
      -- the left; only the right pane changes from static log to live chat.
      ensure_content_win()
      local reuse_win = win_valid(state.content_win) and state.content_win or nil
      state.content_win = nil -- chatlog now owns this window
      require('conductor.chatlog').open(instance, { reuse_win = reuse_win })
    end)
  end)
end

local function setup_list_keymaps()
  local config = require 'conductor.config'
  local options = { buffer = state.list_buf, nowait = true }

  config.map('browser_list', 'open', 'n', function()
    -- Opens the content the cursor points at (a session, or a specific branch
    -- tip on an expanded row) and focuses the content window. Expanding a
    -- forked session's branches is `<Tab>` (toggle_branches), not `<CR>`.
    local session, leaf, jump = branch_target_at_cursor()
    if session then
      state.branch_choice[session.path] = leaf
      show_session(session, jump and function()
        scroll_content_to(jump)
      end or nil)
      if win_valid(state.content_win) then
        vim.api.nvim_set_current_win(state.content_win)
      end
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: open session content' }))

  config.map('browser_list', 'toggle_branches', 'n', function()
    local session = session_at_cursor()
    if session and session.forked then
      state.branch_expanded[session.path] = not state.branch_expanded[session.path] or nil
      render_list()
      locate_in_list(session)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: expand / collapse branches' }))

  -- g-prefixed actions: the buffer is editable, so bare r/a/o/c must stay
  -- available as normal editing commands (oil.nvim-style).
  config.map('browser_list', 'resume', 'n', function()
    local session = session_at_cursor()
    if session then
      require('conductor.picker').action_resume(session)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: resume in terminal' }))

  config.map('browser_list', 'attach', 'n', function()
    local session = session_at_cursor()
    if session then
      require('conductor.picker').action_attach(session)
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: attach managed instance' }))

  config.map('browser_list', 'open_raw', 'n', function()
    local session = session_at_cursor()
    if session then
      ensure_content_win()
      if win_valid(state.content_win) then
        vim.api.nvim_set_current_win(state.content_win)
      end
      vim.cmd.edit(vim.fn.fnameescape(session.path))
    end
  end, vim.tbl_extend('force', options, { desc = 'Conductor: open raw log' }))

  config.map('browser_list', 'toggle_cwd', 'n', function()
    state.cwd_filter = state.cwd_filter == nil and vim.fn.getcwd() or nil
    refresh_sessions()
  end, vim.tbl_extend('force', options, { desc = 'Conductor: toggle cwd/all filter' }))

  config.map('browser_list', 'refresh', 'n', refresh_sessions, vim.tbl_extend('force', options, { desc = 'Conductor: refresh sessions' }))

  config.map('browser_list', 'new', 'n', create_new_session, vim.tbl_extend('force', options, { desc = 'Conductor: new session' }))

  config.map('browser_list', 'search', 'n', function()
    require('conductor.search').open()
  end, vim.tbl_extend('force', options, { desc = 'Conductor: grep search all sessions' }))

  config.map('browser_list', 'close', 'n', M.close, vim.tbl_extend('force', options, { desc = 'Conductor: close browser' }))

  require('conductor.help').attach(state.list_buf)
end

--- Public API ----------------------------------------------------------------

---Open the session browser.
---@param opts { cwd?: string|false }|nil cwd filter; false = all projects, nil = current cwd
function M.open(opts)
  opts = opts or {}
  if opts.cwd == false then
    state.cwd_filter = nil
  else
    state.cwd_filter = opts.cwd or vim.fn.getcwd()
  end

  if win_valid(state.list_win) then
    refresh_sessions()
    vim.api.nvim_set_current_win(state.list_win)
    return
  end

  if not buf_valid(state.list_buf) then
    state.list_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.list_buf, 'conductor://browser-list')
    vim.bo[state.list_buf].buftype = 'acwrite' -- :w triggers BufWriteCmd (oil-style apply)
    vim.bo[state.list_buf].bufhidden = 'hide'
    vim.bo[state.list_buf].swapfile = false
    vim.bo[state.list_buf].filetype = 'conductor'
    setup_list_keymaps()

    vim.api.nvim_create_autocmd('CursorMoved', {
      buffer = state.list_buf,
      callback = function()
        highlight_cursor_line() -- immediate; no debounce so selection never lags
        preview_debounced()
      end,
    })

    vim.api.nvim_create_autocmd('BufWriteCmd', {
      buffer = state.list_buf,
      callback = apply_edits,
    })
  end

  ensure_highlights()
  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('ConductorBrowserHl', { clear = true }),
    callback = function()
      ensure_highlights()
      render_list()
    end,
  })

  local width = require('conductor.config').options.browser.width
  vim.cmd(('topleft %dvsplit'):format(width))
  state.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.list_win, state.list_buf)
  vim.wo[state.list_win].number = false
  vim.wo[state.list_win].relativenumber = false
  vim.wo[state.list_win].signcolumn = 'no'
  vim.wo[state.list_win].winfixwidth = true
  vim.wo[state.list_win].wrap = false
  -- The selected row is painted by a high-priority extmark (highlight_cursor_line)
  -- instead of the built-in 'cursorline', which loses the priority tie against
  -- the zebra stripes' line_hl_group and vanishes on striped rows.
  vim.wo[state.list_win].cursorline = false
  vim.wo[state.list_win].conceallevel = 2
  vim.wo[state.list_win].concealcursor = 'nc'
  -- Fold each project group (header + its sessions) like a normal file.
  vim.wo[state.list_win].foldmethod = 'expr'
  vim.wo[state.list_win].foldexpr = "v:lua.require'conductor.browser'.foldexpr()"
  vim.wo[state.list_win].foldtext = "v:lua.require'conductor.browser'.foldtext()"
  vim.wo[state.list_win].foldlevel = 99 -- start with all groups expanded
  vim.wo[state.list_win].fillchars = 'fold: '

  -- Land on the first session once the (async) list arrives.
  refresh_sessions(function()
    local first_line
    for line in pairs(state.line_to_session) do
      if not first_line or line < first_line then
        first_line = line
      end
    end
    if first_line and win_valid(state.list_win) then
      vim.api.nvim_win_set_cursor(state.list_win, { first_line, 0 })
    end
    local session = session_at_cursor()
    if session then
      show_session(session)
    end
  end)
end

---Open (or focus) the browser, render `session` in the content pane, and jump
---to the first occurrence of `query`. Backs the cross-session grep
---(`conductor.search`). When the browser is closed it is opened across all
---projects first so the target session is always reachable.
---@param session ConductorSession
---@param query string|nil
function M.reveal(session, query)
  local opening = not win_valid(state.list_win)
  local function do_reveal()
    show_session(session, function()
      if query and query ~= '' then
        jump_to_query(query)
      end
    end, query)
    locate_in_list(session)
  end
  if opening then
    M.open { cwd = false }
    -- open()'s session list loads asynchronously; give it a beat before we
    -- position the list cursor (content rendering does not depend on it).
    vim.defer_fn(do_reveal, 120)
  else
    do_reveal()
  end
end

---Whether the browser list panel is currently open in the current tab.
---@return boolean
function M.is_open()
  return win_valid(state.list_win)
end

function M.close()
  state.preview_generation = state.preview_generation + 1
  if win_valid(state.content_win) and buf_valid(state.content_buf) then
    -- Only close the content window if it is still showing our buffer.
    if vim.api.nvim_win_get_buf(state.content_win) == state.content_buf then
      local windows = vim.api.nvim_tabpage_list_wins(0)
      if #windows > (win_valid(state.list_win) and 2 or 1) then
        vim.api.nvim_win_close(state.content_win, true)
      end
    end
  end
  if win_valid(state.list_win) then
    vim.api.nvim_win_close(state.list_win, true)
  end
  state.list_win = nil
  state.content_win = nil
  state.current_path = nil
end

---Resolve the cwd_filter value a given open() opts would produce.
---@param opts { cwd?: string|false }|nil
---@return string|nil
local function resolve_filter(opts)
  opts = opts or {}
  if opts.cwd == false then
    return nil
  end
  return opts.cwd or vim.fn.getcwd()
end

function M.toggle(opts)
  if win_valid(state.list_win) then
    -- Only toggle closed when re-opening the *same* scope; otherwise switch
    -- the open browser to the requested scope instead of closing it.
    if state.cwd_filter == resolve_filter(opts) then
      M.close()
    else
      M.open(opts)
    end
  else
    M.open(opts)
  end
end

return M
