local cs = require("opencode.ui.chat.state")
return cs.factory("tool_renderer", function(view)
local M = {}

local state = view
local chat_tasks = cs.module(view, require("opencode.ui.chat.tasks"))
local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local task_animation = cs.module(view, require("opencode.ui.chat.task_animation"))
local task_children = cs.module(view, require("opencode.ui.chat.task_children"))
local tree = require("opencode.ui.chat.widget_tree")
local sync = require("opencode.sync")

-- A row depends on its own part, not on its siblings: key it by the part's
-- revision so one tool update leaves the rest of the message cached.
function M.render_tool_part(ctx, tool_part, message_revision, part_revisions)
	tool_part = chat_tasks.resolve_tool_part(tool_part)
	local part_revision = tool_part.id and part_revisions and part_revisions[tool_part.id]
	part_revision = part_revision or ("message:" .. tostring(message_revision or 0))
	local position_ids = {
		session_id = tool_part.sessionID or ctx.current_session.id,
		message_id = tool_part.messageID,
		part_id = tool_part.id,
	}

	if tool_part.tool == "task" then
		local is_expanded = state.expanded_tasks[tool_part.id] or false
		local cache_key = nil
		if not is_expanded and not chat_tasks.is_animating_tool_part(tool_part) then
			-- The collapsed summary and status also read the child session.
			local child_session_id = task_children.get_task_child_session_id(tool_part)
			cache_key = ctx:render_cache_key(
				"task",
				ctx.current_session.id,
				tool_part.messageID,
				tool_part.id,
				part_revision,
				ctx.chat_width,
				is_expanded,
				child_session_id or "",
				child_session_id and sync.get_task_summary_revision(child_session_id) or "",
				task_animation.task_status(tool_part)
			)
		end
		local result = ctx:cached_render_result(cache_key, function()
			return chat_tasks.render_task_tool(tool_part, is_expanded)
		end, ctx:render_owner_key("task", tool_part.messageID, tool_part.id))
		ctx:begin_block("task", tool_part.id or tool_part.callID, cache_key)
		local base_line = ctx:add_render_result(result, "task")
		state.tasks[tool_part.id] = widget_support.mark_render_generation(vim.tbl_extend("force", position_ids, {
			kind = "task",
			start_line = base_line,
			end_line = base_line + #result.lines - 1,
			tool_part = tool_part,
			highlights = result.highlights,
			children = tree.positions(result.children, base_line, state.render_generation),
		}))
		if chat_tasks.is_animating_tool_part(tool_part) then chat_tasks.ensure_task_child_loaded(tool_part) end
		return
	end

	local is_expanded = state.expanded_tools[tool_part.id] or false
	local separator_before = tool_part.tool == "bash" and ctx.last_block_kind == "tool" and ctx.last_tool_name == "bash"
	local cache_key = nil
	if not chat_tasks.is_animating_tool_part(tool_part) then
		cache_key = ctx:render_cache_key(
			tool_part.type == "skill" and "skill_attachment" or "tool",
			ctx.current_session.id,
			tool_part.messageID,
			tool_part.id,
			part_revision,
			ctx.chat_width,
			is_expanded,
			separator_before,
			separator_before and vim.fn.strdisplaywidth(tool_panel.PANEL_PREFIX) or "",
			separator_before and vim.fn.strdisplaywidth("─") or "",
			chat_tasks.tool_cache_key(tool_part)
		)
	end
	local result = ctx:cached_render_result(cache_key, function()
		return chat_tasks.render_regular_tool(tool_part, is_expanded, { separator_before = separator_before })
	end, ctx:render_owner_key(tool_part.type == "skill" and "skill_attachment" or "tool",
		tool_part.messageID, tool_part.id))
	-- A shell panel ends on its "▏" row; only another shell panel continues it.
	if #result.lines > 0 and tool_part.tool ~= "bash" and ctx.last_block_kind == "tool" and ctx.last_tool_name == "bash" then
		ctx:add_raw_line("")
	end
	-- After the shell panel's closing blank, which belongs to the panel above.
	ctx:begin_block("tool", tool_part.id or tool_part.callID, cache_key)
	local base_line = ctx:add_render_result(result, "tool")
	if #result.lines > 0 then ctx.last_tool_name = tool_part.tool end
	state.tools[tool_part.id] = widget_support.mark_render_generation(vim.tbl_extend("force", position_ids, {
		kind = chat_tasks.is_tool_leaf(tool_part) and "tool" or nil,
		start_line = base_line,
		end_line = base_line + #result.lines - 1,
		tool_part = tool_part,
		separator_before = separator_before,
		highlights = result.highlights,
		children = tree.positions(result.children, base_line, state.render_generation),
	}))
end

-- Attachments share leaf navigation and expansion, while retaining their native
-- type and server-provided text in the sync store and rendered position.
M.render_skill_attachment = M.render_tool_part

return M

end)
