local web_tool = require("opencode.ui.chat.web_tool")
local M = { animation_line = web_tool.animation_line }

function M.render_tool(part, expanded, opts)
	if type(part) ~= "table" or part.tool ~= "websearch" then return nil end
	return web_tool.render(part, expanded, opts)
end

M.render = M.render_tool
return M
