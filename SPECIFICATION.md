# OpenCode.nvim Specification

A Neovim frontend for OpenCode - the open source AI coding agent.

## Overview

This plugin provides a native Neovim experience for interacting with OpenCode, replicating and extending the TUI functionality within the Neovim ecosystem.

---

## Architecture

### Lazy Initialization

The plugin follows a **lazy initialization** pattern - OpenCode server is NOT started when Neovim opens. Instead, the server is started on-demand when the user first invokes any OpenCode command.

```
┌─────────────────────────────────────────────────────────────┐
│                  Initialization Flow                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. Neovim starts                                           │
│     └─ Plugin loads (registers commands, keymaps)           │
│        └─ NO server started, NO connection made             │
│                                                             │
│  2. User invokes command (toggle, send, palette, etc.)      │
│     └─ Check if server running                              │
│        ├─ If running → connect                              │
│        └─ If not → start server, wait for ready, connect    │
│                                                             │
│  3. Connection established                                  │
│     └─ Create/restore session                               │
│     └─ Start SSE listener                                   │
│     └─ Execute requested command                            │
│                                                             │
│  4. On Neovim exit (optional)                               │
│     └─ Keep server running (for other clients)              │
│     └─ Or shutdown if configured                            │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Communication Layer

OpenCode exposes a REST API with SSE (Server-Sent Events) for real-time updates. The plugin communicates with the OpenCode server via:

```
┌─────────────────────────────────────────────────────────────┐
│                     Neovim Plugin                           │
├─────────────────────────────────────────────────────────────┤
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Chat Buffer  │  │ Diff Viewer  │  │ Command Palette  │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐   │
│  │ Lualine Comp │  │ Notifications│  │ Permission UI    │   │
│  └──────────────┘  └──────────────┘  └──────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                    SDK/Client Layer                         │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  HTTP Client (curl/plenary)  │  SSE Client (async)   │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                   OpenCode Server                           │
│  REST API (Hono) + SSE Events + WebSocket                   │
└─────────────────────────────────────────────────────────────┘
```

### Lifecycle Management

The plugin maintains an internal state machine for server/connection lifecycle:

```lua
-- Internal states
{
  state = "idle",        -- "idle" | "starting" | "connecting" | "connected" | "error"
  server_pid = nil,      -- PID if we started the server
  server_managed = false, -- true if we started it, false if external
}
```

**State Transitions:**

```
     ┌──────────────────────────────────────────────────┐
     │                                                  │
     ▼                                                  │
  [idle] ──(command invoked)──► [starting] ──(ready)──► [connecting]
     ▲                              │                       │
     │                              │                       │
     │                         (timeout/error)          (success)
     │                              │                       │
     │                              ▼                       ▼
     └────────────────────────── [error] ◄───────────── [connected]
                                    │                       │
                                    │                  (disconnect)
                                    │                       │
                                    └───────────────────────┘
```

**Server Detection:**

Before starting a new server, the plugin checks:
1. Is there already a server at `host:port`? (HTTP health check)
2. If yes → connect to existing server (`server_managed = false`)
3. If no → spawn new server process (`server_managed = true`)

**Graceful Handling:**

```lua
-- All public API functions go through ensure_connected()
function M.send(message)
  ensure_connected(function()
    -- Actually send the message
  end)
end

-- ensure_connected handles the lazy init
local function ensure_connected(callback)
  if state.state == "connected" then
    callback()
    return
  end

  if state.state == "idle" then
    start_and_connect(callback)
    return
  end

  if state.state == "starting" or state.state == "connecting" then
    -- Queue callback for when connected
    table.insert(pending_callbacks, callback)
    return
  end

  if state.state == "error" then
    -- Retry or show error
    vim.notify("OpenCode: Connection failed. Retrying...", vim.log.levels.WARN)
    start_and_connect(callback)
  end
