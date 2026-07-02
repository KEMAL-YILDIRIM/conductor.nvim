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
    { '<leader>af', '<cmd>Conductor sessions<cr>', desc = 'Agent sessions (all)' },
    { '<leader>ah', '<cmd>Conductor here<cr>', desc = 'Agent sessions (cwd)' },
    { '<leader>ap', '<cmd>Conductor panel<cr>', desc = 'Agent panel (live sessions)' },
    { '<leader>an', '<cmd>Conductor new<cr>', desc = 'Agent new session' },
  },
  opts = {},
}
```

## Usage

| Command | Description |
|---|---|
| `:Conductor sessions` | Pick from all sessions across projects |
| `:Conductor here` | Pick from sessions for the current working directory |
| `:Conductor panel` | Toggle the live sessions sidebar |
| `:Conductor new [name]` | Spawn a new managed agent instance |

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
| `x` | Kill instance and remove it |
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
| `q` | Close the chat view |

Tool calls render as `▶ bash \`echo hi\`` while collapsed; expanding shows the captured output in a fenced code block. Running tools show `…`, failed tools `✗`.

Input bar:

| Key | Action |
|---|---|
| `<CR>` | Send prompt (normal or insert mode) |
| `<S-CR>` | Insert newline |
| `<C-k>` | Focus the log window |
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
  terminal = {
    backend = 'snacks', -- or 'split'
    snacks_win = { position = 'right', width = 0.5 },
  },
}
```
