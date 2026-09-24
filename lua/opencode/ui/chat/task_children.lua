-- Resolve task navigation only from the child session ID supplied by v2.

local M = {}

local state = require("opencode.ui.chat.state").state
local actions = require("opencode.actions")
local render = require("opencode.ui.chat.render")
local task_animation = require("opencode.ui.chat.task_animation")

local function resolve_tool_part(value)
	return require("opencode.ui.chat.tasks").resolve_tool_part(value)
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
	if not task_animation.is_task_working(task_animation.task_status(tool_part)) then return end

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
	state.task_child_loading[part_id] = true
	local load_opts = vim.tbl_extend("force", { limit = 100 }, type(opts) == "table" and opts or {})
	actions.load_session_messages(child_id, load_opts, function(err)
		vim.schedule(function()
			state.task_child_loading[part_id] = nil
			if not err then state.task_child_cache[part_id] = true end
			if state.tasks[part_id] then require("opencode.ui.chat.tasks").rerender_task(part_id) end
		end)
	end)
end

---@param tool_part table|nil
---@param callback function(err: any, child_session_id: string|nil)
function M.resolve_task_child_session_id(tool_part, callback)
	callback(nil, M.get_task_child_session_id(tool_part))
end

return M