end
```

### Core Dependencies

- `plenary.nvim` - Async HTTP requests, job management
- `nui.nvim` - UI components (windows, popups, layouts)
- `telescope.nvim` (optional) - Enhanced picker experience
- `nvim-notify` (optional) - Better notifications

---

## 1. Command Palette (Config Window)

A fuzzy-searchable command palette similar to TUI's `Ctrl+P`.

### Features

| Feature | Description |
|---------|-------------|
| Fuzzy search | Filter commands/actions by typing |
| Frecency sorting | Recently used items appear first |
| Categories | Group items by type (Sessions, Models, Agents, etc.) |
| Preview | Show context for selected item |
| Keybind hints | Display associated keybindings |

### UI Layout

```
┌─ OpenCode Commands ──────────────────────────────┐
│ > search query                                   │
├──────────────────────────────────────────────────┤
│   Sessions                                       │
│     ● Switch Session            <leader>os      │
│     ○ New Session               <leader>on      │
│     ○ Fork Session              <leader>of      │
│   ─────────────────────────────────────────────  │
│   Model                                          │
│     ○ Switch Model              <leader>om      │
│     ○ Switch Provider           <leader>op      │
│   ─────────────────────────────────────────────  │
│   Agent                                          │
│     ○ Switch Agent              <leader>oa      │
│     ○ Switch Mode (build/plan)  <leader>oM      │
│   ─────────────────────────────────────────────  │
│   Actions                                        │
│     ○ Abort Current             <leader>ox      │
│     ○ Compact Session           <leader>oc      │
│     ○ Revert Changes            <leader>or      │
│   ─────────────────────────────────────────────  │
│   MCP                                            │
│     ○ MCP Servers               <leader>oS      │
│     ○ Refresh Tools                             │
└──────────────────────────────────────────────────┘
```

### Commands Available

```lua
-- Session Management
{ name = "Switch Session",     action = "session.list",    category = "Sessions" }
{ name = "New Session",        action = "session.new",     category = "Sessions" }
{ name = "Fork Session",       action = "session.fork",    category = "Sessions" }
{ name = "Delete Session",     action = "session.delete",  category = "Sessions" }
{ name = "Archive Session",    action = "session.archive", category = "Sessions" }

-- Model/Provider
{ name = "Switch Model",       action = "model.switch",    category = "Model" }
{ name = "Switch Provider",    action = "provider.switch", category = "Model" }

-- Agent/Mode
{ name = "Switch Agent",       action = "agent.switch",    category = "Agent" }
{ name = "Switch Mode",        action = "mode.switch",     category = "Agent" }
{ name = "Set Custom Agent",   action = "agent.custom",    category = "Agent" }

-- Actions
{ name = "Abort Request",      action = "request.abort",   category = "Actions" }
{ name = "Compact Messages",   action = "session.compact", category = "Actions" }
{ name = "Revert Changes",     action = "session.revert",  category = "Actions" }
{ name = "Clear Chat",         action = "chat.clear",      category = "Actions" }

-- MCP
{ name = "MCP Servers",        action = "mcp.servers",     category = "MCP" }
{ name = "MCP Tools",          action = "mcp.tools",       category = "MCP" }
{ name = "Refresh MCP",        action = "mcp.refresh",     category = "MCP" }

-- Files
{ name = "View Changed Files", action = "files.changed",   category = "Files" }
{ name = "View Diff",          action = "files.diff",      category = "Files" }

-- Theme
{ name = "Switch Theme",       action = "theme.switch",    category = "UI" }
{ name = "Toggle Sidebar",     action = "sidebar.toggle",  category = "UI" }
```

### Configuration

```lua
{
  command_palette = {
    -- Keybinding to open
    keymap = "<leader>op",

    -- Window appearance
    width = 60,
    height = 20,
    border = "rounded",

    -- Behavior
    frecency = true,           -- Track usage frequency
    show_keybinds = true,      -- Show keybind hints
    show_icons = true,         -- Use icons (requires nerd font)

    -- Categories to show (order matters)
    categories = {
      "Sessions",
      "Model",
      "Agent",
      "Actions",
      "MCP",
      "Files",
      "UI",
    },

    -- Custom commands
    custom_commands = {
      {
        name = "My Custom Action",
        action = function() ... end,
        category = "Custom",
      },
    },
  },
}
```

### Telescope Integration (Optional)

When telescope is available, use it as the picker backend:

```lua
{
  command_palette = {
    backend = "telescope", -- "builtin" | "telescope" | "fzf-lua"
    telescope = {
      theme = "dropdown",
      layout_config = {
        width = 0.5,
        height = 0.6,
      },
    },
  },
}
```

---

## 2. Lualine Integration

Status line component showing OpenCode state.

### Display Modes

**Minimal:**
```
 opencode: claude-sonnet ● streaming
```

**Normal:**
```
 opencode │ claude-sonnet │ build │ ● streaming │ 12 msgs
```

**Expanded:**
```
 opencode │ anthropic/claude-sonnet │ build │ ● streaming │ session: main │ 12 msgs │ +45 -12
