# OpenCode.nvim Implementation Plan

Generated: 2026-02-01

## Overview

OpenCode.nvim is a Neovim frontend for OpenCode - the open source AI coding agent. This document tracks the implementation progress and remaining tasks.

---

## Phase 1: Core Foundation [COMPLETED]

### Task 1: HTTP/SSE Client Module [DONE]
**Files Created:**
- `lua/opencode/client/http.lua` - Async HTTP client using plenary.curl
- `lua/opencode/client/sse.lua` - Server-Sent Events client with auto-reconnect
- `lua/opencode/client/init.lua` - Unified client API

**Features:**
- GET, POST, PATCH, PUT, DELETE HTTP methods
- JSON request/response handling
- Basic authentication support
- SSE event parsing and pub/sub
- Auto-reconnect with configurable delay
- Health check endpoint

### Task 2: State Management Module [DONE]
**Files Created:**
- `lua/opencode/state.lua` - Centralized state store

**Features:**
- Connection state tracking (idle/starting/connecting/connected/error)
- Server info (PID, managed flag, host, port, version)
- Session tracking (ID, name, message count)
- Model/Provider tracking
- Agent/Mode tracking
- Status management (idle/streaming/thinking/paused/error)
- Pending changes tracking for diffs
- Event subscription system for state changes

### Task 3: Lifecycle Management (Lazy Init) [DONE]
**Files Created:**
- `lua/opencode/lifecycle.lua` - Server lifecycle management

**Features:**
- Lazy initialization (server starts on first command)
- `ensure_connected(callback)` pattern
- Server detection (check for existing server)
- Process management (spawn, PID tracking, kill)
- Startup timeout and health check polling
- Auto-shutdown on vim exit (configurable)
- Connection state machine

### Task 4: Event System [DONE]
**Files Created:**
- `lua/opencode/events.lua` - Pub/sub event bus

**Features:**
- `on()`, `once()`, `off()`, `emit()` API
- Event history tracking (last 100 events)
- State bridge (state changes → events)
- SSE bridge (server events → local events)
- Event types: connected, disconnected, message, status_change, etc.

### Task 5: Basic Chat Buffer UI [DONE]
**Files Created:**
- `lua/opencode/ui/chat.lua` - Chat interface

**Features:**
- Multiple layouts: vertical, horizontal, float
- Message display with role, timestamp, content
- Buffer management (create, open, close, toggle)
- Keymaps: q (close), i (focus input), scroll, help
- Help popup with key reference
- Auto-scroll on new messages

**Updated Files:**
- `lua/opencode/init.lua` - Integrated all modules
- `plugin/opencode.lua` - Added commands: OpenCodeStart, OpenCodeStop, OpenCodeRestart
- `test.lua` - Test configuration with leader=comma
- `test.sh` - Test script with dependency detection
- `README.md` - Updated with API documentation

---

## Phase 2: Chat Enhancement [IN PROGRESS]

### Task 6: Input Area with History [DONE]
**File Created:**
- `lua/opencode/ui/input.lua`

**Features Implemented:**
- Multi-line text input with popup interface
- Prompt history navigation (↑/↓ keys)
- Stash/restore prompts (<C-s>/<C-r>)
- Send message on <C-CR>, cancel on <Esc>
- History persistence to JSON file
- Visual indicators in popup border

**Updated Files:**
- `lua/opencode/ui/chat.lua` - Integrated `focus_input()` function
- `lua/opencode/init.lua` - Added `M.focus_input()` API
- `lua/opencode/config.lua` - Added input configuration section

### Task 7: Markdown Rendering for Messages [DONE]
**File Created:**
- `lua/opencode/ui/markdown.lua`

**Features Implemented:**
- Parse markdown (headers, lists, code blocks, blockquotes)
- Syntax highlighting for code blocks (treesitter + fallback)
- Inline code styling
- Visual code block rendering with borders
- Auto-detection of markdown in messages

**Updated Files:**
- `lua/opencode/ui/chat.lua` - Integrated markdown rendering in message display
- `lua/opencode/config.lua` - Added markdown configuration section

### Task 8: Tool Call Display/Interaction [DONE]
**File Created:**
- `lua/opencode/ui/tools.lua`

