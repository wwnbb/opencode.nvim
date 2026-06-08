local M = {}

local state = require("opencode.ui.chat.state").state
local chat_tasks = require("opencode.ui.chat.tasks")
local widget_support = require("opencode.ui.chat.widget_support")
local perf = require("opencode.perf")

function M.render_tool_part(ctx, tool_part, message_revision, part_revisions)
	local tool_name = tostring(tool_part and tool_part.tool or "unknown")
	local done = perf.start("chat.render.tool_part." .. tool_name)
	local part_revision = tool_part.id and part_revisions and part_revisions[tool_part.id] or 0

	if tool_part.tool == "task" then
		local is_expanded = state.expanded_tasks[tool_part.id] or false
		local cache_key = nil
		if not is_expanded and not chat_tasks.is_animating_tool_part(tool_part) then
			cache_key = ctx:render_cache_key(
				"task",
				ctx.current_session.id,
				tool_part.messageID,
				tool_part.id,
				message_revision,
				part_revision,
				ctx.chat_width,
				is_expanded
			)
		end
		local result = ctx:cached_render_result(cache_key, function()
			return chat_tasks.render_task_tool(tool_part, is_expanded)
		end)
		local base_line = ctx:add_render_result(result, "tool")
		state.tasks[tool_part.id] = widget_support.mark_render_generation({
			start_line = base_line,
			end_line = base_line + #result.lines - 1,
			tool_part = tool_part,
			highlights = result.highlights,
		})
		chat_tasks.ensure_task_child_loaded(tool_part)
		done({
			tool = tool_name,
			part_id = tool_part.id,
			expanded = is_expanded == true,
			lines = #(result.lines or {}),
			highlights = #(result.highlights or {}),
			cacheable = cache_key ~= nil,
		})
		return
	end

	local is_expanded = state.expanded_tools[tool_part.id] or false
	local cache_key = nil
	if not chat_tasks.is_animating_tool_part(tool_part) then
		cache_key = ctx:render_cache_key(
			"tool",
			ctx.current_session.id,
			tool_part.messageID,
			tool_part.id,
			message_revision,
			part_revision,
			ctx.chat_width,
			is_expanded
		)
	end
	local result = ctx:cached_render_result(cache_key, function()
		return chat_tasks.render_regular_tool(tool_part, is_expanded)
	end)
	local base_line = ctx:add_render_result(result, "tool")
	state.tools[tool_part.id] = widget_support.mark_render_generation({
		start_line = base_line,
		end_line = base_line + #result.lines - 1,
		tool_part = tool_part,
		highlights = result.highlights,
	})
	done({
		tool = tool_name,
		part_id = tool_part.id,
		expanded = is_expanded == true,
		lines = #(result.lines or {}),
		highlights = #(result.highlights or {}),
		cacheable = cache_key ~= nil,
	})
end

return M