```

### Status Indicators

| Icon | State | Description |
|------|-------|-------------|
| ● | `streaming` | Receiving response |
| ◐ | `thinking` | Processing/thinking |
| ◯ | `idle` | Ready for input |
| ⏸ | `paused` | Waiting for permission |
| ✗ | `error` | Error occurred |
| ⊘ | `disconnected` | Server not connected |

### Component Definition

```lua
-- lualine component
require('lualine').setup({
  sections = {
    lualine_x = {
      {
        require('opencode').lualine_component,
        -- or use the table format for more control:
        -- require('opencode.lualine').component
      },
    },
  },
})
```

### Configuration

```lua
{
  lualine = {
    -- Display mode
    mode = "normal", -- "minimal" | "normal" | "expanded"

    -- What to show
    show_model = true,
    show_provider = false,      -- Show provider name
    show_agent = true,          -- Show current agent/mode
    show_status = true,         -- Show streaming/idle status
    show_session = false,       -- Show session name
    show_message_count = true,  -- Show message count
    show_diff_stats = false,    -- Show +/- line counts

    -- Icons (requires nerd font)
    icons = {
      opencode = "",
      streaming = "●",
      thinking = "◐",
      idle = "◯",
      paused = "⏸",
      error = "✗",
      disconnected = "⊘",
      separator = "│",
    },

    -- Colors (linked to highlight groups)
    colors = {
      streaming = "DiagnosticInfo",
      thinking = "DiagnosticWarn",
      idle = "Comment",
      paused = "DiagnosticWarn",
      error = "DiagnosticError",
      disconnected = "Comment",
    },

    -- Click actions
    on_click = function(clicks, button, modifiers)
      if button == "l" then
        require('opencode').toggle_chat()
      elseif button == "r" then
        require('opencode').command_palette()
      end
    end,
  },
}
```

### Standalone Status API

```lua
local opencode = require('opencode')

-- Get current status
local status = opencode.get_status()
-- Returns: {
--   connected = true,
--   state = "streaming", -- "streaming" | "thinking" | "idle" | "paused" | "error"
--   model = "claude-sonnet-4-20250514",
--   provider = "anthropic",
--   agent = "build",
--   session_id = "abc123",
--   session_name = "main",
--   message_count = 12,
--   diff_stats = { additions = 45, deletions = 12 },
-- }

