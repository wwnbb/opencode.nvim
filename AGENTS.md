# AGENTS.md — Development Guide for opencode.nvim

## What This Plugin Is

opencode.nvim is a **Neovim frontend** for [OpenCode 2.0.11+](https://github.com/sst/opencode).
It communicates with the native `/api` REST endpoints and `/api/event` SSE stream.

**Stack**: Lua, nui.nvim (UI), plenary.nvim (jobs), libuv (TCP transport)

---

## Quick Reference — File Map

```
docs/                                → Reference TUI implementation and OpenCode server source code
plugin/opencode.lua                  → Entry point (loads commands.lua)
lua/opencode/init.lua                → Public API (setup, toggle, send, etc.)
lua/opencode/config.lua              → Default config + merge()
lua/opencode/state.lua               → Centralized app state + change listeners
lua/opencode/sync.lua                → Message/part/session data store (binary search)
lua/opencode/actions.lua             → Internal action boundary (UI modules call this)
lua/opencode/session.lua             → Session management + status mirroring
lua/opencode/selectors.lua           → Read-only derived state queries
lua/opencode/local.lua               → Agent/model/variant selection (persistent)
lua/opencode/lifecycle.lua           → Server spawn, health checks, reconnect
lua/opencode/events.lua              → Event system facade
lua/opencode/cleanup.lua             → Reset/teardown orchestration across modules
lua/opencode/commands.lua            → User commands and default loader keymaps
lua/opencode/send.lua                → Send-flow orchestration for prompts
lua/opencode/events/bus.lua          → Pub/sub event bus
lua/opencode/events/sse_bridge.lua   → Native SSE envelope → local event bus
lua/opencode/events/state_bridge.lua → State ↔ event bridge
lua/opencode/events/util.lua         → Event utilities (error dedupe, helpers)
lua/opencode/events/handlers/*.lua   → Native v2 reducers, interaction/review recovery, sync, notifications
lua/opencode/events/handlers/permission_flow/*.lua → Permission request and review helpers
lua/opencode/client/init.lua         → Combined HTTP + SSE client API
lua/opencode/client/http.lua         → REST client (GET/POST/PATCH/PUT/DELETE)
lua/opencode/client/sse.lua          → SSE streaming client with reconnect
lua/opencode/client/transport.lua    → Raw libuv TCP transport
lua/opencode/client/http_decoder.lua → Streaming HTTP response decoder
lua/opencode/client/tcp_connection.lua → Shared libuv TCP connection lifecycle
lua/opencode/slash.lua               → Slash command system (/new, /models, etc.)
lua/opencode/logger.lua              → Debug logging
lua/opencode/clipboard.lua           → Clipboard helpers (text + images)
lua/opencode/components/lualine.lua  → Lualine statusline component
lua/opencode/ui/chat/init.lua        → Main chat window (layout, session tabs)
lua/opencode/ui/chat/keymaps.lua     → Buffer keymap setup (moved out of init.lua)
lua/opencode/ui/chat/state.lua       → Chat view-layer state (bufnr, winid, widgets)
lua/opencode/ui/chat/render.lua      → Pure NuiLine rendering helpers
lua/opencode/ui/chat/render_coordinator.lua → Render scheduling
lua/opencode/ui/chat/render_context.lua → Render context (NuiLine accumulation)
lua/opencode/ui/chat/render_state.lua → Render scratch state
lua/opencode/ui/chat/highlights.lua   → Chat extmark highlight application (extracted from render.lua)
lua/opencode/ui/chat/widget_support.lua → Widget cursor tracking
lua/opencode/ui/chat/widget_index.lua → Widget assembly/indexing
lua/opencode/ui/chat/widget_renderer.lua → Widget rendering dispatch
lua/opencode/ui/chat/message_renderer.lua → Message rendering
lua/opencode/ui/chat/messages.lua    → Message line rendering
lua/opencode/ui/chat/tool_renderer.lua → Tool/task block rendering
lua/opencode/ui/chat/tool_panel.lua  → Shared panel rendering helpers
lua/opencode/ui/chat/nav.lua         → Subagent navigation
lua/opencode/ui/chat/session_tabs.lua → Session tab management
lua/opencode/ui/chat/cursor.lua      → Cursor context capture/restore for widgets
lua/opencode/ui/chat/interactions.lua → Widget interaction dispatchers (question/permission/edit)
lua/opencode/ui/chat/float_focus.lua → Float focus helpers (edits/diffs)
lua/opencode/ui/chat/help.lua        → Help popup
lua/opencode/ui/chat/bash.lua        → Bash tool widget
lua/opencode/ui/chat/read.lua        → Read tool widget
lua/opencode/ui/chat/rg.lua          → Ripgrep tool widget
lua/opencode/ui/chat/search.lua      → Search tool widget
lua/opencode/ui/chat/skill.lua       → Skill tool widget
lua/opencode/ui/chat/tasks.lua       → Task/subagent widget
lua/opencode/ui/chat/task_animation.lua → Task spinner animation frames/timer
lua/opencode/ui/chat/task_children.lua → Task → child-session ID resolution
lua/opencode/ui/chat/activity.lua    → Thought/Explore rendering
lua/opencode/ui/chat/tool_labels.lua → Tool label/duration formatting
lua/opencode/ui/chat/tool_part.lua   → Tool part resolution (cursor/position lookups)
lua/opencode/ui/chat/questions.lua   → Question widget
lua/opencode/ui/chat/permissions.lua → Permission widget
lua/opencode/ui/chat/edits.lua       → Edit tool widget + inline diff
lua/opencode/ui/chat/edit_previews.lua → Edit preview rendering
lua/opencode/ui/chat/file_edit_results.lua → File edit results
lua/opencode/ui/input.lua            → Multi-line input with history
lua/opencode/ui/input/*.lua          → Input submodules (attachments, autocmds, autocomplete, history, info_bar, keymaps, layout, mentions, popups, slash_commands)
lua/opencode/ui/palette.lua          → Command palette (fuzzy search)
lua/opencode/ui/palette/*.lua        → Palette command submodules (session, model, agent, actions, prompt, mcp, system)
lua/opencode/ui/float.lua            → Float utilities (centered popups, menus)
lua/opencode/ui/float_context.lua    → Floating window placement and focus helpers
lua/opencode/ui/menu.lua             → Shared list and searchable menu controller
lua/opencode/ui/highlights.lua       → Shared UI highlight defaults
lua/opencode/ui/panel.lua            → Panel line helpers
lua/opencode/ui/spinner.lua          → Loading spinner
lua/opencode/ui/syntax.lua           → Treesitter syntax highlighting
lua/opencode/ui/native_diff.lua      → Native diff viewer
lua/opencode/ui/active_sessions.lua  → Active sessions UI
lua/opencode/ui/log_viewer.lua       → Log viewer
lua/opencode/ui/question_widget.lua  → Question widget renderer
lua/opencode/ui/permission_widget.lua → Permission widget renderer
lua/opencode/ui/edit_widget.lua      → Edit widget renderer
lua/opencode/ui/widget_base.lua      → Widget base class
lua/opencode/permission/state.lua    → Permission request state
lua/opencode/permission/danger.lua   → Danger mode auto-approval
lua/opencode/question/state.lua      → Question request state
lua/opencode/edit/state.lua          → Edit review state
lua/opencode/artifact/changes.lua    → Change tracking
lua/opencode/provider/state.lua      → Transient provider auth state
lua/opencode/session/*.lua           → Session submodules (lock, navigation, pending, status, view)
lua/opencode/util/session.lua        → Session title helpers
lua/opencode/util/locale.lua         → Duration/titlecase formatting
lua/opencode/util/text.lua           → Text utilities
lua/opencode/util/schedule.lua       → vim.schedule wrapper helpers
```

---

## Data Flow

```
User Input
  → init.lua (public API)
    → client/http.lua → OpenCode Server

OpenCode Server
  → /api/event SSE stream → client/sse.lua
    → events/sse_bridge.lua (forwards native v2 envelopes)
      → events/bus.lua (pub/sub)
        → events/handlers/v2.lua and interaction/review handlers
          → sync.lua (message/part store)
          → state.lua (app state)
          → session.lua (session mutations)
            → events emit "chat_render"
              → ui/chat/render_coordinator.lua
                → ui/chat/render.lua (pure NuiLine rendering)
                  → Buffer update
```

---

## Architecture Rules

### State Ownership

| Module | Owns | Mutates Via |
--------|------|-------------|
| `state.lua` | connection, server, session, model, agent, status, danger_mode | `set_*()` functions |
| `sync.lua` | messages, parts, session_status, providers, agents | `handle_*()` functions |
| `local.lua` | agent/model/variant selection, recent/favorite models | `.agent.set()`, `.model.set()`, `.variant.set()` |
| `ui/chat/state.lua` | bufnr, winid, widget positions, expanded state | Direct mutation |
| `permission/state.lua` | Permission requests | `add()`, `resolve()` |
| `question/state.lua` | Question requests | `add()`, `resolve()` |
| `edit/state.lua` | Edit reviews | `add()`, `resolve()` |

**Rule**: UI modules never mutate `state.lua` or `sync.lua` directly. They call `actions.lua` → `init.lua` or emit events.

### Module Dependency Direction

```
init.lua ← actions.lua ← ui/*
init.lua → lifecycle.lua → client/*
init.lua → events.lua → events/handlers/* → sync.lua, state.lua, session.lua
ui/chat/* → sync.lua (read only), state.lua (read only), selectors.lua (read only)
```

**Rule**: UI modules import `actions.lua`, not `init.lua` directly. They read state via `state.lua`/`sync.lua`/`selectors.lua`.

---

## Development Patterns

### Adding a New Feature

1. **Identify the layer**: API? State? Event handler? UI widget?
2. **Follow existing patterns**: Look at similar modules first
3. **State changes**: Add to `state.lua` with `set_*()` + change listeners
4. **Server data**: Add to `sync.lua` with `handle_*()` functions
5. **Events**: Add handler in `events/handlers/`, register in `events.lua`
6. **UI**: Add widget in `ui/chat/`, register in `ui/chat/init.lua`
7. **Commands**: Register in `commands.lua` (vim commands) or `palette.lua` (fuzzy) or `slash.lua` (slash)

### Adding a New Tool Widget

1. Create `lua/opencode/ui/chat/<tool_name>.lua`
2. Use `render.add_panel_line()` or `render.add_panel_raw_line()` for consistent styling
3. Track position in `ui/chat/state.lua` (`state.tools[part_id] = { start_line, end_line }`)
4. Register expand/collapse in `ui/chat/tasks.lua` or `ui/chat/init.lua`
5. Add keymaps in `setup_buffer()` in `ui/chat/init.lua`

**Pattern to follow**: See `ui/chat/bash.lua` or `ui/chat/read.lua`

### Adding a New Command Palette Command

In `ui/palette.lua`, add to `register_defaults()`:

```lua
M.register({
    id = "category.action_name",
    title = "Action Title",
    description = "What it does",
    category = "session", -- session|model|agent|actions|prompt|mcp|files|navigation|system
    keybind = "<leader>ox", -- optional
    action = function()
        -- implementation
    end,
    enabled = function() -- optional
        return true
    end,
})
```

### Adding a New Slash Command

In `slash.lua`, add to `register_defaults()`:

```lua
M.register({
    name = "commandname",
    aliases = { "alias1", "alias2" }, -- optional
    description = "What it does",
    category = "session",
    handler = function(args, parsed)
        -- implementation
    end,
    enabled = function() -- optional
        return true
    end,
})
```

### Adding a New Event

1. Native server event: Handle its `type` and `data` in `events/handlers/v2.lua` or the relevant native interaction handler.
2. Local event: Emit via `events.emit("event_name", data)`.
3. Handler: Create `events/handlers/<name>.lua` with `setup(events)` and register it in `events.lua`.

### Adding State

1. Add field to internal `state` table in `state.lua`
2. Create `set_*()` and `get_*()` functions
3. Call `emit_change()` on mutation
4. Add to `get_status_summary()` if needed for lualine/palette
5. Add to `reset()` if needed for cleanup

---

## UI Consistency Rules

### Rendering

- **Always use `render.add_panel_line()`** for tool/widget output blocks
- **Always use `render.add_panel_raw_line()`** for pre-formatted text
- **Prefix convention**: `"▏  "` for content, `"▏"` for blank lines
- **Width**: Use `render.get_chat_text_width()` for line wrapping
- **Highlights**: Use extmarks with `chat_hl_ns` namespace

### NuiLine Pattern

```lua
local NuiLine = require("nui.line")
local NuiText = require("nui.text")

local line = NuiLine()
line:append(NuiText("prefix", "HighlightGroup"))
line:append(NuiText(" content", "Normal"))
```

### Highlight Groups

- `OpenCodeUserMessageBg`: User message background (links to CursorLine)
- `OpenCodeInputBorder`: Input border (links to Special)
- `OpenCodeInputBorderAgent`: Dynamic per-agent border color
- `OpenCodeInputAgent`: Agent name in info bar
- `OpenCodeInputModel`: Model name in info bar
- `OpenCodeInputProvider`: Provider name in info bar
- `OpenCodeInputVariant`: Variant name in info bar
- `OpenCodeWinbar*`: Session tab highlights
- `OpenCodeLualine*`: Lualine component highlights
- `OpenCodeHiddenCursor`: Hidden cursor in chat buffer

### Widget Interaction Pattern

```lua
-- Track position in state
state.tools[part_id] = { start_line = line_nr, end_line = end_nr, tool_part = part }

-- Cursor-driven selection (CursorMoved autocmd)
vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = bufnr,
    callback = function()
        M.sync_widget_selection_from_cursor()
    end,
})

-- Keymaps check widget at cursor before default behavior
vim.keymap.set("n", "<CR>", function()
    local edit_id = chat_edits.get_edit_at_cursor()
    if edit_id then
        chat_edits.handle_edit_accept_file()
    else
        -- default behavior
    end
end, opts)
```

### Float Window Pattern

```lua
local float = require("opencode.ui.float")

-- Centered popup
local popup, bufnr = float.create_centered_popup({
    width = 60,
    height = 20,
    title = " Title ",
})
popup:mount()
float.setup_close_keymaps(bufnr, function() popup:unmount() end)

-- Searchable menu
float.create_searchable_menu(items, function(item)
    -- handle selection
end, { title = " Select ", width = 50 })

-- Input popup
float.create_input_popup({
    title = " Input ",
    prompt = "Enter value:",
    on_submit = function(value) end,
})
```

---

## Server Communication

### HTTP Client

```lua
local client = require("opencode.client")

client.list_sessions({ roots = true, limit = 100 }, function(err, sessions) end)
client.get_messages(id, { limit = 100 }, function(err, messages) end)
client.send_message(id, { parts = {...} }, function(err, response) end)
```

### SSE Events

```lua
client.on_event("*", function(event_type, data) end) -- native envelope via data._v2_envelope
```

### Key API Endpoints

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/info` | GET | Server info and health |
| `/api/event` | GET | Native SSE stream |
| `/api/session` | GET/POST | List or create sessions |
| `/api/session/:id/message` | GET | Read message history |
| `/api/session/:id/prompt` | POST | Send a prompt |
| `/api/session/:id/interrupt` | POST | Interrupt generation |
| `/api/session/:id/diff` | GET | Get diff |
| `/api/session/:id/revert/stage` | POST | Stage revert |
| `/api/session/:id/permission/:requestID/reply` | POST | Reply to permission |
| `/api/session/:id/form/:formID/reply` | POST | Reply to form |
| `/api/provider`, `/api/agent`, `/api/skill` | GET | Catalogs |

---

## Testing

```sh
./scripts/bootstrap-test-deps.sh    # Install pinned test dependencies
./tests/run.sh                     # Run all Plenary/Busted specs
./tests/run.sh unit                # Run unit specs
./tests/run.sh smoke               # Run smoke specs
./tests/run.sh checks              # Run architecture/state guardrails
```

---

## Installation (for reference)

```lua
-- lazy.nvim
{
  "opencode.nvim",
  dependencies = { "MunifTanjim/nui.nvim", "nvim-lua/plenary.nvim" },
  config = function()
    require("opencode").setup({
      server = { auto_start = true },
      session = { default_agent = "build" },
      chat = { layout = "vertical", position = "right", width = 80 },
      keymaps = { toggle = "<leader>oo", command_palette = "<leader>op" },
    })
  end,
}
```

---

## Keymaps Reference

### Chat Buffer (Normal Mode)

| Key | Action |
|-----|--------|
| `q` | Close chat |
| `i` | Focus input |
| `<C-c>` | Abort generation |
| `<C-p>` | Command palette |
| `N` | New session |
| `x` | Close session tab |
| `gt` / `gT` | Next / previous session |
| `Ngt` | Go to session N |
| `O` | Toggle tool/task expand |
| `gd` | Enter subagent output |
| `<BS>` | Go back to parent session |
| `j` / `k` | Navigate widgets |
| `<CR>` | Confirm widget selection |
| `<Space>` | Toggle multi-select |
| `<Tab>` / `<S-Tab>` | Next / prev question tab |
| `1-9` | Select option by number |
| `<C-a>` | Accept edit (at cursor) |
| `<C-x>` | Reject edit (at cursor) |
| `<C-m>` | Resolve edit manually |
| `=` | Toggle inline diff |
| `A` / `X` / `M` | Accept / reject / resolve all edits |
| `dt` / `dv` | Diff in tab / vsplit |
| `a` | Toggle auto-scroll |
| `?` | Show help |

### Input Mode

| Key | Action |
|-----|--------|
| `<C-g>` | Send message |
| `<C-x><C-s>` | Send message (alt) |
| `<Esc>` | Cancel |
| `<C-t>` | Cycle variant |
| `<C-a>` | Cycle agent |
| `<C-e>` | Cycle model |
| `<Up>` / `<Down>` | History navigation |

---

## Common Pitfalls

1. **Don't import `init.lua` from UI modules** — Use `actions.lua` instead
2. **Don't mutate state directly** — Use `set_*()` functions that emit change events
3. **Don't create NuiLine without wrapping** — Use `render.wrap_text()` for long content
4. **Don't forget `vim.schedule()`** — SSE callbacks run outside Neovim's main loop
5. **Don't hardcode highlight groups** — Use the established `OpenCode*` groups
6. **Don't skip the action boundary** — UI → actions.lua → init.lua, not UI → init.lua
7. **Don't forget `pcall` for lazy requires** — Many modules are loaded lazily
8. **Don't create new UI patterns** — Follow existing widget/float/menu patterns
