# OpenCode.nvim

[![Lua](https://img.shields.io/badge/Lua-2C2D72?style=flat-square&logo=lua&logoColor=white)]()
[![Neovim](https://img.shields.io/badge/Neovim-57A143?style=flat-square&logo=neovim&logoColor=white)]()

Neovim frontend for [OpenCode](https://github.com/sst/opencode) - the open source AI coding agent.

> **Status**: Early development - not functional yet

## Features (Planned)

- Chat interface with markdown rendering
- Accumulated diff review system
- Lualine integration
- Fuzzy-searchable command palette
- Interactive permission handling

## Installation

Using [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "wwnbb/opencode.nvim",
  dependencies = {
    "nvim-lua/plenary.nvim",
    "MunifTanjim/nui.nvim",
  },
  config = function()
    require("opencode").setup()
  end,
}
```

## Configuration

```lua
require("opencode").setup({
  server = {
    host = "localhost",
    port = 9099,
  },
  keymaps = {
    toggle = "<leader>oo",
    command_palette = "<leader>op",
  },
})
```

## Commands

| Command | Description |
|---------|-------------|
| `:OpenCode` | Open chat window |
| `:OpenCodeToggle` | Toggle chat window |
| `:OpenCodeClose` | Close chat window |
| `:OpenCodeStart` | Start OpenCode server |
| `:OpenCodeStop` | Stop OpenCode server (if started by plugin) |
| `:OpenCodeRestart` | Restart OpenCode server |

## Lua API

```lua
local opencode = require('opencode')

-- Setup
opencode.setup({
  server = { host = "localhost", port = 9099 },
})

-- Chat control
opencode.toggle()        -- Toggle chat window
opencode.open()          -- Open chat window
opencode.close()         -- Close chat window
opencode.focus()         -- Focus chat window
opencode.send("Hello")   -- Send a message
opencode.clear()         -- Clear chat history

-- Server lifecycle
opencode.start()         -- Start server
opencode.stop()          -- Stop server
opencode.restart()       -- Restart server
opencode.disconnect()    -- Disconnect (keep server running)

-- Events
opencode.on("message", function(data)
  print("New message received")
end)

-- State access
print(opencode.state.get_connection())
print(opencode.state.get_status())
```

## Development

See [SPECIFICATION.md](SPECIFICATION.md) for detailed implementation plan.

## License

MIT