-- Subscribe to status changes
opencode.on_status_change(function(status)
  -- Called whenever status changes
end)
```

---

## 3. Edit/Diff Viewer

Auto-accepts edits to a shadow buffer, providing a browsable diff interface after completion.

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Edit Flow                                │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. OpenCode proposes edit                                  │
│           │                                                 │
│           ▼                                                 │
│  2. Plugin intercepts via SSE event                         │
│           │                                                 │
│           ▼                                                 │
│  3. Store in shadow buffer (not applied to file yet)        │
│           │                                                 │
│           ▼                                                 │
│  4. Auto-accept to server (configurable)                    │
│           │                                                 │
│           ▼                                                 │
│  5. On job complete → Generate diff view                    │
│           │                                                 │
│           ▼                                                 │
│  6. User reviews, accepts/rejects per-file or per-hunk      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### Diff View Layout

```
┌─ Changed Files (3) ─────────────────────────────────────────┐
│  [x] src/main.ts           +23 -5                           │
│  [x] src/utils/helper.ts   +12 -0                           │
│  [ ] tests/main.test.ts    +45 -10                          │
├─────────────────────────────────────────────────────────────┤
│ src/main.ts                                    [Apply] [Skip]│
├─────────────────────────────────────────────────────────────┤
│  10   │     const oldCode = "before";                       │
│  11 - │-    const result = processData(input);              │
│  11 + │+    const result = await processData(input);        │
│  12 + │+    if (!result) {                                  │
│  13 + │+      throw new Error("Processing failed");         │
│  14 + │+    }                                               │
│  15   │     return result;                                  │
├─────────────────────────────────────────────────────────────┤
│ Hunk 1 of 3  │ [Accept Hunk] [Reject Hunk] [Accept All]     │
└─────────────────────────────────────────────────────────────┘
```

### Keybindings in Diff View

| Key | Action |
|-----|--------|
| `j/k` | Navigate files |
| `J/K` | Navigate hunks within file |
| `<CR>` | Toggle file selection |
| `a` | Accept current hunk |
| `x` | Reject current hunk |
| `A` | Accept all hunks in file |
| `X` | Reject all hunks in file |
| `<C-a>` | Accept all changes |
| `<C-x>` | Reject all changes |
| `<Tab>` | Toggle inline/split diff view |
| `p` | Preview file with changes applied |
| `o` | Open original file |
| `q` | Close diff viewer |
| `?` | Show help |

### File Change Tracking

```lua
-- Internal structure for tracking changes
{
  session_id = "abc123",
  changes = {
    ["src/main.ts"] = {
      original = "...",           -- Original content
      modified = "...",           -- Modified content
      hunks = {
        {
          start_line = 10,
          end_line = 15,
          original_lines = {...},
          modified_lines = {...},
          status = "pending",     -- "pending" | "accepted" | "rejected"
        },
      },
      status = "pending",         -- Overall file status
    },
  },
  stats = {
    total_files = 3,
    total_additions = 80,
    total_deletions = 15,
  },
}
```

### Configuration

```lua
{
  diff = {
    -- Auto-accept behavior
    auto_accept = true,          -- Auto-accept edits from server

    -- When to show diff viewer
    show_on_complete = true,     -- Auto-open when job completes
    show_on_edit = false,        -- Show immediately on each edit

    -- View settings
    default_view = "inline",     -- "inline" | "split"
    split_direction = "vertical", -- "vertical" | "horizontal"

    -- File list position
    file_list_position = "top",  -- "top" | "left" | "right"
    file_list_width = 40,        -- Width when left/right
    file_list_height = 8,        -- Height when top

    -- Diff appearance
    context_lines = 3,           -- Lines of context around changes
    show_line_numbers = true,

    -- Highlight groups
    highlights = {
      added = "DiffAdd",
      removed = "DiffDelete",
      changed = "DiffChange",
      hunk_header = "DiffText",
      file_header = "Title",
      selected = "Visual",
    },

    -- Signs in sign column
    signs = {
      added = "+",
      removed = "-",
      changed = "~",
    },

    -- Behavior
    confirm_reject = true,       -- Confirm before rejecting all

    -- Keymaps (within diff view)
    keymaps = {
      next_file = "j",
      prev_file = "k",
      next_hunk = "J",
      prev_hunk = "K",
      toggle_file = "<CR>",
      accept_hunk = "a",
      reject_hunk = "x",
      accept_file = "A",
      reject_file = "X",
      accept_all = "<C-a>",
      reject_all = "<C-x>",
      toggle_view = "<Tab>",
      preview = "p",
      open_original = "o",
      close = "q",
      help = "?",
    },
  },
}
```

### API

```lua
local opencode = require('opencode')

-- Open diff viewer manually
opencode.show_diff()

-- Get pending changes
local changes = opencode.get_pending_changes()

-- Accept/reject programmatically
opencode.accept_file("src/main.ts")
opencode.reject_file("src/main.ts")
opencode.accept_hunk("src/main.ts", 1)
opencode.reject_hunk("src/main.ts", 1)
opencode.accept_all()
opencode.reject_all()

