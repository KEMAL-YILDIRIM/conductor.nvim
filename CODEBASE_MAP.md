# Codebase Map
_Last updated: 2026-10-27_

## Architecture Overview

`conductor.nvim` is a Neovim plugin (pure Lua) for managing AI agent
conversations (sessions) from inside the editor. It discovers session logs,
previews parsed conversation transcripts, resumes/spawns agents, and renders
live streaming chat. It targets the **pi coding agent** today, but is built on
an **adapter interface** so other harnesses (Claude Code, OpenCode) can be
added.

Entry point: `M.setup(opts)` in `lua/conductor/init.lua`, which registers the
`:Conductor` user command with subcommands (`browse`, `browse_all`, `sessions`,
`here`, `panel`, `search`, `new`).

## Core Components

### Adapters (`lua/conductor/adapters/`)
- `interface.lua` — the adapter contract. Defines normalized event types
  (`agent_start`, `text_delta`, `tool_start`, `ui_request`, …), core
  `@class`es (`ConductorSession`, `ConductorInstanceHandle`), and the
  registry. Phases: (1) discovery/parse/resume, (2) `spawn()` managed headless
  instances emitting normalized events.
- `pi.lua`, `pi_fs.lua`, `pi_rpc.lua` — the pi implementation: filesystem
  discovery and the `pi --mode rpc` supervisor transport. `pi_rpc` exposes a
  generic `handle.request(command, callback)` (id-tagged, reply delivered on
  the main thread) and reports automatic compaction as notifications.
- `pi_commands.lua` — pi built-in slash commands for managed sessions
  (`/model`, `/thinking`, `/compact`, `/new`, `/name`, `/session`, `/fork`,
  `/clone`, `/export`, `/copy`, `/help`) mapped to RPC requests, plus
  `!cmd`/`!!cmd` shell shortcuts. `dispatch(instance, text)` returns
  `'handled' | 'rejected' | 'passthrough'`; `list_commands` caches pi's
  `get_commands` per instance (fetched at spawn). Wired as the optional adapter
  fields `dispatch_input` / `list_commands`.

### Session Discovery & Parsing
- `log_parser.lua` — parses pi session JSONL files into clean conversation logs
  + metadata (format per pi-coding-agent session-format docs).
- `threadwork.lua` — runs pure-Lua scans/parses on libuv's threadpool
  (`vim.uv.new_work`) so multi-MB JSONL reads don't block the UI. Worker runs in
  a fresh Lua state per call (no upvalues/globals).

### UI: Browser (`browser.lua`)
Persistent left panel listing sessions (cwd-scoped by default); selecting a
session renders its conversation in the main window. The list is editable,
oil.nvim-style: each line carries a hidden `/NNN ` id token (concealed) used to
map edits back to sessions. Zebra-striped rows + an extmark-painted selected-row
wash (not built-in `cursorline`). Project groups are folds.

### UI: Pickers
- `picker.lua` — **backend-neutral picker core**: listing, display formatting,
  async preview rendering, shared actions, and `highlight_markdown_preview`.
- `picker_fzf.lua` — fzf-lua frontend.
- `lua/telescope/_extensions/conductor.lua` — telescope frontend.

### UI: Search (`search.lua`)
Cross-session grep: indexes every session's *parsed* conversation text once
(off-thread via threadwork), live-filters as you type, then opens the match in
the browser and jumps/scrolls to the line.

### UI: Chat & Sidebar
- `chatlog.lua` — per-instance markdown-rendered chat view with collapsible
  tool-call entries and a persistent multi-line input bar (filetype
  `conductor_input`, `syntax=markdown`). Refused input stays in the bar;
  `set_input()` refills it (used by `/fork`).
- `completion.lua` — `/` command completion for the input bar: registers the
  `conductor.blink` source with blink.cmp at runtime (and restricts the
  `conductor_input` filetype to it unless the user configured that filetype),
  else falls back to `omnifunc` + a `TextChangedI` auto-trigger. Also
  `accept_if_open`/`close_if_open` so `<CR>`/`<C-c>`/`<C-k>` act on an open
  menu first.
- `blink.lua` — the blink.cmp source (enabled only in `conductor_input`).
- `sidebar.lua` — live sessions sidebar, one line per managed instance with a
  status icon. Push-updated via the `User ConductorUpdate` autocmd (no polling).
- `supervisor.lua` — owns managed instances, tracks status, broadcasts changes
  via `User ConductorUpdate`. `submit()` routes input through the adapter's
  `dispatch_input` before `prompt()`; `append`/`note`/`reset_log` helpers let
  commands write into the chat log.
- `ui_dialog.lua` — presents blocking agent `ui_request` dialogs via
  `vim.ui.select`/`vim.ui.input` and sends the response back.
- `help.lua` — floating keybinding cheatsheet (`g?`), rendered from buffer-local
  keymap `desc`s.

### External Sessions
- `external.lua` — discovers externally-running agents via presence files
  (`~/.pi/agent/conductor/presence/<pid>.json`) written by the bundled
  `pi-extension/conductor-presence.ts` extension.

### Config
- `config.lua` — defaults + `setup()`. Notable: `browser.width` (60 cols),
  terminal backend options, `chat.slash_completion`.

## Data Flow

1. `:Conductor <sub>` → `init.lua` dispatch.
2. Discovery: adapter (`pi_fs`) globs session files → `threadwork` parses
   off-thread → `ConductorSession[]`.
