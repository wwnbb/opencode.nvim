local cs = require("opencode.ui.chat.state")
return cs.factory("system_reminder", function(view)
-- Model-facing <system-reminder> notices fold to one row; the text is shown literally.
local M = {}
local render = cs.module(view, require("opencode.ui.chat.render"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local style = cs.module(view, require("opencode.ui.chat.tool_style"))
local text = require("opencode.util.text")

local function summary(body)
	local first = vim.trim(body):match("^[^\n]*") or ""
	return first:match("^(.-[.!?])%s") or first
end

function M.render_tool(part, expanded)
	local body = part.system_reminder
	local result = style.panel.result()
	local width = render.get_chat_text_width()
	local label = "System reminder"
	local first = summary(body)
	if first ~= "" then label = label .. " · " .. first end
	render.add_panel_line(result, text.truncate(tool_panel.header(label, { fold = true, expanded = expanded }),
		math.max(1, width - 1), "…"), style.header_hl, { prefix = " " })
	if expanded then
		local rows, indent = {}, vim.fn.strdisplaywidth(style.prefix)
		for _, line in ipairs(vim.split(vim.trim(body), "\n", { plain = true })) do
			local wrapped = render.wrap_text(render.expand_tabs(line, indent), math.max(1, width - indent))
			if #wrapped == 0 then wrapped = { "" } end
			vim.list_extend(rows, wrapped)
		end
		style.add_border(result)
		tool_panel.add_raw_body(result, table.concat(rows, "\n"), { panel = style.panel, prefix = style.prefix })
		style.add_border(result, true)
		style.contain_background(result)
	end
	return result
end

return M

end)