-- Subscribe to edit events
opencode.on_edit(function(edit)
  -- Called for each edit
  -- edit = { file = "...", before = "...", after = "...", diff = "..." }
end)
```

---

## 4. Chat Buffer

The main interaction interface - a configurable buffer for conversation.

### Layout Options

**Vertical Split (Default):**
```
┌─────────────────────────┬──────────────────────────────────┐
│                         │  OpenCode Chat                   │
│                         ├──────────────────────────────────┤
│    Main Editor          │  User: How do I fix this bug?    │
│                         │                                  │
│                         │  Assistant: I can help with      │
│                         │  that. Let me analyze...         │
│                         │                                  │
│                         │  [Tool: read src/main.ts]        │
│                         │                                  │
│                         ├──────────────────────────────────┤
│                         │ > Type your message...           │
└─────────────────────────┴──────────────────────────────────┘
```

**Horizontal Split:**
```
┌────────────────────────────────────────────────────────────┐
│                      Main Editor                           │
├────────────────────────────────────────────────────────────┤
│  OpenCode Chat                                             │
│  User: How do I fix this bug?                              │
│  Assistant: I can help with that...                        │
├────────────────────────────────────────────────────────────┤
│ > Type your message...                                     │
└────────────────────────────────────────────────────────────┘
```

**Floating Window:**
```
┌────────────────────────────────────────────────────────────┐
│                                                            │
│    ┌─ OpenCode Chat ──────────────────────────────┐        │
│    │  User: How do I fix this bug?                │        │
│    │                                              │        │
│    │  Assistant: I can help...                    │        │
│    │                                              │        │
│    ├──────────────────────────────────────────────┤        │
│    │ > Type your message...                       │        │
│    └──────────────────────────────────────────────┘        │
│                                                            │
└────────────────────────────────────────────────────────────┘
```

### Message Rendering

Messages support markdown rendering with syntax highlighting:

```
┌──────────────────────────────────────────────────────────────┐
│  You                                            10:30 AM     │
│  How do I implement a binary search?                         │
├──────────────────────────────────────────────────────────────┤
│  Assistant                                      10:30 AM     │
│  Here's a binary search implementation:                      │
│                                                              │
│  ```typescript                                               │
│  function binarySearch<T>(                                   │
│    arr: T[],                                                 │
│    target: T                                                 │
│  ): number {                                                 │
│    let left = 0;                                             │
│    let right = arr.length - 1;                               │
│    // ...                                                    │
│  }                                                           │
│  ```                                                         │
│                                                              │
│  This algorithm has O(log n) complexity.                     │
├──────────────────────────────────────────────────────────────┤
│  Tool Call: read                                             │
│  ├─ File: src/search.ts                                      │
│  └─ Lines: 1-50                                              │
│  [Expand]                                                    │
├──────────────────────────────────────────────────────────────┤
│  Tool Call: edit                                             │
│  ├─ File: src/search.ts                                      │
│  ├─ Status: ✓ Applied                                        │
│  └─ Changes: +15 -3                                          │
│  [View Diff]                                                 │
└──────────────────────────────────────────────────────────────┘
```

### Input Area

The input area supports multi-line editing with special features:

```
┌─ Input ─────────────────────────────────────────────────────┐
│ > Fix the authentication bug in the login component.        │
│   Make sure to handle the edge case where the user's        │
│   session has expired.                                      │
├─────────────────────────────────────────────────────────────┤
│ [Send: <C-CR>] [Cancel: <Esc>] [Attach: <C-a>] [History: ↑] │
└─────────────────────────────────────────────────────────────┘
```

### Features

- **Context attachment**: Attach current buffer, selection, or files
- **Prompt history**: Navigate previous prompts with up/down
- **Prompt stash**: Save prompts for later (like TUI)
- **Multi-line input**: Natural multi-line editing
- **Markdown rendering**: Proper markdown with code highlighting
- **Collapsible tool calls**: Expand/collapse tool call details
- **Copy support**: Copy code blocks or full messages
- **Scroll sync**: Option to auto-scroll on new content

### Keybindings

**Chat Buffer (Normal Mode):**

| Key | Action |
|-----|--------|
| `q` | Close chat (toggle off) |
| `i` | Focus input area |
| `<CR>` | Expand/collapse tool call under cursor |
| `yy` | Copy current message |
| `yc` | Copy code block under cursor |
| `gd` | Go to file mentioned in tool call |
| `gD` | Open diff for edit tool call |
| `gg` | Go to first message |
| `G` | Go to last message |
| `<C-u>` | Scroll up half page |
| `<C-d>` | Scroll down half page |
| `?` | Show help |

**Input Area (Insert Mode):**

| Key | Action |
|-----|--------|
| `<C-CR>` | Send message |
| `<Esc>` | Exit input / close chat |
| `<C-a>` | Attach file/selection |
| `<Up>` | Previous prompt from history |
| `<Down>` | Next prompt from history |
| `<C-s>` | Stash current prompt |
| `<C-r>` | Restore stashed prompt |
| `<C-c>` | Cancel current request |
| `<C-l>` | Clear input |

### Toggle Functionality

```lua
-- Toggle chat visibility
:OpenCodeToggle

-- Or via Lua
require('opencode').toggle()

