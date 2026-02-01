# Accumulated Diff Artifact Feature Specification

## Overview

This specification describes how the opencode.nvim plugin should accumulate all file edits during a session into a single reviewable diff artifact. Instead of applying edits immediately, the plugin collects all changes and presents them to the user for review before proceeding to testing.

## Problem Statement

Currently, file edits from the LLM are handled individually. Users see changes applied one-by-one, which:
- Makes it difficult to see the complete picture of changes
- Doesn't allow reviewing all changes as a cohesive unit before testing
- Can lead to partial states if the user interrupts mid-task

## Proposed Solution

The plugin should:
1. Intercept file edit tool calls from the LLM response
2. Accumulate all edits into a single "Edit Artifact" data structure
3. Display the artifact in a review interface before applying
4. Allow the user to accept/reject the entire changeset (or individual files)
5. Only proceed to testing phase after user approval

---

## Data Structures

### EditArtifact

```lua
---@class EditArtifact
---@field id string Unique identifier
---@field session_id string Associated session
---@field status "pending" | "reviewing" | "applied" | "rejected"
---@field files EditArtifactFile[]
---@field stats EditArtifactStats
---@field created_at number Timestamp
---@field reviewed_at number|nil Timestamp when reviewed

---@class EditArtifactFile
---@field path string Absolute file path
---@field relative_path string Relative to project root
---@field type "add" | "update" | "delete" | "move"
---@field before string Original content (empty for new files)
---@field after string New content (empty for deletions)
---@field diff string Unified diff format
---@field additions number Lines added
---@field deletions number Lines removed
---@field selected boolean Whether to include in apply
---@field move_path string|nil Target path for moves

---@class EditArtifactStats
---@field total_files number
---@field total_additions number
---@field total_deletions number
```

### ToolCall (from LLM response)

```lua
---@class ToolCall
---@field id string Tool call ID
---@field tool string Tool name ("edit", "write", "apply_patch", etc.)
---@field input table Tool parameters
---@field output string|nil Tool result
---@field metadata table|nil Additional metadata including diffs
```

---

## Module Structure

### `lua/opencode/artifact/init.lua`

Main artifact module entry point.

```lua
local M = {}

---@type EditArtifact|nil
M.current_artifact = nil

--- Create a new artifact from accumulated tool calls
---@param session_id string
---@param tool_calls ToolCall[]
---@return EditArtifact
function M.create(session_id, tool_calls) end

--- Add a file change to the current artifact
---@param file EditArtifactFile
function M.add_file(file) end

--- Accept and apply the artifact
---@param artifact EditArtifact
---@return boolean success
---@return string|nil error
function M.accept(artifact) end

--- Reject the artifact (no changes applied)
---@param artifact EditArtifact
function M.reject(artifact) end

--- Get current pending artifact
---@return EditArtifact|nil
function M.get_current() end

--- Clear current artifact
function M.clear() end

return M
```

### `lua/opencode/artifact/accumulator.lua`

Handles accumulating tool calls into artifact.

```lua
local M = {}

--- Extract file diffs from a tool call based on tool type
---@param tool_call ToolCall
---@return EditArtifactFile[]
function M.extract_files(tool_call) end

--- Merge multiple edits to the same file
---@param files EditArtifactFile[]
---@return EditArtifactFile[]
function M.merge_files(files) end

--- Calculate stats from file list
---@param files EditArtifactFile[]
---@return EditArtifactStats
function M.calculate_stats(files) end

--- Generate unified diff between two strings
---@param before string
---@param after string
---@param filename string
---@return string
function M.generate_diff(before, after, filename) end

return M
```

### `lua/opencode/artifact/ui.lua`

UI components for artifact review.

```lua
local M = {}

--- Show artifact review in floating window
---@param artifact EditArtifact
---@param opts? { on_accept: function, on_reject: function }
function M.show_review(artifact, opts) end

--- Show diff for a specific file in split
---@param file EditArtifactFile
function M.show_file_diff(file) end

--- Update review window with current artifact state
function M.refresh() end

--- Close review window
function M.close() end

return M
```

### `lua/opencode/artifact/backup.lua`

Handles backup/restore for safe rollback.

```lua
local M = {}

--- Create backup of files before applying changes
---@param files EditArtifactFile[]
---@return string backup_id
function M.create_backup(files) end

--- Restore files from backup
---@param backup_id string
---@return boolean success
function M.restore(backup_id) end

--- Clean up old backups
---@param max_age_seconds number
function M.cleanup(max_age_seconds) end

return M
```

