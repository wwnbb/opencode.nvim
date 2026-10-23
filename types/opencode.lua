---@meta
-- LuaLS annotations only. This directory is not on the runtime path and is
-- never required; .luarc.json adds it to workspace.library.

-- nui.nvim's own annotations (workspace.library .deps/nvim/nui.nvim) define
-- NuiLine; this adds the private markers the chat renderer stores on lines.

---@class NuiLine
---@field _opencode_preserve_blank? boolean Keep an intentionally blank Markdown line through wrapping

---Rendered NuiLine list with optional syntax metadata attached to the list.
---@class OpenCodeRenderedLines: NuiLine[]
---@field _opencode_highlights? table[] Extmark highlights projected onto the rendered rows
---@field _opencode_syntax_retry? boolean Treesitter was not ready; render again later