-- Specific actions
require('opencode').open()   -- Open if closed
require('opencode').close()  -- Close if open
require('opencode').focus()  -- Focus input area
```

### Configuration

```lua
{
  chat = {
    -- Layout
    layout = "vertical",       -- "vertical" | "horizontal" | "float"
    position = "right",        -- "left" | "right" | "top" | "bottom"
    width = 80,                -- Width for vertical split
    height = 20,               -- Height for horizontal split

    -- Float-specific settings
    float = {
      width = 0.8,             -- Percentage of screen
      height = 0.8,
      border = "rounded",
      title = " OpenCode ",
      title_pos = "center",
    },

    -- Input area
    input = {
      height = 5,              -- Default input height
      max_height = 15,         -- Max height when expanding
      border = "single",
      prompt = "> ",
    },

    -- Message display
    messages = {
      show_timestamps = true,
      timestamp_format = "%H:%M",
      show_role_icons = true,
      role_icons = {
        user = "",
        assistant = "",
        system = "",
      },

      -- Code blocks
      code_block_border = true,
      code_block_highlight = true,

      -- Tool calls
      tool_calls_collapsed = true,  -- Start collapsed
      show_tool_status = true,
    },

    -- Behavior
    auto_scroll = true,        -- Auto-scroll on new content
    focus_on_open = true,      -- Focus input when opened
    close_on_esc = true,       -- Close with Esc in normal mode

    -- History
    prompt_history = {
      enabled = true,
      max_size = 100,
      persist = true,          -- Save between sessions
    },

    -- Context attachment
    context = {
      auto_attach_buffer = false,   -- Auto-attach current buffer
      auto_attach_selection = true, -- Auto-attach visual selection
      show_preview = true,          -- Preview attached content
    },

    -- Keymaps
    keymaps = {
      -- Buffer keymaps
      close = "q",
      focus_input = "i",
      toggle_tool_call = "<CR>",
      copy_message = "yy",
      copy_code = "yc",
      goto_file = "gd",
      goto_diff = "gD",
      scroll_up = "<C-u>",
      scroll_down = "<C-d>",

      -- Input keymaps
      send = "<C-CR>",
      cancel = "<C-c>",
      attach = "<C-a>",
      history_prev = "<Up>",
      history_next = "<Down>",
      stash = "<C-s>",
      restore = "<C-r>",
      clear = "<C-l>",
    },

    -- Highlight groups
    highlights = {
      user_message = "Normal",
      assistant_message = "Normal",
      system_message = "Comment",
      timestamp = "Comment",
      tool_call = "Special",
      tool_status_success = "DiagnosticOk",
      tool_status_error = "DiagnosticError",
      code_block_bg = "CursorLine",
    },
  },
}
```

### API

```lua
local opencode = require('opencode')

-- Send message
opencode.send("Fix the bug in src/main.ts")

-- Send with context
opencode.send("Explain this code", {
  context = {
    { type = "file", path = "src/main.ts" },
    { type = "selection", content = "..." },
  },
})

-- Abort current request
opencode.abort()

-- Get chat history
local messages = opencode.get_messages()

-- Clear chat
opencode.clear()

-- Subscribe to events
opencode.on_message(function(message)
  -- New message received
end)

