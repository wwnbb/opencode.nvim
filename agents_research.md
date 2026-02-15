# Subagent (Task Tool) Research Report

## Problem Statement

Investigate how OpenCode TUI handles subagent messages, what hotkeys relate to it, what features exist, and compare with the Neovim plugin implementation to identify gaps and missing features.

---

## Investigation Findings

### 1. TUI Subagent Message Handling

#### A. Task Tool Rendering (`llm_context/opencode/packages/ui/src/components/message-part.tsx`)

The TUI registers the `task` tool with specialized rendering:

```typescript
ToolRegistry.register({
  name: "task",
  render(props) {
    // Renders with:
    // - Icon: "task"
    // - Title: localized "ui.tool.agent" with subagent_type
    // - Subtitle: description (clickable to navigate to child session)
    // - Shows child permission prompts inline
    // - Displays summary of tool calls made by subagent
  },
})
```

**Key Features:**
- **Clickable subtitle**: Navigates to child session
- **Child permission proxy**: Shows child session's permission requests inline
- **Summary display**: Shows all tool invocations within the subagent
- **Metadata tracking**: Tracks `sessionId`, `model`, and tool `summary`

#### B. Keyboard Shortcuts for Subagent Navigation

| Keybind Name | Default Key | Action |
|--------------|-------------|--------|
| `session_child_cycle` | `<leader>right` | Navigate to next child session |
| `session_child_cycle_reverse` | `<leader>left` | Navigate to previous child session |
| `session_parent` | `<leader>up` | Go to parent session |

**Location:** `llm_context/opencode/packages/opencode/src/config/config.ts` (lines 820-822)

**Leader key:** `ctrl+x` by default, so actual sequences are:
- `ctrl+x` → `right` = Next child
- `ctrl+x` → `left` = Previous child
- `ctrl+x` → `up` = Go to parent

#### C. Session Hierarchy Navigation

When viewing a subagent session (has `parentID`), the header displays:

```
┌────────────────────────────────────────────────────┐
│ Subagent session                                   │
│ Context: 15,240 tokens ($0.02) v1.0.0             │
│ [Parent <leader+up>] [Prev <leader+left>] [Next <leader+right>] │
└────────────────────────────────────────────────────┘
```

The navigation works by:
1. Tracking `children` sessions with same `parentID`
2. Cycling through siblings with wraparound
3. Navigating to `parentID` when "Parent" is triggered

#### D. Permission Display for Subagents

Two-tier permission system:
1. **Parent session collects child permissions**
2. **Task tool shows child permission inline** with action buttons

---

### 2. Current Plugin Implementation

#### A. Task Tool Rendering (`lua/opencode/ui/chat.lua`, lines 1082-1159)

**What exists:**

```lua
local function render_task_tool(tool_part)
    local input = tool_part.state and tool_part.state.input or {}
    local metadata = tool_part.state and tool_part.state.metadata or {}
    local tool_status = tool_part.state and tool_part.state.status or "pending"
    local subagent = input.subagent_type or "unknown"
    local desc = input.description or ""
    local summary = metadata.summary or {}

    -- Handles:
    -- 1. completed: collapsed single line with tool call count
    -- 2. pending/no summary: shows "~ Delegating..."
    -- 3. running: shows header + tree of sub-tool calls
end
```

**What works:**
- Task icon display (`◉`)
- Single-line collapsed view
- Running tool tree during execution
- Tool call count

#### B. Current Keybindings

**Chat buffer:**

| Key | Action |
|-----|--------|
| `<CR>` | Toggle tool details / Confirm selection |
| `gd` | Go to file |
| `gD` | View diff |

**Session management:**

| Key | Action |
|-----|--------|
| `<leader>os` | Switch session (via palette) |
| `<leader>on` | New session |
| `<leader>of` | Fork session |

---

## Missing Features

| Feature | TUI | Plugin | Evidence |
|---------|-----|--------|----------|
| Child session navigation | `<leader>right/left/up>` | Missing | No keybinds in `config.lua` or `chat.lua` |
| Child session ID tracking | `metadata.sessionID` | Not extracted | `render_task_tool` doesn't use `metadata.sessionID` |
| Navigate to child session | Click subtitle | Missing | No `navigateToSession` callback |
| Session hierarchy tracking | `children` memo | Missing | `sync.lua` doesn't track `parentID`/children |
| Parent session navigation | `<leader>up>` | Missing | No `session_parent` keybind |
| Child permission proxy | Inline display | Missing | No child permission aggregation |
| Subagent model display | Shows model | Missing | Metadata not displayed |

