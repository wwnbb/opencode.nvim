local cs = require("opencode.ui.chat.state")
return cs.factory("subagent_notification", function(view)
local M = {}
local render = cs.module(view, require("opencode.ui.chat.render"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local style = cs.module(view, require("opencode.ui.chat.tool_style"))

function M.render_tool(part, expanded)
	local input, metadata = part.state.input, part.state.metadata
	local description = type(input.description) == "string" and input.description or ""
	local actor = type(metadata.agent) == "string" and metadata.agent ~= "" and metadata.agent or "Subagent"
	local status = ({ completed = "finished", error = "failed", cancelled = "cancelled" })[metadata.state]
	local heading = render.format_title(actor) .. " " .. status
	if description ~= "" then heading = heading .. " · " .. description:gsub("%s+", " ") end
	local result = style.panel.result()
	render.add_panel_line(result, tool_panel.header(heading, { fold = true, expanded = expanded }),
		metadata.state == "error" and style.error_hl or style.header_hl, { prefix = " " })
	if expanded then
		local output = part.text or ""
		-- Native descriptions/output are not XML escaped; strip only the exact envelope.
		local opening = '<subagent sessionID="' .. metadata.childID .. '" state="' .. metadata.state
			.. '" description="' .. description .. '">\n'
		local closing = "\n</subagent>"
		if output:sub(1, #opening) == opening and output:sub(-#closing) == closing then
			output = output:sub(#opening + 1, -#closing - 1)
		end
		style.add_border(result)
		tool_panel.add_raw_body(result, output ~= "" and output or "No output", {
			panel = style.panel, prefix = style.prefix,
		})
		style.add_border(result, true)
		style.contain_background(result)
	end
	-- Rendered as a task, it still ends with the blank row of every compact row.
	result.lines[#result.lines + 1] = ""
	return result
end

return M

end)
