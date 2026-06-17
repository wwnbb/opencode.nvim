---
name: opencode-nvim-widgets
description: Implement or refine opencode.nvim chat widgets and tool renderers. Use when working in /Users/admin/work/lua/opencode.nvim on Lua UI code for bash, read, edit, file-edit, search, skill, todo, task, question, or permission widgets; adding a new tool widget; changing widget rendering, highlights, expand/collapse behavior, focus handling, keymaps, or chat buffer design.
---

# OpenCode.nvim Widgets

Use this skill to implement widgets that feel native to opencode.nvim's chat buffer. Match the existing read, bash, and edit widgets: compact panel rendering, defensive tool-state parsing, explicit highlight groups, predictable collapsed/expanded views, and no surprising side effects from render functions.

## Map

- Regular tool widgets: `lua/opencode/ui/chat/<tool>.lua`.
- Regular tool dispatch, icons, summaries, expand/collapse, in-place rerendering: `lua/opencode/ui/chat/tasks.lua`.
- Shared panel helpers: `lua/opencode/ui/panel.lua` and `lua/opencode/ui/chat/render.lua`.
- Text normalization: `lua/opencode/util/text.lua`.
- Interactive edit rendering: `lua/opencode/ui/edit_widget.lua`.
- Edit lifecycle, keymaps, inline diff windows, replies: `lua/opencode/ui/chat/edits.lua`.
- Chat state and tracked ranges: `lua/opencode/ui/chat/state.lua`.
- Focus/range helpers: `lua/opencode/ui/chat/widget_support.lua`.

Inspect the closest existing widget first: bash for commands, read for file previews, edit for interactive reviews, tasks for dispatch behavior.

## Renderer Contract

Implement regular tool widgets as pure renderers:

```lua
---@param tool_part table
---@param is_expanded boolean
---@return table|nil result
function M.render_tool(tool_part, is_expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "mytool" then
		return nil
	end

	ensure_highlights()
	local result = { lines = {}, highlights = {} }
	return result
end
```

Return `nil` for unsupported tools so `tasks.render_regular_tool()` can continue down the specialized-renderer chain and then fall back to `render.render_tool_line()`.

When adding a regular tool:

1. Add `local chat_mytool = require("opencode.ui.chat.mytool")` in `chat/tasks.lua`.
2. Add a quiet icon to `TOOL_ICONS` if summary rows need one.
3. Add concise pending/completed label handling in `format_summary_item_label()` or `M.format_tool_line()` only when the generic label is not enough.
4. Insert `result = result or chat_mytool.render_tool(tool_part, is_expanded)` in `M.render_regular_tool()` before the generic fallback.

## Data Rules

Tool payloads may be partial while pending/running. Parse defensively from `tool_part.input`, `tool_part.state.input`, `tool_part.metadata`, and `tool_part.state.metadata`.

```lua
local render = require("opencode.ui.chat.render")
local text_util = require("opencode.util.text")

local tool_state = type(tool_part.state) == "table" and tool_part.state or {}
local input = type(tool_state.input) == "table" and tool_state.input or {}
local fallback_input = type(tool_part.input) == "table" and tool_part.input or {}
input = vim.tbl_deep_extend("force", {}, fallback_input, input)

local metadata = render.get_tool_metadata(tool_part)
local status = tool_state.status or "pending"
local working = status == "pending" or status == "running"
```

For output text:

- Treat `nil` and `vim.NIL` as empty.
- Accept strings plus useful tables such as `{ output = ... }`, `{ content = ... }`, `{ stdout = ..., stderr = ... }`.
- Strip ANSI and normalize CRLF through `text_util.normalize_text`.
- Use `first_nonempty_text` for body text and `first_nonempty_trimmed_text` for labels, paths, descriptions, commands, and workdirs.
- Never assume `state.input` is a table; some tools pass raw strings.

## Panel Pattern

Use the shared panel helpers so wrapping, padding, and prefix highlights match existing widgets:

```lua
local panel = require("opencode.ui.panel")

local PANEL_PREFIX = "▏  "
local PANEL_BLANK_PREFIX = "▏"
local PANEL_BORDER_HL = "OpenCodeMyToolMuted"

local function add_panel_line(result, text, hl_group)
	return panel.add_line(result, text, hl_group, {
		prefix = PANEL_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end

local function add_panel_raw_line(result, text, hl_group, opts)
	opts = vim.tbl_extend("force", opts or {}, {
		prefix = PANEL_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
	return panel.add_raw_line(result, text, hl_group, opts)
end

local function add_panel_blank(result)
	panel.add_blank(result, "OpenCodeMyToolOutput", {
		prefix = PANEL_BLANK_PREFIX,
		prefix_hl_group = PANEL_BORDER_HL,
	})
end
```

Layout rules:

- Start with a blank panel row, then one concise header, then content.
- Use `# <Verb> <target>` for readable/completed states.
- Use `~ <action>...` for incomplete states.
- Add a trailing plain blank separator only when the surrounding widget type already does so, as read and edit do.
- Normalize paths with `vim.fn.fnamemodify(path, ":~:.")`.
- Keep details in the body, not the header.