**Features Implemented:**
- Tool call cards with icons and status indicators
- Collapsible details (toggle with Enter)
- Status tracking: pending, running, success, error
- Go to file (gd) and view diff (gD) keymaps
- Support for multiple tool call formats
- Tool call state management

**Updated Files:**
- `lua/opencode/ui/chat.lua` - Integrated tool call rendering, added add_tool_call/update_tool_call functions
- `lua/opencode/config.lua` - Added tools configuration section

### Task 9: Context Attachment [DONE]
**File Created:**
- `lua/opencode/context.lua`

**Features Implemented:**
- Attach current buffer with `M.attach_buffer()`
- Attach visual selection with `M.attach_selection()`
- Attach file with `M.attach_file(filepath)`
- Preview attachments with popup
- Compile attachments for message context
- Support for excluded patterns and file type filtering

**API Functions:**
- `M.add(attachment)` - Add attachment to list
- `M.remove(id)` - Remove attachment by ID
- `M.clear()` - Clear all attachments
- `M.get_all()` - Get all attachments
- `M.compile_for_message()` - Format for message sending

---

## Phase 3: Diff System [IN PROGRESS]

### Task 10: Edit Tracking State [DONE]
**File Created:**
- `lua/opencode/artifact/changes.lua`

**Features Implemented:**
- Store original/modified content with backup system
- Hunk tracking with status per hunk
- Stats calculation (+/- lines, modified count)
- Accept/reject state management
- File backup before applying changes
- Confirmation prompts for sensitive files
- Status tracking: pending, accepted, rejected, applied, failed, conflict

**API Functions:**
- `M.add_change(filepath, original, modified)` - Add new change
- `M.accept(id)` - Apply change to file
- `M.reject(id)` - Mark change as rejected
- `M.get_all()` - Get all tracked changes
- `M.get_stats()` - Get summary statistics

### Task 11: Diff Viewer UI
**Description:** Three-panel diff interface
**Files to Create:**
- `lua/opencode/ui/diff.lua`
- `lua/opencode/ui/float.lua` (shared utilities)

**Features:**
- File list panel (top/left/right)
- Diff content panel
- Inline and split diff views
- Hunk navigation

### Task 12: Accept/Reject Functionality
**Description:** Apply or discard changes
**Files to Modify:**
- `lua/opencode/artifact/changes.lua`
- `lua/opencode/ui/diff.lua`

**Features:**
- Accept/reject per hunk (a/x)
- Accept/reject per file (A/X)
- Accept/reject all (<C-a>/<C-x>)
- File backup before apply
- Confirm destructive operations

---

## Phase 4: Integration [PENDING]

### Task 13: Lualine Component
**Description:** Status line integration
**Files to Create:**
- `lua/opencode/components/lualine.lua`

**Features:**
- Three display modes (minimal/normal/expanded)
- Status icons (streaming/thinking/idle/error)
- Model/agent info display
- Message count
- Click actions

### Task 14: Command Palette UI
**Description:** Fuzzy-searchable command picker
**Files to Create:**
- `lua/opencode/ui/palette.lua`

**Features:**
- Categories (Sessions, Model, Agent, Actions, MCP)
- Frecency sorting
- Keybind hints
- Telescope integration (optional)

### Task 15: Permission Handling Dialogs
**Description:** Interactive permission prompts
**Files to Create:**
- `lua/opencode/ui/permission.lua`

**Features:**
- Tool permission dialogs
- Allow/deny/always options
- Command preview
- Timeout handling

### Task 16: Actions (Session/Model/Agent/MCP)
**Description:** Action handlers for command palette
**Files to Create:**
- `lua/opencode/actions/session.lua`
- `lua/opencode/actions/model.lua`
- `lua/opencode/actions/agent.lua`
- `lua/opencode/actions/mcp.lua`

**Features:**
- Session: list, switch, create, fork, delete
- Model: list, switch providers
- Agent: list, switch, set mode
- MCP: servers, tools, refresh

---

## Phase 5: Polish [PENDING]

### Task 17: Telescope Integration
**Description:** Use telescope as picker backend
**Files to Modify:**
- `lua/opencode/ui/palette.lua`