3. Preview/search: `log_parser` produces transcript text; pickers/search render
   markdown previews via `picker.highlight_markdown_preview`.
4. Managed run: `supervisor` spawns via adapter RPC → normalized events →
   `chatlog`/`sidebar`; `User ConductorUpdate` drives UI refresh.
5. Chat input: `chatlog` `<CR>` → `supervisor.submit` → adapter
   `dispatch_input` (built-in command → RPC request → system note; `!cmd` →
   `bash` request → tool entry) or passthrough → `handle.prompt`.

## Key Patterns

- **Adapter abstraction**: all harness-specific behavior lives behind
  `adapters/interface.lua`; normalized event vocabulary decouples UI from pi.
- **Off-main-thread work**: heavy globbing/parsing goes through
  `threadwork.lua` (libuv threadpool, isolated Lua state — no upvalues).
- **Event-driven UI**: `User ConductorUpdate` autocmd instead of polling.
- **Extmark-driven highlighting**: browser selection & zebra stripes use
  namespaced extmarks with explicit priorities rather than `cursorline`
  (which loses the priority tie against `line_hl_group` stripes).
- **`syntax` over `filetype` for previews**: set `vim.bo[buf].syntax =
  'markdown'` (not `filetype`) so Treesitter's FileType attach never fires —
  avoids "Keyboard interrupt" during buffer teardown on picker cancel.
- **Editable-list mapping via concealed id token**: list lines carry a hidden
  `/NNN ` token so oil.nvim-style edits map back to sessions.

## Recent Changes
- 2026-10-27 **Slash commands in managed sessions**: pi's built-in commands
  only work in its TUI, so `pi_commands.lua` intercepts them (and `!cmd`)
  and issues the matching RPC requests. pi's discovered commands are checked
  *before* the terminal-only refusal list (an extension registers `/llama`).
  Locally-run shell entries carry `local_command = true` so the agent's own
  `bash` `tool_end` events don't match them. `/` completion via a runtime
  blink.cmp source or native `omnifunc`; input bar filetype is now
  `conductor_input`.
- 2026-02-13 Fixed browser fold leak: `M.foldexpr`/`M.foldtext` are window-local
  and inherited by splits spawned off the browser, so collapsed folds in other
  buffers (e.g. a C# file) rendered conductor's "(N sessions)" foldtext. Both
  now guard on `vim.bo.filetype == 'conductor'` and defer to Neovim defaults
  otherwise; the guard lives in the named functions so already-leaked windows
  self-heal on plugin reload.
- 2026-02-13 Browser **branch view** (list-based): forked sessions get a
  `▸⑂`/`▾⑂` disclosure badge in front of the name in the **list** (inline virt
  text, so the editable row text stays clean) driven by a cheap
  `scan_meta.forked` flag. `<Tab>` (`browser_list.toggle_branches`) expands a
  forked session's tips as nested, selectable child rows *in the list* — rows
  carry a concealed `~NNN` token (`parse_line` → 'branch', ignored by the `:w`
  diff), mapped via `state.branch_index`; moving the cursor onto one previews
  that tip in the content pane and scrolls to where it split from main (its
  diverging prompt, via `scroll_content_to`, focus-preserving), and `<CR>`
  opens+focuses it (`branch_target_at_cursor` returns session/leaf/jump-text and
  drives both). `<CR>` on a session row just opens
  its content (expanding is `<Tab>` only). Tips are **grouped by fork point**:
  the newest/main tip renders as the trunk (`(main)` tag), the rest sit under a
  `⑂ split after: <excerpt>` label (inert `~NNN` token) built from each leaf's
  `fork_id`/`fork_text` (nearest main-branch message the tip diverged from,
  computed in `log_parser.resolve_active_path`). Tip rows show only a `●`/`○`
  marker (no `⑂`; the badge is the parent's). Tips are parsed on demand
  (`branch_leaves_for`, mtime-cached). `gb`
  (`browser_content.switch_branch`) remains a `vim.ui.select` fallback in the
  content pane. `log_parser.parse(path, { target_leaf })` renders a chosen tip;
  the browser pins it via `state.branch_choice` (main-thread parse for
  non-newest tips; the async path still serves the newest). Content cache is
  branch-keyed (`cache.leaf`). (The content pane no longer lists branches
  inline — superseded by the list view.)
- 2026-02-13 `log_parser.parse` now walks the pi `parentId` DAG and renders only
  the **active branch** (newest-timestamp message leaf → root). Fixes forked
  sessions (rewind/edit appends sibling entries) that previously interleaved
  abandoned retry branches into the transcript and inflated `message_count`.
  Exposes `meta.branch_count` + `meta.leaves` (branch tips, newest first).
  Validated across 545 real sessions (28 forked, 0 errors). `scan_meta` (cheap
  listing path) now sets `meta.forked` via a string-matched shared-parentId
  test for the list badge — validated on 558 sessions: 0 false positives, 1
  false negative vs the DAG parser.
- 2026-02-12 Browser zebra stripes + extmark-painted selected-row wash; full
  id-prefix conceal (names at col 0); panel widened to 60 cols; search preview
  scroll-to/highlight; `highlight_markdown_preview` fixes Treesitter teardown
  interrupt on picker cancel.
- Cross-session grep search (`:Conductor search`, `g/`).
- Open chat in place, keeping the sidebar put.
- External terminal backend + non-blocking session refresh.
- Editable session browser with help cheatsheet (`g?`).
- Initial codebase map created.