opencode.on_stream(function(chunk)
  -- Streaming chunk received
end)
```

---

## 5. Permission Handling

Interactive permission prompts within Neovim.

### Permission Dialog

```
┌─ Permission Required ────────────────────────────────────────┐
│                                                              │
│  OpenCode wants to execute a bash command:                   │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐  │
│  │ npm install lodash                                     │  │
│  └────────────────────────────────────────────────────────┘  │
│                                                              │
│  Tool: bash                                                  │
│  Agent: build                                                │
│                                                              │
│  ┌────────────┐ ┌────────────┐ ┌────────────────────────┐    │
│  │  Allow (y) │ │  Deny (n)  │ │ Always Allow (a)       │    │
│  └────────────┘ └────────────┘ └────────────────────────┘    │
│                                                              │
└──────────────────────────────────────────────────────────────┘
```

### Keybindings

| Key | Action |
|-----|--------|
| `y` | Allow this request |
| `n` | Deny this request |
| `a` | Always allow (add to permissions) |
| `d` | Always deny (add to permissions) |
| `e` | Edit command before allowing |
| `?` | Show more details |
| `<Esc>` | Deny and close |

### Configuration

```lua
{
  permissions = {
    -- Auto-handling (use with caution)
    auto_allow = {},           -- Patterns to auto-allow
    auto_deny = {},            -- Patterns to auto-deny

    -- UI
    float = {
      width = 60,
      height = 15,
      border = "rounded",
    },

    -- Behavior
    timeout = nil,             -- Auto-deny after timeout (ms)
    sound = false,             -- Play sound on permission request

    -- Keymaps
    keymaps = {
      allow = "y",
      deny = "n",
      always_allow = "a",
      always_deny = "d",
      edit = "e",
      details = "?",
      close = "<Esc>",
    },
  },
}
```

---

## 6. Global Configuration

Complete plugin configuration structure:

```lua
require('opencode').setup({
  -- Server connection (lazy - only starts on first command)
  server = {
    host = "localhost",
    port = 9099,
    auth = {
      username = "opencode",
      password = nil,          -- Or set via OPENCODE_SERVER_PASSWORD
    },

    -- Lazy initialization (default behavior)
    lazy = true,               -- Don't start on Neovim open
    auto_start = true,         -- Start server on first command if not running
    startup_timeout = 10000,   -- Timeout for server startup (ms)
    health_check_interval = 1000, -- Interval to check if server is ready (ms)

    -- Lifecycle
    shutdown_on_exit = false,  -- Keep server running when Neovim exits
    reuse_running = true,      -- Connect to existing server if running
  },

  -- Default session
  session = {
    auto_create = true,        -- Create session on startup
    auto_restore = true,       -- Restore last session
    default_agent = "build",   -- Default agent
  },

  -- Feature configurations (detailed above)
  command_palette = { ... },
  lualine = { ... },
  diff = { ... },
  chat = { ... },
  permissions = { ... },

  -- Notifications
  notifications = {
    enabled = true,
    provider = "auto",         -- "auto" | "nvim-notify" | "native"
    level = "info",            -- Minimum level to show

    -- Startup notifications
    show_startup = true,       -- Show "Starting OpenCode..." message
    show_connected = true,     -- Show "Connected to OpenCode" message
    startup_spinner = true,    -- Show spinner while starting
  },

  -- Logging
  log = {
    enabled = false,
    level = "warn",            -- "debug" | "info" | "warn" | "error"
    file = vim.fn.stdpath("cache") .. "/opencode.log",
  },

  -- Keymaps
  keymaps = {
    -- Global keymaps
    toggle = "<leader>oo",
    command_palette = "<leader>op",
    show_diff = "<leader>od",
    abort = "<leader>ox",

    -- Disable specific keymaps
    disable = {},
  },
})
```

---

## 7. Commands

Vim commands exposed by the plugin:

| Command | Description |
|---------|-------------|
| `:OpenCode` | Open chat window (starts server if needed) |
| `:OpenCodeToggle` | Toggle chat window (starts server if needed) |
| `:OpenCodeClose` | Close chat window |
| `:OpenCodeSend {msg}` | Send message (starts server if needed) |
| `:OpenCodeAbort` | Abort current request |
| `:OpenCodePalette` | Open command palette (starts server if needed) |
| `:OpenCodeDiff` | Open diff viewer |
| `:OpenCodeSession {name}` | Switch/create session |
| `:OpenCodeModel {model}` | Switch model |
| `:OpenCodeAgent {agent}` | Switch agent |
| `:OpenCodeStatus` | Show status popup |
| `:OpenCodeStart` | Manually start server |
| `:OpenCodeStop` | Stop server (if plugin started it) |
| `:OpenCodeRestart` | Restart server |
| `:OpenCodeLog` | Open log file |

---

## 8. Lua API Reference

```lua
local opencode = require('opencode')

-- Setup
opencode.setup(opts)

-- Chat
opencode.toggle()
opencode.open()
opencode.close()
opencode.focus()
opencode.send(message, opts)
opencode.abort()
opencode.clear()
opencode.get_messages()

-- Session
opencode.session.list()
opencode.session.create(name)
opencode.session.switch(id)
opencode.session.delete(id)
opencode.session.fork()
opencode.session.compact()
opencode.session.revert()

-- Model/Provider
opencode.model.list()
opencode.model.switch(model_id)
opencode.provider.list()
opencode.provider.switch(provider_id)

-- Agent
opencode.agent.list()
opencode.agent.switch(agent_name)
opencode.mode.switch(mode_name)

-- Diff
opencode.diff.show()
opencode.diff.hide()
opencode.diff.accept_all()
opencode.diff.reject_all()
opencode.diff.accept_file(path)
opencode.diff.reject_file(path)
opencode.diff.get_pending()

-- Status
opencode.get_status()
opencode.is_connected()
opencode.is_streaming()

-- Events
opencode.on(event, callback)    -- Subscribe to event
opencode.off(event, callback)   -- Unsubscribe
opencode.once(event, callback)  -- One-time subscription

-- Event types:
-- "status_change" - Status changed
-- "message" - New message
-- "stream" - Streaming chunk
-- "edit" - File edit proposed
-- "permission" - Permission requested
-- "error" - Error occurred
-- "connected" - Connected to server
-- "disconnected" - Disconnected from server