**Features:**
- Telescope picker for command palette
- Category previews
- Frecency integration

### Task 18: nvim-notify Integration
**Description:** Enhanced notifications
**Files to Create:**
- `lua/opencode/notify.lua`

**Features:**
- Use nvim-notify when available
- Fallback to vim.notify
- Styled notifications for events

### Task 19: Health Check Module
**Description:** :checkhealth support
**Files to Create:**
- `lua/opencode/health.lua`

**Features:**
- Dependency checks (plenary, nui)
- Server connection check
- Session status
- Configuration validation

### Task 20: Documentation
**Description:** Complete documentation
**Files to Create/Update:**
- `doc/opencode.txt` - Vim help documentation
- `README.md` - Update with full usage

**Features:**
- API reference
- Configuration examples
- Troubleshooting guide

---

## Current Status Summary

**Completed:** 10/20 tasks (50%)
**Current Phase:** Phase 3 (Diff System) - IN PROGRESS
**Next Phase:** Continue Phase 3 with Task 11 (Diff Viewer UI)

### Files Structure
```
opencode.nvim/
├── lua/opencode/
│   ├── init.lua              # Main entry, public API
│   ├── config.lua            # Configuration defaults
│   ├── state.lua             # State management [DONE]
│   ├── lifecycle.lua         # Lazy initialization [DONE]
│   ├── events.lua            # Event system [DONE]
│   ├── client/
│   │   ├── init.lua          # Combined client [DONE]
│   │   ├── http.lua          # HTTP client [DONE]
│   │   └── sse.lua           # SSE client [DONE]
│   ├── ui/
│   │   ├── chat.lua          # Chat UI [DONE]
│   │   ├── input.lua         # Input area [DONE]
│   │   ├── markdown.lua      # Markdown rendering [DONE]
│   │   ├── tools.lua         # Tool call display [DONE]
│   │   └── diff.lua          # Diff viewer [TODO]
│   │   └── palette.lua       # Command palette [TODO]
│   │   └── permission.lua    # Permission dialogs [TODO]
│   ├── context.lua           # Context attachment [DONE]
  │   ├── artifact/
  │   │   └── changes.lua       # Edit tracking [DONE]
│   ├── actions/
│   │   └── session.lua       # Session actions [TODO]
│   │   └── model.lua         # Model actions [TODO]
│   │   └── agent.lua         # Agent actions [TODO]
│   │   └── mcp.lua           # MCP actions [TODO]
│   └── components/
│       └── lualine.lua       # Lualine component [TODO]
├── plugin/
│   └── opencode.lua          # Plugin loader, commands
├── test.lua                  # Test configuration
├── test.sh                   # Test script
└── IMPLEMENTATION_PLAN.md    # This file
```

---

## Dependencies

**Required:**
- `nvim-lua/plenary.nvim` - HTTP client, jobs
- `MunifTanjim/nui.nvim` - UI components

**Optional:**
- `nvim-telescope/telescope.nvim` - Enhanced picker
- `rcarriga/nvim-notify` - Better notifications

---

## Testing

Run tests with:
```bash
./test.sh                    # With test.lua config (leader=comma)
./test.sh --minimal          # Minimal setup
./test.sh --help             # Show help
```

Test configuration sets:
- `mapleader = ","`
- `<leader>ot` to toggle OpenCode

---

## API Quick Reference

```lua
local opencode = require('opencode')

-- Setup
opencode.setup({
  server = { host = "localhost", port = 9099 },
})

-- Chat
opencode.toggle()        -- Toggle chat
opencode.open()          -- Open chat
opencode.close()         -- Close chat
opencode.send("hello")   -- Send message
opencode.clear()         -- Clear chat

-- Server
opencode.start()         -- Start server
opencode.stop()          -- Stop server
opencode.restart()       -- Restart server

-- Events
opencode.on("message", function(data) ... end)
opencode.once("connected", function() ... end)

-- State
print(opencode.state.get_connection())
print(opencode.state.get_status())
```

---

## Next Steps

1. Implement Task 6: Input Area with History
2. Implement Task 7: Markdown Rendering
3. Connect input to chat for sending messages
4. Implement message streaming display

Ready to begin Phase 2!