---

## Code Gaps

### Gap 1: No child session ID extraction (`chat.lua:1082-1159`)

```lua
-- MISSING: Should extract child session ID
local child_session_id = metadata.sessionID or metadata.childSessionID
```

### Gap 2: No session hierarchy tracking (`sync.lua`)

```lua
-- MISSING: Should track parent-child relationships
local store = {
    session_parent = {}, -- { [child_session_id] = parent_session_id }
    session_children = {}, -- { [parent_session_id] = { child_ids... } }
}
```

### Gap 3: No navigation keybinds (`config.lua`)

```lua
-- MISSING: Should have these keybinds
keymaps = {
    session_child_next = "<leader>o]",  -- Navigate to next child
    session_child_prev = "<leader>o[",  -- Navigate to prev child
    session_parent = "<leader>o<Up>",   -- Navigate to parent
}
```

### Gap 4: No interactive task navigation (`chat.lua`)

```lua
-- MISSING: <CR> on task tool should offer navigation to child session
-- Current: <CR> only toggles tool details
-- Expected: Should navigate to child session if on completed task
```

---

## What Should Be Added/Fixed

### 1. Session Hierarchy Tracking (`sync.lua`)

```lua
-- Add to store
M.track_session_parent = function(child_id, parent_id)
    store.session_parent[child_id] = parent_id
    store.session_children[parent_id] = store.session_children[parent_id] or {}
    table.insert(store.session_children[parent_id], child_id)
end
```

### 2. Extract Child Session from Task Metadata (`chat.lua`)

```lua
-- In render_task_tool
local child_session_id = metadata.sessionID
if child_session_id then
    -- Store mapping for navigation
    state.set_task_child_session(message_id, child_session_id)
end
```

### 3. Add Navigation Keybinds (`config.lua`)

```lua
keymaps = {
    -- Existing...
    session_child_next = "]s",  -- Or <leader>o]
    session_child_prev = "[s",  -- Or <leader>o[
    session_parent = "[S",      -- Or <leader>o<Up>
}
```

### 4. Implement Navigation Actions (`init.lua`)

```lua
M.session_next_child = function()
    local current = state.get_current_session()
    local children = sync.get_child_sessions(current.id)
    -- Navigate to next sibling
end

M.session_prev_child = function()
    -- Navigate to previous sibling
end

M.session_parent = function()
    local current = state.get_current_session()
    if current.parentID then
        M.session_switch(current.parentID)
    end
end
```

### 5. Add Task Tool Navigation (`chat.lua`)

```lua
-- Modify <CR> keybind
vim.keymap.set("n", "<CR>", function()
    local task_session = M.get_task_session_at_cursor()
    if task_session then
        require("opencode").session_switch(task_session)
    else
        -- Existing toggle behavior
    end
end, opts)
```

### 6. Show Child Session Link in Task Tool (`chat.lua`)

```lua
-- Add to render_task_tool output
if tool_status == "completed" and child_session_id then
    add_line("  [Enter] View subagent session ->", "Comment")
end
```

---

## Summary Table

| Feature Category | TUI Feature | Plugin Status | Priority |
|-----------------|-------------|---------------|----------|
| Task tool rendering | Collapsed/expanded views | Implemented | - |
| Tool call tree | Shows running tools | Implemented | - |
| Child session navigation | `<leader>right/left>` | Missing | High |
| Parent session navigation | `<leader>up>` | Missing | High |
| Session hierarchy tracking | `children` memo | Missing | High |
| Child session ID | Extracted from metadata | Missing | High |
| Child permission proxy | Inline display | Missing | Medium |
| Subagent model display | Shows model info | Missing | Low |
| Session navigation UI | Header buttons | Missing | Medium |

---

## Open Questions

1. **Should child sessions be fully rendered in a separate buffer/tab, or inline in the parent chat?**
   - TUI: Separate session view with navigation
   - Plugin: Could use tabs, splits, or floating windows

2. **How should the plugin display the session hierarchy?**
   - A tree view in a sidebar?
   - Status line indicators?
   - Header similar to TUI?

3. **Should there be a visual indicator when viewing a child session?**
   - TUI shows "Subagent session" header with navigation buttons
   - Plugin could show in status line or window title