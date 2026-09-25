local M = {}

local state = require("opencode.ui.chat.state").state
local chat_tasks = require("opencode.ui.chat.tasks")
local widget_support = require("opencode.ui.chat.widget_support")
local tree = require("opencode.ui.chat.widget_tree")

function M.render_tool_part(ctx, tool_part, message_revision, part_revisions)
	tool_part = chat_tasks.resolve_tool_part(tool_part)
	local part_revision = tool_part.id and part_revisions and part_revisions[tool_part.id] or 0
	local position_ids = {
		session_id = tool_part.sessionID or ctx.current_session.id,
		message_id = tool_part.messageID,
		part_id = tool_part.id,
	}

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
		state.tasks[tool_part.id] = widget_support.mark_render_generation(vim.tbl_extend("force", position_ids, {
			start_line = base_line,
			end_line = base_line + #result.lines - 1,
			tool_part = tool_part,
			highlights = result.highlights,
		}))
		chat_tasks.ensure_task_child_loaded(tool_part)
		return
	end

	local is_expanded = state.expanded_tools[tool_part.id] or false
	local cache_key = nil
	if not chat_tasks.is_animating_tool_part(tool_part) then
		cache_key = ctx:render_cache_key(
			tool_part.type == "skill" and "skill_attachment" or "tool",
			ctx.current_session.id,
			tool_part.messageID,
			tool_part.id,
			message_revision,
			part_revision,
			ctx.chat_width,
			is_expanded,
			chat_tasks.tool_cache_key(tool_part)
		)
	end
	local result = ctx:cached_render_result(cache_key, function()
		return chat_tasks.render_regular_tool(tool_part, is_expanded)
	end)
	local base_line = ctx:add_render_result(result, "tool")
	state.tools[tool_part.id] = widget_support.mark_render_generation(vim.tbl_extend("force", position_ids, {
		kind = chat_tasks.is_tool_leaf(tool_part) and "tool" or nil,
		start_line = base_line,
		end_line = base_line + #result.lines - 1,
		tool_part = tool_part,
		highlights = result.highlights,
		children = tree.positions(result.children, base_line, state.render_generation),
	}))
end

-- Attachments share leaf navigation and expansion, while retaining their native
-- type and server-provided text in the sync store and rendered position.
M.render_skill_attachment = M.render_tool_part

return M
