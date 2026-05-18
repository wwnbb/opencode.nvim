# OpenCode.nvim

[![Lua](https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)]()
[![Neovim](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)]()

Neovim frontend for [OpenCode](https://github.com/sst/opencode) - the open source AI coding agent.

> **Status**: Early development - not functional yet

## Mapping Helpers

```lua
local opencode = require("opencode")
local keyset = vim.keymap.set

keyset("n", "<leader>oe", opencode.add_current_line_and_open_input, {
	desc = "OpenCode add line + open input",
})
keyset("x", "<leader>oe", opencode.add_visual_selection_and_open_input, {
	desc = "OpenCode add selection + open input",
})

keyset("n", "<leader>oa", opencode.add_current_line, { desc = "OpenCode add line" })
keyset("x", "<leader>oa", opencode.add_visual_selection, { desc = "OpenCode add selection" })
```

## Danger Mode

Danger mode auto-approves permission requests while it is enabled. It replies with `once` for each request, so approvals are not persisted after you disable the mode.

```vim
:OpenCodeDangerMode on
:OpenCodeDangerMode off
:OpenCodeDangerMode toggle
```

```lua
require("opencode").setup({
	danger_mode = false,
})
```

## Lualine Component

The lualine component stays compact: `◈2` means two chats need user attention. When your current working
directory is inside a git repository, it can also show changed line counts like `+100 -20`. Additions use
`OpenCodeLualineDiffAdd`; deletions use `OpenCodeLualineDiffDelete`.

```lua
require("opencode").setup({
	lualine = {
		show_attention = true,
		attention_icon = "◈",
		show_diff_stats = true,
		diff_stats_cache_ms = 2000,
	},
})
```

## Testing

Install pinned local Neovim test dependencies once:

```sh
./scripts/bootstrap-test-deps.sh
```

Run all headless checks, including the chat tab integration scenario:

```sh
./scripts/test-headless.sh
```

## Session Tabs

Session tabs are shown above the chat when multiple sessions are active. Their colors can be configured under
`chat.session_tabs.colors`; omit any value to keep the colorscheme-derived default for that part.

Use `x` in the chat buffer or `:OpenCodeCloseSession` to close the current active tab without deleting the
underlying OpenCode session. The session can still be resumed later from the session list.

Use `gt`/`gT` to move between session tabs. Use `Ngt` to jump to a tab by index, such as `5gt`, and `0gt` to
jump to the first tab.

```lua
require("opencode").setup({
	chat = {
		session_tabs = {
			colors = {
				active_fg = "#ffffff",
				active_bg = "#3b82f6",
				inactive_fg = "#9ca3af",
				inactive_bg = "#1f2937",
				running_fg = "#22c55e",
				waiting_fg = "#f59e0b",
				error_fg = "#ef4444",
				idle_fg = "#6b7280",
			},
		},
	},
})
```
