local cs = require("opencode.ui.chat.state")
return cs.factory("instructions", function(view)
-- Consecutive instruction loads share one row counting distinct files; each
-- load is a sub-line when expanded. The file contents stay model-facing.
local M = {}
local render = cs.module(view, require("opencode.ui.chat.render"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local style = cs.module(view, require("opencode.ui.chat.tool_style"))
local text = require("opencode.util.text")

-- A row for the run of instruction-load messages starting at messages[first].
---@param messages table[]
---@param first integer
---@param load fun(message: table): table|nil Instruction load of a message
---@return table|nil part, integer last
function M.group(messages, first, load)
	local loads, last = {}, first
	for index = first, #messages do
		local message = messages[index]
		local current = load(message)
		if current then
			loads[#loads + 1], last = current, index
		elseif not message.hidden then
			break
		end
	end
	if #loads == 0 then return nil, first end
	local leader = loads[1]
	return {
		id = "instructions:" .. leader.id, messageID = leader.messageID, sessionID = leader.sessionID,
		type = "text", synthetic = true, instructions = loads,
	}, last
end

function M.cache_key(part)
	local ids = {}
	for _, load in ipairs(part.instructions) do ids[#ids + 1] = load.id end
	return table.concat(ids, "\0")
end

function M.render_tool(part, expanded)
	local files, count = {}, 0
	for _, load in ipairs(part.instructions) do
		for _, path in ipairs(load.instruction_load.paths) do
			if not files[path] then files[path], count = true, count + 1 end
		end
	end
	local result = style.panel.result()
	local width = render.get_chat_text_width()
	local label = "Instructions · " .. count .. (count == 1 and " file" or " files")
	render.add_panel_line(result, tool_panel.header(label, { fold = true, expanded = expanded }),
		style.header_hl, { prefix = " " })
	if expanded then
		for _, load in ipairs(part.instructions) do
			local data = load.instruction_load
			local line = data.description
			if not line then
				local paths = {}
				for _, path in ipairs(data.paths) do paths[#paths + 1] = text.normalize_path(path) end
				line = "Loaded " .. table.concat(paths, ", ")
			end
			style.add_sub_line(result, text.truncate(line, math.max(1, width - #style.SUB_PREFIX), "…"))
		end
	end
	return result
end

return M

end)