---

## User Interface

### Review Window Layout

```
┌─────────────────────────────────────────────────────────────────┐
│ Review Changes                                        [X] Close │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ Summary: 4 files | +127 lines | -23 lines                      │
│                                                                 │
│ ─────────────────────────────────────────────────────────────── │
│                                                                 │
│ [x] + src/auth.lua                          +45  -5   [d]iff   │
│ [x] + src/types.lua                         +32  -0   [d]iff   │
│ [x] ~ src/routes.lua                        +38  -12  [d]iff   │
│ [x] - src/old_auth.lua                      +0   -15  [d]iff   │
│                                                                 │
│ ─────────────────────────────────────────────────────────────── │
│                                                                 │
│ Press:                                                          │
│   a     = Apply selected changes                               │
│   r     = Reject all changes                                   │
│   <Tab> = Toggle file selection                                │
│   d     = View diff for file under cursor                      │
│   q     = Close (keeps artifact pending)                       │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

### Diff View (Split Window)

When user presses `d` on a file, open a diff view:

```
┌────────────────────────────┬────────────────────────────────────┐
│ src/auth.lua (before)      │ src/auth.lua (after)               │
├────────────────────────────┼────────────────────────────────────┤
│ local M = {}               │ local M = {}                       │
│                            │ local jwt = require("jwt")         │
│                            │ local hash = require("hash")       │
│ function M.login(user)     │ function M.login(user, password)   │
│   return true              │   if not M.verify(password) then   │
│                            │     return false, "invalid"        │
│                            │   end                              │
│                            │   return jwt.sign(user)            │
│ end                        │ end                                │
│                            │                                    │
│ return M                   │ return M                           │
└────────────────────────────┴────────────────────────────────────┘
```

---

## Integration Points

### Intercepting Tool Calls

The plugin should intercept edit-related tool calls before they're executed:

```lua
-- In the message/response handler
local function handle_tool_calls(tool_calls)
  local edit_tools = { "edit", "write", "apply_patch", "multiedit" }
  local edit_calls = {}
  local other_calls = {}

  for _, call in ipairs(tool_calls) do
    if vim.tbl_contains(edit_tools, call.tool) then
      table.insert(edit_calls, call)
    else
      table.insert(other_calls, call)
    end
  end

  -- Execute non-edit tools immediately
  for _, call in ipairs(other_calls) do
    execute_tool(call)
  end

  -- Accumulate edit tools into artifact
  if #edit_calls > 0 then
    local artifact = require("opencode.artifact").create(session_id, edit_calls)
    require("opencode.artifact.ui").show_review(artifact, {
      on_accept = function()
        -- Proceed to testing
      end,
      on_reject = function()
        -- Notify LLM of rejection
      end,
    })
  end
end
```

### Events

```lua
-- Emit events for external integrations
vim.api.nvim_exec_autocmds("User", {
  pattern = "OpenCodeArtifactCreated",
  data = { artifact = artifact },
})

vim.api.nvim_exec_autocmds("User", {
  pattern = "OpenCodeArtifactApplied",
  data = { artifact = artifact },
})

vim.api.nvim_exec_autocmds("User", {
  pattern = "OpenCodeArtifactRejected",
  data = { artifact = artifact },
})
```

---

## Configuration

```lua
require("opencode").setup({
  artifact = {
    -- Enable artifact accumulation mode
    enabled = true,

    -- Auto-expand diffs in review UI
    auto_expand = false,

    -- Show review window automatically when artifact is ready
    auto_show = true,

    -- Window configuration
    window = {
      width = 0.8,   -- 80% of editor width
      height = 0.8,  -- 80% of editor height
      border = "rounded",
    },

    -- Diff view style
    diff_style = "split", -- "split" | "unified" | "inline"

    -- Keymaps (can be customized)
    keymaps = {
      accept = "a",
      reject = "r",
      toggle = "<Tab>",
      diff = "d",
      close = "q",
      select_all = "A",
      deselect_all = "D",
    },

    -- Backup settings
    backup = {
      enabled = true,
      dir = vim.fn.stdpath("data") .. "/opencode/backups",
      max_age = 86400, -- 24 hours
    },
  },
})
```

---

## User Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Request                              │
│              "Add authentication to the API"                     │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                      LLM Response                                │
│         Contains multiple edit/write tool calls                  │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                  Plugin Intercepts Edits                         │
│                                                                  │
│  1. Separate edit tools from other tools                        │
│  2. Execute non-edit tools (read, glob, etc.)                   │
│  3. Accumulate edit tools into EditArtifact                     │
│  4. Calculate diffs and stats                                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Show Review Window                            │
│                                                                  │
│  - List all files with changes                                  │
│  - Show +/- line counts                                         │
│  - Allow file selection                                         │
│  - Keymaps for accept/reject/diff                               │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
        ┌───────────────────┐   ┌───────────────────┐
        │      Accept       │   │      Reject       │
        │                   │   │                   │
        │ 1. Create backup  │   │ 1. Clear artifact │
        │ 2. Apply changes  │   │ 2. Notify LLM     │
        │ 3. Clear artifact │   │ 3. User can       │
        │ 4. Proceed to     │   │    request retry  │
        │    testing        │   │                   │
        └───────────────────┘   └───────────────────┘
```