-- UI Components
opencode.command_palette()
opencode.lualine_component  -- For lualine integration

-- Health check
opencode.health.check()

-- Lifecycle (lazy initialization)
opencode.start()            -- Manually start server (usually automatic)
opencode.stop()             -- Stop server (if we started it)
opencode.restart()          -- Restart server
opencode.connect()          -- Connect to running server
opencode.disconnect()       -- Disconnect (keeps server running)
opencode.ensure_connected(cb) -- Ensure connected, then call callback
```

---

## 9. Events System

The plugin emits events that can be subscribed to:

```lua
local opencode = require('opencode')

-- Connection events
opencode.on("connected", function()
  vim.notify("OpenCode connected!")
end)

opencode.on("disconnected", function(reason)
  vim.notify("OpenCode disconnected: " .. reason)
end)

-- Message events
opencode.on("message", function(msg)
  -- msg = { role, content, timestamp, tool_calls }
end)

opencode.on("stream", function(chunk)
  -- chunk = { content, done }
end)

-- Edit events
opencode.on("edit", function(edit)
  -- edit = { file, before, after, diff }
end)

-- Permission events
opencode.on("permission", function(request)
  -- request = { tool, args, ... }
end)

-- Status events
opencode.on("status_change", function(status)
  -- status = { state, model, agent, ... }
end)
```

---

## 10. Health Check

`:checkhealth opencode`

**When not yet started (lazy mode):**
```
opencode: require("opencode.health").check()

OpenCode.nvim ~
- OK Plugin loaded
- OK Lazy mode: server will start on first command
- OK plenary.nvim installed
- OK nui.nvim installed
- WARNING nvim-notify not installed (optional)
- WARNING telescope.nvim not installed (optional)
```

**When connected:**
```
opencode: require("opencode.health").check()

OpenCode.nvim ~
- OK Server running at localhost:9099
- OK Server managed by: plugin (PID: 12345)
- OK Connected to session "main"
- OK Model: claude-sonnet-4-20250514
- OK Agent: build
- OK plenary.nvim installed
- OK nui.nvim installed
- WARNING nvim-notify not installed (optional)
- WARNING telescope.nvim not installed (optional)
```

**When server is external:**
```
opencode: require("opencode.health").check()

OpenCode.nvim ~
- OK Server running at localhost:9099
- OK Server managed by: external process
- OK Connected to session "main"
...
```

---

## File Structure

```
opencode.nvim/
├── lua/
│   └── opencode/
│       ├── init.lua           # Main entry, setup, public API
│       ├── config.lua         # Configuration handling
│       ├── lifecycle.lua      # Server start/stop, lazy init
│       ├── client.lua         # HTTP/SSE client
│       ├── state.lua          # State management
│       ├── events.lua         # Event system
│       │
│       ├── ui/
│       │   ├── chat.lua       # Chat buffer
│       │   ├── input.lua      # Input area
│       │   ├── diff.lua       # Diff viewer
│       │   ├── palette.lua    # Command palette
│       │   ├── permission.lua # Permission dialogs
│       │   └── float.lua      # Float window utils
│       │
│       ├── components/
│       │   ├── lualine.lua    # Lualine component
│       │   └── statusline.lua # Native statusline
│       │
│       ├── actions/
│       │   ├── session.lua    # Session actions
│       │   ├── model.lua      # Model actions
│       │   ├── agent.lua      # Agent actions
│       │   └── mcp.lua        # MCP actions
│       │
│       └── health.lua         # Health check
│
├── plugin/
│   └── opencode.lua           # Plugin loader, commands
│
├── doc/
│   └── opencode.txt           # Help documentation
│
├── SPECIFICATION.md           # This file
└── README.md                  # User documentation
```

---

## Implementation Priority

1. **Phase 1: Core Foundation**
   - HTTP/SSE client
   - State management
   - Basic chat buffer
   - Send/receive messages

2. **Phase 2: Chat Enhancement**
   - Markdown rendering
   - Tool call display
   - Input history
   - Context attachment

3. **Phase 3: Diff System**
   - Edit tracking
   - Diff viewer UI
   - Accept/reject functionality

4. **Phase 4: Integration**
   - Lualine component
   - Command palette
   - Permission handling

5. **Phase 5: Polish**
   - Telescope integration
   - nvim-notify integration
   - Health check
   - Documentation
