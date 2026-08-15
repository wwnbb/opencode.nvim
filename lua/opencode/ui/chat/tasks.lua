-- Task and tool widget facade for the chat buffer.
-- Rendering dispatch + task widget + expand/collapse toggles + cursor queries.
-- Animation lives in task_animation.lua, labels in tool_labels.lua,
-- child-session resolution in task_children.lua, block updates in widget_support.lua.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render = require("opencode.ui.chat.render")
local chat_todos = require("opencode.ui.chat.todos")
local chat_bash = require("opencode.ui.chat.bash")
local chat_read = require("opencode.ui.chat.read")
local chat_skill = require("opencode.ui.chat.skill")
local chat_search = require("opencode.ui.chat.search")
local chat_rg = require("opencode.ui.chat.rg")
local chat_file_edit_results = require("opencode.ui.chat.file_edit_results")
local widget_support = require("opencode.ui.chat.widget_support")
local task_animation = require("opencode.ui.chat.task_animation")
local tool_labels = require("opencode.ui.chat.tool_labels")
local task_children = require("opencode.ui.chat.task_children")
local actions = require("opencode.actions")
local tool_part = require("opencode.ui.chat.tool_part")

local REGULAR_TOOL_RENDERERS = {
	chat_todos.render_tool,
	chat_bash.render_tool,
	chat_read.render_tool,
	chat_skill.render_tool,
	chat_search.render_tool,
	chat_rg.render_tool,
	chat_file_edit_results.render_tool,
}

---@param position table|nil
---@return table|nil
function M.resolve_tool_part(position)
	return tool_part.resolve(position)
end

-- ─── Animation (facade — implementation in task_animation.lua) ────────────────

local TASK_HIGHLIGHT_PRIORITY = task_animation.TASK_HIGHLIGHT_PRIORITY

M.get_task_anim_frame = task_animation.get_task_anim_frame
M.is_animating_tool_part = task_animation.is_animating_tool_part
M.stop_task_animation_timer = task_animation.stop_task_animation_timer
M.has_active_task_rows = task_animation.has_active_task_rows
M.start_task_animation_timer = task_animation.start_task_animation_timer
M.update_active_animations_in_place = task_animation.update_active_animations_in_place
M.update_animation_frames_in_place = task_animation.update_animation_frames_in_place

M.clear_animation_extmarks = widget_support.clear_animation_extmarks

-- ─── Tool labels (facade — implementation in tool_labels.lua) ────────────────

M.format_tool_line = tool_labels.format_tool_line

---@param tool_part table
---@return string|nil
-- ─── Child session resolution (facade — implementation in task_children.lua) ──

M.ensure_task_child_loaded = task_children.ensure_task_child_loaded
M.resolve_missing_task_children = task_children.resolve_missing_task_children
M.resolve_task_child_session_id = task_children.resolve_task_child_session_id