## Collapse And Overflow

Use `MAX_COLLAPSED_OUTPUT_LINES = 10` unless the surrounding widget has a stronger precedent. Build body entries first, then render all entries when expanded or the limit when collapsed.

- Add a fold marker only when there is hidden content or the widget is expanded.
- Keep collapsed and expanded headers semantically stable.
- Add `... (N more lines, press O to expand)` when collapsed content is hidden.
- Make the collapsed view answer "what happened?" without requiring expansion.

## Highlights And Syntax

Define highlights in `ensure_highlights()` and call it at the top of `render_tool()`:

```lua
local function ensure_highlights()
	panel.set_hl("OpenCodeMyToolMuted", "Comment", "Normal")
	panel.set_hl("OpenCodeMyToolHeader", "Title", "Normal", { bold = true })
	panel.set_hl("OpenCodeMyToolPath", "String", "Normal", { bold = true })
	panel.set_hl("OpenCodeMyToolOutput", "Normal", nil)
	panel.set_hl("OpenCodeMyToolError", "DiagnosticError", "ErrorMsg")
end
```

Highlight coordinates are zero-based and relative to the widget result. The caller applies them at the widget start line.

For code/output:

- Use `syntax.language_for_path(filepath)` for file previews.
- Use `syntax.detect_output_language(output, metadata)` for shell/tool output.
- Use `panel.add_raw_line()` when columns matter.
- Set `wrap = false` when line-to-source positions matter.
- Only call `syntax.add_highlights()` after confirming rows did not wrap; mark `can_highlight = false` when `#rows > 1`.
- Set `col_offset = #PANEL_PREFIX`, plus any body prefix such as `"$ "`.
- Use `syntax.add_markdown_highlights()` for markdown output.
- Use `render.highlight_panel_text(result, rows, text, hl_group)` for targeted path/header spans.

## Status And Animation

Use `status == "pending" or status == "running"` as the working predicate. Existing widgets use `state.task_anim_frame`:

```lua
local cs = require("opencode.ui.chat.state")
local state = cs.state
local FRAMES = { "|", "/", "-", "\\" }

local function get_anim_frame()
	return FRAMES[state.task_anim_frame] or FRAMES[1]
end
```

Show animation only while working. Use error highlights when `status == "error"`, an error body exists, or an exit code is non-zero.

## Interactive Widgets

Regular tool renderers should not manage cursor behavior. For interactive widgets like edit review:

- Keep rendering in a dedicated renderer such as `edit_widget.lua`.
- Keep lifecycle, state transitions, external effects, and replies in a chat module such as `chat/edits.lua`.
- Store user choices in a state module such as `edit/state.lua`.
- Return `widget_base.make_meta()` with interactive ranges when cursor navigation needs per-item selection.
- Use `widget_support.request_focus()`, `capture_focus_line()`, and `apply_focus_cursor()` for focus after render.
- Keep keymap routing in `chat/init.lua` narrow and explicit.
- When replacing widget lines in place, update `state.<kind>[id].end_line`, highlights, and tracked ranges through existing helpers.

## Design Rules

- Optimize for repeated scanning inside a narrow Neovim side panel.
- Prefer quiet symbols and compact labels over explanatory copy.
- Use custom groups named `OpenCode<Tool><Role>` with sources such as `Comment`, `Normal`, `String`, `Title`, `Special`, `DiagnosticError`, and diff groups.
- Inherit cursor-line background through `panel.set_hl`.
- Do not add decorative boxes, nested panels, large headings, or marketing-style copy.
- Do not add visible instructions except terse action hints that map to existing keys, such as overflow text.
- Keep output faithful. Strip transport noise such as echoed commands only when a widget has a known pattern; never hide actual errors.
- For file changes, show path, status, and stats first; use inline diff only on demand.
- For command output, show description/workdir, command, output, stderr, and exit code when available.
- For file reads, show path, offset/limit, code preview, loaded-file notes, and errors.

## Validation

Run a focused Lua load check after adding or changing modules:

```bash
nvim --headless -u test.lua --cmd "set rtp+=/Users/admin/work/lua/opencode.nvim" +qa
```

If changing architecture or state boundaries, run matching repo scripts:

```bash
nvim --headless -u test.lua --cmd "set rtp+=/Users/admin/work/lua/opencode.nvim" -l tests/smoke-require.lua
nvim --headless -u test.lua --cmd "set rtp+=/Users/admin/work/lua/opencode.nvim" -l tests/check-architecture.lua
nvim --headless -u test.lua --cmd "set rtp+=/Users/admin/work/lua/opencode.nvim" -l tests/check-state-ownership.lua
```

Use `./test.sh --minimal` for manual UI inspection when rendering, cursor behavior, or keymaps changed. Test pending, running, completed, error, empty-output, long-output, and narrow-window cases.

Do not validate tool implementation changes by re-running the same live OpenCode tool in the current session; the running tool may not hot-reload its own source.
