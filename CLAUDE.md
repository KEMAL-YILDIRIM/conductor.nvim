# CLAUDE.md

## Project Overview

`conductor.nvim` — a pure-Lua Neovim plugin to manage AI agent conversations
(sessions) from the editor: discover session logs, preview parsed transcripts,
resume/spawn agents, and render live streaming chat. Currently targets the
**pi coding agent** behind an adapter interface (Claude Code / OpenCode
planned). See `CODEBASE_MAP.md` for the component map.

## Common Commands

- **Format**: `stylua lua/` (config in `.stylua.toml`)
- **Try it in Neovim**: `:Conductor browse` (cwd sessions), `browse_all`,
  `sessions`, `here`, `panel`, `search`, `new`
- No build step / test suite (Lua plugin).

## Architecture Notes

- Entry: `lua/conductor/init.lua` → `M.setup(opts)` registers `:Conductor`.
- Harness-specific code lives behind `lua/conductor/adapters/interface.lua`
  (normalized event vocabulary; pi impl in `pi*.lua`).
- Heavy scans/parses run off-thread via `threadwork.lua` (libuv threadpool,
  isolated Lua state — no upvalues/globals in worker fns).
- UI refresh is event-driven via the `User ConductorUpdate` autocmd.
- Backend-neutral picker core in `picker.lua`; telescope/fzf-lua are thin
  frontends.

## Behavioral Patterns

See [~/.claude/patterns/_global.md](~/.claude/patterns/_global.md) for global
patterns that apply to all projects.

## Session Learnings
<!-- Learnings captured by /learn command -->

### 2026-02-13
- **pi sessions are a `parentId` DAG, not a linear log.** Rewind/edit/retry
  appends a *sibling* entry at a shared `parentId`, so a file can hold several
  conversation tips ("branches"). Real data: 28 of 545 local sessions fork
  (up to 9 tips). Abandoned branches stay in the file. The live conversation is
  the message **leaf with the newest timestamp**; walk its `parentId` chain to
  the root to get the render path. `log_parser.parse` does this in two passes
  (decode all → resolve active path → render on-path only).
- **Collapse metadata hops when detecting leaves.** pi threads `session_info`
  (rename), `model_change`, etc. into the `parentId` chain *between* two
  messages. Naive "message with no message child = leaf" then counts an interior
  message as a false branch tip (inflated 63 vs true 28 forks). Resolve each
  message's *nearest message ancestor* by walking up through non-message
  entries. Only real string `parentId`s link the DAG (JSON null / missing =
  root / metadata).
- **Browser branch switch renders a chosen tip on the main thread.** The
  content cache (`state.entry_cache`) is keyed by path **and** `leaf`
  (`cache.leaf == state.branch_choice[path]`), so switching branches misses the
  cache and re-parses. The newest tip stays on the async (threadwork) path;
  only a *pinned* non-newest tip does a synchronous `parse_log(path,
  { target_leaf })` — fine because it's a deliberate, rare `gb` action. Choosing
  the newest tip clears the override (`branch_choice[path] = nil`) so the async
  path resumes serving it.
- **`switch_branch` is forward-declared.** It's referenced by
  `ensure_content_buf`'s keymap (defined early) but calls `show_session`
  (defined late), so declare `local switch_branch` before `ensure_content_buf`
  and later assign `function switch_branch() ... end` (no `local`) to fill the
  upvalue — avoids the def-order cycle.
- **Window-local `foldexpr`/`foldtext` leak via split inheritance.** The browser
  sets them on its list window; new windows split off it (content pane, or any
  later `:split`) *copy* these window-local options. A C# file opened in such a
  window then shows conductor's `(N sessions)` foldtext (its ft config overrides
  `foldmethod`/`foldexpr` but not `foldtext`). Fix: guard both functions on
  `vim.bo.filetype == 'conductor'` and defer to Neovim defaults otherwise
  (`foldexpr` → `'0'`, `foldtext` → `vim.fn.foldtext()`). Because leaked windows
  reference the functions **by name** (`v:lua.require'...'.foldtext()`), guarding
  the function itself self-heals every already-leaked window on plugin reload —
  no need to track them down.
- **Investigate against real data before designing.** pi's session schema stores
  a per-message `parentId` (a DAG), but only ~5% of local sessions actually
  fork; a 3-file sample looked purely linear. Scanning the *full* store
  (`~/.config/ai/pi/agent/sessions`, 545 files) surfaced the 28 real forks and
  the exact fan-out semantics — don't conclude "feature has no data" from a tiny
  sample.

### 2026-02-12
- **Preview buffers: use `syntax`, not `filetype`.** Set
  `vim.bo[buf].syntax = 'markdown'` for picker/search previews. Using
  `filetype = 'markdown'` triggers the FileType autocmd → Treesitter attaches;
  on picker cancel (`<C-c>` sets `got_int`), telescope's `nvim_buf_delete` runs
  the highlighter `destroy()` via `nvim_buf_call`, which raises "Keyboard
  interrupt". `syntax=` fires the Syntax autocmd instead, so no TS highlighter
  exists to tear down. Shared helper: `picker.highlight_markdown_preview`.
- **Browser selection is an extmark, not `cursorline`.** `line_hl_group` zebra
  stripes win the priority tie against built-in CursorLine and hide it on
  striped rows. The selected row is painted by a high-priority
  (`priority = 200`) extmark in a dedicated `conductor_browser_cursor`
  namespace, redrawn on every `CursorMoved` (no debounce, so selection never
  lags). `cursorline` is left `false`.
- **Highlights track the theme.** `ensure_highlights()` derives stripe +
  selected-row colors from `Normal` bg (luminance-based nudge / cyan blend),
  uses `default = true` so user groups win, and re-runs on `ColorScheme`.
- **Editable list rows keep 2 structural leading spaces** required by the
  `^%s` header/session test in `parse_line`/foldexpr; the whole `  /NNN `
  prefix is concealed so names render at column 0 and row fills span
  edge-to-edge.
