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
