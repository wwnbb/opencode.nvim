local cs = require("opencode.ui.chat.state")
return cs.factory("task_children", function(view)
-- Resolve task navigation only from the child session ID supplied by v2.

local M = {}

local state = view
local actions = require("opencode.actions")
local render = cs.module(view, require("opencode.ui.chat.render"))

local function resolve_tool_part(value)
	return cs.module(view, require("opencode.ui.chat.tasks")).resolve_tool_part(value)
end

---@param tool_part table|nil
---@return string|nil
function M.get_task_child_session_id(tool_part)
	tool_part = resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then return nil end
	local metadata = render.get_tool_metadata(tool_part)
	local child_id = metadata.sessionId or metadata.sessionID
	if type(child_id) == "string" and child_id ~= "" then return child_id end
	return nil
end

---@param tool_part table|nil
---@param opts? table
function M.ensure_task_child_loaded(tool_part, opts)
	tool_part = resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" or tool_part.tool ~= "task" or not tool_part.id then return end

	local child_id = M.get_task_child_session_id(tool_part)
	-- The task stays visible while the server has not emitted an exact child ID.
	if not child_id then return end

	local sync = require("opencode.sync")
	local messages = sync.get_messages(child_id)
	if type(messages) == "table" and #messages > 0 then
		state.task_child_cache[tool_part.id] = true
		return
	end
	if state.task_child_cache[tool_part.id] or state.task_child_loading[tool_part.id] then return end

	local part_id = tool_part.id
	local loading = state.task_child_loading
	loading[part_id] = true
	local load_opts = vim.tbl_extend("force", { limit = 100 }, type(opts) == "table" and opts or {})
	actions.load_session_messages(child_id, load_opts, function(err)
		vim.schedule(function()
			if state.task_child_loading ~= loading then return end
			loading[part_id] = nil
			if err then state.expanded_tasks[part_id] = nil else state.task_child_cache[part_id] = true end
			if state.tasks[part_id] then cs.module(view, require("opencode.ui.chat.tasks")).rerender_task(part_id) end
		end)
	end)
end

---@param tool_part table|nil
---@param callback function(err: any, child_session_id: string|nil)
function M.resolve_task_child_session_id(tool_part, callback)
	callback(nil, M.get_task_child_session_id(tool_part))
end

return M

end)