---

## Implementation Notes

### Diff Generation

Use Neovim's built-in diff or a pure Lua implementation:

```lua
-- Option 1: Use vim.diff (Neovim 0.9+)
local diff = vim.diff(before, after, {
  algorithm = "histogram",
  result_type = "unified",
})

-- Option 2: Shell out to diff command
local diff = vim.fn.system({
  "diff", "-u",
  "--label", "a/" .. filename,
  "--label", "b/" .. filename,
  before_file, after_file
})
```

### File Application

```lua
local function apply_file(file)
  if file.type == "delete" then
    vim.fn.delete(file.path)
  elseif file.type == "move" then
    vim.fn.rename(file.path, file.move_path)
  else
    -- Ensure directory exists
    vim.fn.mkdir(vim.fn.fnamemodify(file.path, ":h"), "p")
    -- Write content
    local f = io.open(file.path, "w")
    if f then
      f:write(file.after)
      f:close()
    end
  end

  -- Reload buffer if open
  local bufnr = vim.fn.bufnr(file.path)
  if bufnr ~= -1 then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("edit!")
    end)
  end
end
```

### Syntax Highlighting in Review Window

```lua
-- Highlight groups for review window
vim.api.nvim_set_hl(0, "OpenCodeArtifactAdd", { fg = "#98c379" })
vim.api.nvim_set_hl(0, "OpenCodeArtifactDelete", { fg = "#e06c75" })
vim.api.nvim_set_hl(0, "OpenCodeArtifactModify", { fg = "#e5c07b" })
vim.api.nvim_set_hl(0, "OpenCodeArtifactSelected", { fg = "#61afef" })
vim.api.nvim_set_hl(0, "OpenCodeArtifactStats", { fg = "#abb2bf", italic = true })
```

---

## Commands

```lua
-- User commands
vim.api.nvim_create_user_command("OpenCodeArtifactReview", function()
  local artifact = require("opencode.artifact").get_current()
  if artifact then
    require("opencode.artifact.ui").show_review(artifact)
  else
    vim.notify("No pending artifact", vim.log.levels.INFO)
  end
end, {})

vim.api.nvim_create_user_command("OpenCodeArtifactAccept", function()
  local artifact = require("opencode.artifact").get_current()
  if artifact then
    require("opencode.artifact").accept(artifact)
  end
end, {})

vim.api.nvim_create_user_command("OpenCodeArtifactReject", function()
  local artifact = require("opencode.artifact").get_current()
  if artifact then
    require("opencode.artifact").reject(artifact)
  end
end, {})
```

---

## Open Questions

1. **Partial acceptance**: Should users be able to accept some files and reject others?
   - Proposed: Yes, via checkbox toggle per file

2. **Hunk-level selection**: Should we support accepting/rejecting individual hunks?
   - Proposed: Future enhancement, not in initial version

3. **Multiple artifacts**: Can there be multiple pending artifacts?
   - Proposed: No, one at a time. New edits merge into current artifact.

4. **Timeout behavior**: What if user doesn't review for a long time?
   - Proposed: Artifact persists until explicitly accepted/rejected

5. **Buffer reloading**: How to handle if user has unsaved changes in a file being modified?
   - Proposed: Warn user and require confirmation

---

## Success Criteria

1. All file edits from a single LLM task are accumulated into one artifact
2. User can review all changes before any are applied
3. User can view individual file diffs
4. User can accept or reject the entire changeset
5. Rejected changes are not applied; user can request LLM to retry
6. Applied changes can be undone via backup restore
7. Review window has clear, intuitive keybindings
