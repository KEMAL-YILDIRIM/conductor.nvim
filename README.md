# conductor.nvim

Manage AI agent conversations from Neovim. Discover sessions, preview conversation logs in a telescope picker, and resume them in a terminal.

Currently supports the [pi coding agent](https://github.com/earendil-works/pi-mono); the adapter interface is designed so other harnesses (Claude Code, OpenCode, ...) can be added.

## Status / Roadmap

- **Phase 1 (current)**: session discovery, telescope picker with parsed conversation-log preview, resume in terminal
- **Phase 2**: RPC supervisor — spawn/manage `pi --mode rpc` processes, live sidebar with per-session status (streaming / needs input / idle / error)
- **Phase 3**: in-editor chat view with streaming render
- **Phase 4**: adapter API stabilization, external-session attach, fzf-lua backend

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
  },
  opts = {},
}
```

## Usage

| Command | Description |
|---|---|
| `:Conductor sessions` | Pick from all sessions across projects |
| `:Conductor here` | Pick from sessions for the current working directory |

In the picker:

- `<CR>` — resume the session in a terminal (`pi --session <path>`)
- `<C-o>` — open the raw session `.jsonl` file

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
    preview_max_entries = 200,
    preview_max_lines_per_entry = 20,
  },
  terminal = {
    backend = 'snacks', -- or 'split'
    snacks_win = { position = 'right', width = 0.5 },
  },
}
```
