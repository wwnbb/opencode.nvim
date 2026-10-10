-- The editor snapshot is source data: render it literally, never as Markdown.
local M = {}
local render = require("opencode.ui.chat.render")
local tool_panel = require("opencode.ui.chat.tool_panel")
local style = require("opencode.ui.chat.tool_style")

function M.render_tool(part, expanded)
	local data = part._editor_context
	local result = style.panel.result()
	local label = "Editor context · " .. vim.fn.fnamemodify(data.path, ":t") .. ":" .. data.line
	render.add_panel_line(result, tool_panel.header(label, { fold = true, expanded = expanded }),
		style.header_hl, { prefix = " " })
	if expanded then
		style.add_border(result)
		tool_panel.add_raw_body(result, vim.trim(require("opencode.export").json(data)), {
			panel = style.panel, prefix = style.prefix, language = "json",
		})
		style.add_border(result, true)
		style.contain_background(result)
	end
	return result
end

return M
