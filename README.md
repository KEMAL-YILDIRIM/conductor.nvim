# conductor.nvim

Manage AI agent conversations from Neovim. Discover sessions, preview conversation logs in a telescope picker, and resume them in a terminal.

Currently supports the [pi coding agent](https://github.com/earendil-works/pi-mono); the adapter interface is designed so other harnesses (Claude Code, OpenCode, ...) can be added.

## Status / Roadmap

- **Phase 1 (done)**: session discovery, telescope picker with parsed conversation-log preview, resume in terminal
- **Phase 2 (done)**: RPC supervisor — spawn/manage `pi --mode rpc` processes, live sidebar with per-session status (streaming / needs input / idle / error), streaming chat buffer, agent dialog forwarding
- **Phase 3 (done)**: richer chat view — collapsible tool calls with captured output, tool navigation, persistent multi-line input bar
- **Phase 4 (done)**: backend-neutral picker core + fzf-lua backend, external-session visibility via the bundled `conductor-presence` pi extension
- **Later**: image support, richer external-session interaction (steering via socket)

## Requirements

- Neovim 0.10+
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim)
- [snacks.nvim](https://github.com/folke/snacks.nvim) (optional, preferred terminal backend)
- `pi` on `PATH`

## Installation (lazy.nvim)

```lua
{
  'conductor.nvim',
  dir = 'D:/projects/conductor.nvim', -- local development
  dependencies = { 'nvim-telescope/telescope.nvim' },
  cmd = 'Conductor',
  keys = {
    { '<leader>aa', '<cmd>Conductor browse<cr>', desc = 'Agent session browser (cwd)' },
    { '<leader>aA', '<cmd>Conductor browse_all<cr>', desc = 'Agent session browser (all)' },
    { '<leader>af', '<cmd>Conductor sessions<cr>', desc = 'Agent sessions picker (all)' },
    { '<leader>ah', '<cmd>Conductor here<cr>', desc = 'Agent sessions picker (cwd)' },
    { '<leader>ap', '<cmd>Conductor panel<cr>', desc = 'Agent panel (live sessions)' },
    { '<leader>an', '<cmd>Conductor new<cr>', desc = 'Agent new session' },
  },
  opts = {},
}
```

## Usage

| Command | Description |
|---|---|
| `:Conductor browse` | Toggle the session browser (left list panel, cwd sessions) |
| `:Conductor browse_all` | Toggle the session browser across all projects |
| `:Conductor sessions` | Pick from all sessions across projects (fuzzy picker) |
| `:Conductor here` | Pick from sessions for the current working directory |
| `:Conductor panel` | Toggle the live sessions sidebar |
| `:Conductor new [name]` | Spawn a new managed agent instance |
| `:Conductor search` | Grep across every session's conversation text |

### Session browser (`:Conductor browse`)

A persistent left panel lists sessions grouped by project directory (current
working directory by default). Moving the cursor over a session renders its
full conversation — including collapsible tool calls — in the main window on
the right.

| Key | Action |
|---|---|
| `j` / `k` | Navigate sessions; the content panel follows |
| `<CR>` | Focus the content panel |
| `gr` | Resume the session in a terminal |
| `ga` | Attach as a managed instance (headless RPC + chat) |
| `go` | Open the raw session `.jsonl` |
| `gc` | Toggle cwd-only / all-projects filter |
| `gn` | Create a new session (prompts for name + editable location) |
| `g/` | Live grep across all sessions — type to filter, `<CR>` jumps to the match |
| `gR` | Refresh the session list |
| `g?` | Toggle the keybinding cheatsheet |
| `q` | Close the browser |

#### Editing the list (oil.nvim-style)

The list buffer is modifiable; edit it like any text and `:w` applies the
changes to the session files on disk (after a confirmation prompt):

- **Rename** — change a session's name in place (appends a `session_info`
  entry, pi's own rename mechanism)
- **Delete** — delete the session's line (`dd`)
- **Move** — move a session's line under another project header (the header
  cwd in the `.jsonl` is rewritten so pi resumes it in the new project)
- **Copy** — paste a yanked session line under another project header
  (the copy gets a fresh session id); optionally edit the name on the copy
- **Create** — add a new indented line with a session name under a project
  header (creates an empty session you can attach to or resume)

Project headers are the unindented lines; you can also type a new header
(e.g. `~/code/other-project`) and place sessions under it. Session lines
carry a concealed `/id` token — leave it intact when editing names.

In the content panel: `<CR>` expands/collapses the tool call under the cursor,
`]t` / `[t` jump between tool calls, `q` closes the browser.

In the picker:

- `<CR>` — resume the session in a terminal (`pi --session <path>`)
- `<C-a>` — attach the session as a *managed* instance (headless RPC + chat buffer)
- `<C-o>` — open the raw session `.jsonl` file

In the sidebar (`:Conductor panel`):

| Key | Action |
|---|---|
| `<CR>` | Open the chat buffer for the instance under the cursor |
| `p` | Send a prompt without opening the chat |
| `n` | Spawn a new instance |
| `s` | Stop (abort) the running agent |
| `x` | Kill instance and remove it |
| `g?` | Toggle the keybinding cheatsheet |
| `q` | Close sidebar |