-- Render a task tool part as a compact TUI-style subagent summary.
--
-- Layout (collapsed, running):
--   ⠋ Explore Task — Inventory user commands
--     ↳ Grep nvim_create_user_command
--
-- Layout (collapsed, completed):
--   ✓ Explore Task — Inventory user commands
--     └ 1 toolcall · 1.2s
--
-- Layout (expanded, after O):
--   ✓ Explore Task — Inventory user commands
--     └ 1 toolcall · 1.2s
--
--     >> <first line of child user message>
--
--     ↳ Grep nvim_create_user_command
--
function M.render_task_tool(tool_part, expanded)
	tool_part = M.resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return { lines = {}, highlights = {} }
	end
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local subagent = input.subagent_type or "unknown"
	local desc = input.description or ""
	local summary = render.normalize_task_summary(metadata.summary)

	-- ── Prefer live child-session tool activity when available ──
	local child_session_id = task_children.get_task_child_session_id(tool_part)
	local child_user_prompt = nil
	if child_session_id then
		local ok_sync, sync = pcall(require, "opencode.sync")
		if ok_sync then
			local derived = {}
			local messages = sync.get_messages(child_session_id)
			for _, message in ipairs(messages) do
				if message.role == "assistant" then
					local tools = sync.get_message_tools(message.id)
					for _, part in ipairs(tools) do
						local part_state = part.state or {}
						local status = part_state.status or "pending"
						table.insert(derived, {
							id = part.id,
							tool = part.tool,
							state = {
								status = status,
								title = part_state.title,
								input = part_state.input or {},
								metadata = render.get_tool_metadata(part),
							},
							metadata = render.get_tool_metadata(part),
						})
					end
				end
				if message.role == "user" and not child_user_prompt then
					-- First user message with non-empty text → the task prompt
					local text = sync.get_message_text(message.id)
					if text ~= "" then
						child_user_prompt = text
					end
				end
			end
			if #derived > 0 then
				table.sort(derived, function(a, b)
					return tostring(a.id or "") < tostring(b.id or "")
				end)
				summary = derived
			end
		end
	end

	local agent_label = render.format_title(subagent)
	local task_frame = task_animation.get_task_anim_frame()
	local working = task_animation.is_task_working(tool_status)
	local completed = tool_status == "completed"
	local metadata_count = tool_labels.get_metadata_toolcall_count(metadata) or 0
	local count = math.max(#summary, metadata_count)
	local duration = tool_labels.format_state_duration(tool_part.state and tool_part.state.time)

	local result_lines = {}
	local result_highlights = {}

	local function add_line(text, hl_group)
		text = render.sanitize_buffer_line(text)
		table.insert(result_lines, text)
		if hl_group then
			table.insert(result_highlights, {
				line = #result_lines - 1,
				col_start = 0,
				col_end = #text,
				hl_group = hl_group,
				priority = TASK_HIGHLIGHT_PRIORITY,
			})
		end
	end

	local function add_spans_line(segments)
		local line = {}
		local spans = {}
		local col = 0
		for _, segment in ipairs(segments) do
			local text = render.sanitize_buffer_line(segment.text)
			if text ~= "" then
				table.insert(line, text)
				if segment.hl_group then
					table.insert(spans, {
						col_start = col,
						col_end = col + #text,
						hl_group = segment.hl_group,
						priority = segment.priority or TASK_HIGHLIGHT_PRIORITY,
					})
				end
				col = col + #text
			end
		end

		table.insert(result_lines, table.concat(line))
		for _, span in ipairs(spans) do
			span.line = #result_lines - 1
			table.insert(result_highlights, span)
		end
	end

	local function add_task_header(icon, icon_hl, agent_hl)
		add_spans_line({
			{ text = icon .. " ", hl_group = icon_hl },
			{ text = agent_label, hl_group = agent_hl },
			{ text = " Task – " .. desc, hl_group = "Comment" },
		})
	end

	local function add_task_detail(label, suffix)
		local first = label:match("^%S+") or label
		local rest = label:sub(#first + 1)
		add_spans_line({
			{ text = "  ↳ ", hl_group = "Comment" },
			{ text = first, hl_group = "Normal" },
			{ text = rest, hl_group = "Normal" },
			{ text = suffix or "", hl_group = "Comment" },
		})
	end

	-- Still-initialising: no input yet
	if desc == "" then
		local line = working and (task_frame .. " Delegating...")
			or (task_animation.get_task_status_icon(tool_status) .. " " .. agent_label .. " Task")
		add_line(line, tool_status == "error" and "DiagnosticError" or "Comment")
		local result = { lines = result_lines, highlights = result_highlights }
		return result
	end

	local line_hl = "Comment"
	local task_icon = task_animation.get_task_status_icon(tool_status)
	local agent_hl = render.get_agent_hl(subagent)
	if tool_status == "error" then
		line_hl = "DiagnosticError"
	end

	add_task_header(task_icon, line_hl, agent_hl)

	if tool_status == "error" then
		local err = tool_part.state and tool_part.state.error or nil
		if err then
			add_line("  ✗ " .. tostring(err), "DiagnosticError")
		end
	elseif working and count > 0 then
		local current_item = tool_labels.find_current_summary_item(summary)
		if not current_item and #summary == 1 then
			current_item = summary[1]
		end
		if current_item then
			add_task_detail(tool_labels.format_summary_item_label(current_item), " · " .. tool_labels.format_toolcall_count(count))
		else
			add_line("  ↳ " .. tool_labels.format_toolcall_count(count), "Comment")
		end
	elseif completed and count > 0 then
		local suffix = duration and (" · " .. duration) or ""
		add_line("  └ " .. tool_labels.format_toolcall_count(count) .. suffix, "Comment")
	end

	if expanded then
		add_line("", nil)
		if child_user_prompt and child_user_prompt ~= "" then
			local prompt_lines = vim.split(child_user_prompt, "\n", { plain = true })
			for i, pl in ipairs(prompt_lines) do
				if pl == "" then
					add_line("", nil)
				elseif i == 1 then
					add_line("  >> " .. pl, "Comment")
				else
					add_line("     " .. pl, "Comment")
				end
			end
		else
			add_line("  (task prompt not yet loaded)", "Comment")
		end

		if #summary > 0 then
			add_line("", nil)
			for _, item in ipairs(summary) do
				local item_state = item.state or {}
				local item_status = item_state.status or "pending"
				local prefix = item_status == "running" and (task_frame .. " ") or ""
				local item_hl = item_status == "error" and "DiagnosticError" or "Comment"
				add_line("  ↳ " .. prefix .. tool_labels.format_summary_item_label(item), item_hl)
			end
		end
	end

	if #result_lines > 1 then
		add_line("", nil)
	end

	local result = { lines = result_lines, highlights = result_highlights }
	return result
end

---Render a regular non-task tool through specialized widgets before generic I/O.
---@param tool_part table
---@param is_expanded boolean
---@return table { lines: string[], highlights: table[] }
function M.render_regular_tool(tool_part, is_expanded)
	tool_part = M.resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return { lines = {}, highlights = {} }
	end
	local tool_name = tostring(tool_part and tool_part.tool or "unknown")
	for _, render_tool in ipairs(REGULAR_TOOL_RENDERERS) do
		local result = render_tool(tool_part, is_expanded)
		if result then
			return result
		end
	end
	local result = render.render_tool_line(tool_part, is_expanded)
	return result
end

-- ─── Cursor position queries ──────────────────────────────────────────────────

---@return string|nil part_id
---@return table|nil task_info
function M.get_task_at_cursor()
	return widget_support.find_widget_context_at_cursor(state.tasks, vim.api.nvim_get_current_win())
end

---@return string|nil part_id
---@return table|nil tool_info
function M.get_tool_at_cursor()
	return widget_support.find_widget_context_at_cursor(state.tools, state.winid)
end

-- ─── In-place widget rendering ────────────────────────────────────────────────

---Re-render a task widget in place (expand/collapse).
---@param part_id string
function M.rerender_task(part_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local is_expanded = state.expanded_tasks[part_id] or false
	local tool_part = M.resolve_tool_part(pos)
	if not tool_part or not widget_support.replace_rendered_block(pos, M.render_task_tool(tool_part, is_expanded)) then
		return
	end
end

---Handle task toggle (expand/collapse child session content).
---@param part_id string
function M.handle_task_toggle(part_id)
	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	if state.expanded_tasks[part_id] then
		state.expanded_tasks[part_id] = nil
		M.rerender_task(part_id)
		return
	end

	state.expanded_tasks[part_id] = true

	if state.task_child_cache[part_id] then
		M.rerender_task(part_id)
		return
	end

	M.rerender_task(part_id)

	task_children.resolve_task_child_session_id(pos, function(err, child_session_id)
		if not state.expanded_tasks[part_id] then
			return
		end

		if err or not child_session_id then
			M.rerender_task(part_id)
			return
		end

		actions.load_session_messages(child_session_id, { limit = 100 }, function(fetch_err)
			vim.schedule(function()
				if fetch_err then
					state.expanded_tasks[part_id] = nil
					M.rerender_task(part_id)
					return
				end

				state.task_child_cache[part_id] = true
				M.rerender_task(part_id)
			end)
		end)
	end)
end

---Re-render a regular tool widget in place (expand/collapse).
---@param part_id string
function M.rerender_tool(part_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.tools[part_id]
	if not pos then
		return
	end

	local is_expanded = state.expanded_tools[part_id] or false
	local tool_part = M.resolve_tool_part(pos)
	if not tool_part or not widget_support.replace_rendered_block(pos, M.render_regular_tool(tool_part, is_expanded)) then
		return
	end
end

---Handle tool toggle (expand/collapse tool input/output).
---@param part_id string
function M.handle_tool_toggle(part_id)
	local pos = state.tools[part_id]
	if not pos then
		return
	end

	if state.expanded_tools[part_id] then
		state.expanded_tools[part_id] = nil
	else
		state.expanded_tools[part_id] = true
	end
	M.rerender_tool(part_id)
end

return M