Status icons: running · needs input (agent finished or asked a question) · idle · error · exited. When an agent extension asks a question (select/confirm/input), conductor surfaces it via `vim.ui.select`/`vim.ui.input` and marks the instance *needs input*.

### External sessions (pi running in a terminal)

Install the bundled presence extension so pi processes running outside Neovim appear in the sidebar with live status:

```bash
cp pi-extension/conductor-presence.ts ~/.pi/agent/extensions/
```

External sessions are shown in an `External (terminal)` section (status polled every 2s while the sidebar is open; dead processes are pruned automatically). `<CR>` opens their session log read-only — prompting into an external TUI is out of scope for now.

### fzf-lua backend

Set `picker.backend = 'fzf-lua'` to use fzf-lua instead of telescope. Same actions: `<CR>` resume, `<C-a>` attach managed, `<C-o>` open raw log. Falls back to telescope if fzf-lua is not installed.

### Chat view

The chat view is a markdown log window with a persistent input bar below it.

Log window:

| Key | Action |
|---|---|
| `i` | Focus the input bar (insert mode) |
| `<CR>` | Expand/collapse the tool call under (or above) the cursor |
| `]t` / `[t` | Jump to next / previous tool call |
| `<C-c>` | Abort the running agent |
| `g?` | Toggle the keybinding cheatsheet |
| `q` | Close the chat view |

Tool calls render as `▶ bash \`echo hi\`` while collapsed; expanding shows the captured output in a fenced code block. Running tools show `…`, failed tools `✗`.

Input bar:

| Key | Action |
|---|---|
| `<CR>` | Send prompt (normal or insert mode) |
| `<S-CR>` | Insert newline |
| `<C-c>` | Stop (abort) the running agent |
| `<C-k>` | Focus the log window |
| `g?` | Toggle the keybinding cheatsheet |
| `q` | Close the chat view (normal mode) |

The previewer shows the **parsed conversation log** — user prompts and assistant replies only — not the raw JSONL, so you can quickly assess which session you're looking at.

## Configuration (defaults)

```lua
require('conductor').setup {
  default_adapter = 'pi',
  adapters = {
    pi = {
      cmd = 'pi',
      sessions_dir = nil, -- defaults to ~/.pi/agent/sessions
    },
  },
  picker = {
    backend = 'telescope', -- or 'fzf-lua'
    preview_max_entries = 200,
    preview_max_lines_per_entry = 20,
  },
  sidebar = {
    width = 36,
  },
  browser = {
    width = 44, -- session-list panel width
  },
  terminal = {
    backend = 'snacks', -- 'snacks', 'split', or 'external'
    snacks_win = { position = 'right', width = 0.5 },
    -- Used when backend = 'external'. Launch the resume command wherever you
    -- like (e.g. a new WezTerm tab). Return truthy on success; falsy/error
    -- falls back to a native nvim tab.
    -- open = function(o)
    --   return vim.system(vim.list_extend(
    --     { 'wezterm', 'cli', 'spawn', '--cwd', o.cwd, '--' }, o.argv)):wait().code == 0
    -- end,
    --
    -- Windows note: `argv[1]` is usually a .cmd/.bat shim (npm installs `pi` as
    -- `pi.cmd`). Spawning it directly makes the batch shim re-split arguments on
    -- spaces, corrupting session paths under e.g. `C:\Users\First Last\...` (the
    -- agent then exits non-zero). Launch through a shell that parses argv once:
    -- open = function(o)
    --   local q = {}
    --   for _, a in ipairs(o.argv) do
    --     q[#q + 1] = "'" .. tostring(a):gsub("'", "''") .. "'"
    --   end
    --   return vim.system({
    --     'wezterm', 'cli', 'spawn', '--cwd', o.cwd, '--',
    --     'pwsh', '-NoLogo', '-NoExit', '-Command', '& ' .. table.concat(q, ' '),
    --   }):wait().code == 0
    -- end,
  },
  -- Buffer-local keybindings, grouped by context. Override any key, or set it
  -- to `false` to disable it. Only the keys you change need to be listed.
  keymaps = {
    browser_list = {
      open = '<CR>',   -- open session content in the main window
      resume = 'gr',   -- resume in a terminal
      attach = 'ga',   -- attach as a managed (headless RPC) instance
      open_raw = 'go', -- open the raw log file
      toggle_cwd = 'gc', -- toggle cwd-only / all-projects filter
      refresh = 'gR',
      new = 'gn',
      close = 'q',
    },
    browser_content = {
      toggle_tool = '<CR>', next_tool = ']t', prev_tool = '[t', close = 'q',
    },
    sidebar = {
      open_chat = '<CR>', prompt = 'p', new = 'n', stop = 's', kill = 'x', close = 'q',
    },
    chat = {
      focus_input = 'i', toggle_tool = '<CR>', next_tool = ']t', prev_tool = '[t',
      abort = '<C-c>', close = 'q',
    },
    input = {
      send = '<CR>', newline = '<S-CR>', focus_log = '<C-k>', abort = '<C-c>', close = 'q',
    },
    help = {
      toggle = 'g?', -- toggle the keybinding cheatsheet (attached to every buffer)
    },
  },
}
```
