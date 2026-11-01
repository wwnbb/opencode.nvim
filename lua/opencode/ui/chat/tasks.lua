local cs = require("opencode.ui.chat.state")
return cs.factory("tasks", function(view)
-- Task and tool widget facade for the chat buffer.
-- Rendering dispatch + task widget + expand/collapse toggles + cursor queries.
-- Animation lives in task_animation.lua, labels in tool_labels.lua,
-- child-session navigation in task_children.lua, block updates in widget_support.lua.

local M = {}

local state = view
local render = cs.module(view, require("opencode.ui.chat.render"))
local render_state = cs.module(view, require("opencode.ui.chat.render_state"))
local chat_bash = cs.module(view, require("opencode.ui.chat.bash"))
local chat_skill = cs.module(view, require("opencode.ui.chat.skill"))
local chat_file_edit_results = cs.module(view, require("opencode.ui.chat.file_edit_results"))
local widget_support = cs.module(view, require("opencode.ui.chat.widget_support"))
local task_animation = cs.module(view, require("opencode.ui.chat.task_animation"))
local tool_labels = cs.module(view, require("opencode.ui.chat.tool_labels"))
local task_children = cs.module(view, require("opencode.ui.chat.task_children"))
local tool_part = cs.module(view, require("opencode.ui.chat.tool_part"))
local tree = require("opencode.ui.chat.widget_tree")
local tool_group = cs.module(view, require("opencode.ui.chat.tool_group"))

-- Standalone leaves use the same navigation, cache and animation contracts as
-- grouped tools, without creating an activity container.
local TOOL_LEAF_RENDERERS = { skill = chat_skill, write = cs.module(view, require("opencode.ui.chat.write")) }

local function leaf_widget(part)
	if part.shell_notification then return cs.module(view, require("opencode.ui.chat.shell_notification")) end
	if part._editor_context then return cs.module(view, require("opencode.ui.chat.editor_context")) end
	if part.system_reminder then return cs.module(view, require("opencode.ui.chat.system_reminder")) end
	if part.instructions then return cs.module(view, require("opencode.ui.chat.instructions")) end
	return part.type == "skill" and chat_skill or TOOL_LEAF_RENDERERS[part.tool]
end

---@type (fun(part: table, is_expanded?: boolean, opts?: table): table|nil)[]
local REGULAR_TOOL_RENDERERS = {
	function(part)
		return require("opencode.ui.chat.question_result").render_tool(part, {
			width = render.get_chat_text_width(), render = render,
		})
	end,
	chat_bash.render_tool,
	chat_file_edit_results.render_tool,
}

---@param position table|nil
---@return table|nil
function M.resolve_tool_part(position)
	return tool_part.resolve(position)
end

function M.is_tool_leaf(part)
	return type(part) == "table" and (tool_group.kind(part) ~= nil or leaf_widget(part) ~= nil)
end

function M.tool_animation_line(part)
	if part.type == "skill" or part.shell_notification or part.system_reminder or part.instructions then return nil end
	local widget = leaf_widget(part)
	if widget then return widget.animation_line end
	return tool_group.animation_line(part)
end

function M.tool_cache_key(part)
	local widget = leaf_widget(part)
	if widget then return widget.cache_key and widget.cache_key(part) or "" end
	if part.tool == "bash" then return chat_bash.cache_key(part) end
	return tool_group.cache_key(part)
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


-- ─── Child session resolution (facade — implementation in task_children.lua) ──

M.ensure_task_child_loaded = task_children.ensure_task_child_loaded
M.resolve_task_child_session_id = task_children.resolve_task_child_session_id

---@param child_session_id string
---@return table|nil summary
---@return string|nil prompt
local function derive_task_child_data(child_session_id)
	local ok_sync, sync = pcall(require, "opencode.sync")
	if not ok_sync then
		return nil, nil
	end

	local revision = sync.get_task_summary_revision(child_session_id)
	local cached_summary, cached_prompt, found = render_state.task_summary_cache_get(child_session_id, revision)
	if found then
		return cached_summary, cached_prompt
	end

	local derived = {}
	local child_user_prompt = nil
	for _, message in ipairs(sync.get_messages(child_session_id)) do
		if message.role == "assistant" then
			for _, part in ipairs(sync.get_message_tools(message.id)) do
				local part_state = part.state or {}
				local metadata = render.get_tool_metadata(part)
				table.insert(derived, {
					id = part.id,
					messageID = message.id,
					sessionID = child_session_id,
					tool = part.tool,
					state = {
						status = part_state.status or "pending",
						title = part_state.title,
						input = part_state.input or {},
						metadata = metadata,
					},
					metadata = metadata,
				})
			end
		end
		if message.role == "user" and not child_user_prompt then
			local text = sync.get_message_text(message.id)
			if text ~= "" then
				child_user_prompt = text
			end
		end
	end
	table.sort(derived, function(a, b)
		return tostring(a.id or "") < tostring(b.id or "")
	end)

	render_state.task_summary_cache_put(child_session_id, revision, derived, child_user_prompt)
	return derived, child_user_prompt
end

-- A child session can appear under several Task invocations in one transcript.
local function scope_task_nodes(nodes, prefix, toggle_id)
	local scoped = {}
	for id, node in pairs(nodes or {}) do
		local copy = vim.tbl_extend("force", {}, node, { id = prefix .. id, toggle_id = toggle_id })
		copy.children = scope_task_nodes(node.children, prefix, toggle_id)
		scoped[copy.id] = copy
	end
	return scoped
end

local TASK_MUTED_HL, TASK_TEXT_HL, TASK_ERROR_HL = "OpenCodeTaskMuted", "OpenCodeTaskText", "OpenCodeTaskError"
require("opencode.ui.highlights").register("opencode.ui.chat.tasks", function()
	vim.api.nvim_set_hl(0, TASK_MUTED_HL, { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, TASK_TEXT_HL, { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, TASK_ERROR_HL, { default = true, link = "DiagnosticError" })
end)

-- Render a task tool part as a compact TUI-style subagent summary.
--
-- Layout (collapsed, running):
--   ⠋ Explore Task · Inventory user commands
--     ↳ Grep "nvim_create_user_command" · 1 tool call
--
-- Layout (collapsed, completed):
--   ✓ Explore Task · Inventory user commands
--     ↳ 1 tool call · 1.2s
--
-- Layout (expanded, after O):
--   ✓ Explore Task · Inventory user commands
--     ↳ 1 tool call · 1.2s
--
--     >> <first line of child user message>
--
--     ↳ Grep "nvim_create_user_command"
--
-- Every task ends with one blank row, like the other rows.
function M.render_task_tool(tool_part, expanded)
	tool_part = M.resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return { lines = {}, highlights = {} }
	end
	if tool_part.subagent_notification then
		return cs.module(view, require("opencode.ui.chat.subagent_notification")).render_tool(tool_part, expanded)
	end
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)
	local tool_status = task_animation.task_status(tool_part)
	local subagent = input.subagent_type or "unknown"
	local desc = input.description or ""
	local summary = render.normalize_task_summary(metadata.summary)

	-- ── Prefer live child-session tool activity when available ──
	local child_session_id = task_children.get_task_child_session_id(tool_part)
	local child_user_prompt = nil
	if child_session_id then
		local derived
		derived, child_user_prompt = derive_task_child_data(child_session_id)
		if derived and #derived > 0 then
			summary = derived
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
	local result = { lines = result_lines, highlights = result_highlights }

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
			{ text = " Task · " .. desc, hl_group = TASK_MUTED_HL },
		})
	end

	local function add_task_detail(label, suffix)
		local first = label:match("^%S+") or label
		local rest = label:sub(#first + 1)
		add_spans_line({
			{ text = "  ↳ ", hl_group = TASK_MUTED_HL },
			{ text = first, hl_group = TASK_TEXT_HL },
			{ text = rest, hl_group = TASK_TEXT_HL },
			{ text = suffix or "", hl_group = TASK_MUTED_HL },
		})
	end

	-- Still-initialising: no input yet
	if desc == "" then
		local line = working and (task_frame .. " Delegating…")
			or (task_animation.get_task_status_icon(tool_status) .. " " .. agent_label .. " Task")
		add_line(line, tool_status == "error" and TASK_ERROR_HL or TASK_MUTED_HL)
		add_line("", nil)
		return result
	end

	local line_hl = TASK_MUTED_HL
	local task_icon = task_animation.get_task_status_icon(tool_status)
	local agent_hl = render.get_agent_hl(subagent)
	if tool_status == "error" then
		line_hl = TASK_ERROR_HL
	end

	add_task_header(task_icon, line_hl, agent_hl)

	if tool_status == "error" then
		local err = tool_part.state and tool_part.state.error or nil
		if err then
			add_line("  ✗ " .. tostring(err), TASK_ERROR_HL)
		end
	elseif working and count > 0 then
		local current_item = tool_labels.find_current_summary_item(summary)
		if not current_item and #summary == 1 then
			current_item = summary[1]
		end
		if current_item then
			add_task_detail(tool_labels.format_summary_item_label(current_item), " · " .. tool_labels.format_toolcall_count(count))
		else
			add_line("  ↳ " .. tool_labels.format_toolcall_count(count), TASK_MUTED_HL)
		end
	elseif completed and count > 0 then
		local suffix = duration and (" · " .. duration) or ""
		add_line("  ↳ " .. tool_labels.format_toolcall_count(count) .. suffix, TASK_MUTED_HL)
	end

	if expanded then
		add_line("", nil)
		if child_user_prompt and child_user_prompt ~= "" then
			local prompt_lines = vim.split(child_user_prompt, "\n", { plain = true })
			for i, pl in ipairs(prompt_lines) do
				if pl == "" then
					add_line("", nil)
				elseif i == 1 then
					add_line("  >> " .. pl, TASK_MUTED_HL)
				else
					add_line("     " .. pl, TASK_MUTED_HL)
				end
			end
		else
			add_line("  (task prompt not yet loaded)", TASK_MUTED_HL)
		end

		if #summary > 0 then
			add_line("", nil)
			for index, item in ipairs(summary) do
				local item_state = item.state or {}
				local item_status = item_state.status or "pending"
				local prefix = item_status == "running" and (task_frame .. " ") or ""
				local item_hl = item_status == "error" and TASK_ERROR_HL or TASK_MUTED_HL
				local id = tool_part.id .. ":child:" .. tostring(item.id or index)
				local part = M.resolve_tool_part(item)
				local rendered = { lines = {}, highlights = {} }
				if state.expanded_tools[id] then
					rendered = M.render_regular_tool(part, true)
					rendered.children = scope_task_nodes(rendered.children, id .. ":", id)
				else
					render.add_panel_line(rendered, "↳ " .. prefix .. tool_labels.format_summary_item_label(item), item_hl, { prefix = "  " })
				end
				tree.append(result, { id = id, kind = "tool", tool_part = part,
					part_id = item.id, message_id = item.messageID, session_id = item.sessionID }, rendered)
			end
		end
	end

	add_line("", nil)
	return result
end

---Render a regular non-task tool through specialized widgets before generic I/O.
---@param tool_part table|nil
---@param is_expanded boolean
---@param opts? { separator_before?: boolean }
---@return table { lines: string[], highlights: table[] }
function M.render_regular_tool(tool_part, is_expanded, opts)
	tool_part = M.resolve_tool_part(tool_part)
	if type(tool_part) ~= "table" then
		return { lines = {}, highlights = {} }
	end
	local activity = cs.module(view, require("opencode.ui.chat.activity"))
	if tool_part.activity_group then
		return activity.render(tool_part.activity_group, state.expanded_tools[tool_part.activity_group.id], state.expanded_tools)
	end
	local widget = leaf_widget(tool_part)
	local render_leaf = widget and (tool_part.type == "skill" and widget.render_attachment or widget.render_tool)
	local result = render_leaf and render_leaf(tool_part, is_expanded) or tool_group.render_leaf(tool_part, is_expanded)
	if result then
		result.lines[#result.lines + 1] = ""
		return result
	end

	for _, render_tool in ipairs(REGULAR_TOOL_RENDERERS) do
		local result = render_tool(tool_part, is_expanded, opts)
		if result then
			return result
		end
	end
	return render.render_tool_line(tool_part, is_expanded)
end

-- ─── Cursor position queries ──────────────────────────────────────────────────

---@return string|nil part_id
---@return table|nil task_info
function M.get_task_at_cursor()
	return widget_support.find_widget_context_at_cursor(state.tasks, state.winid, function(pos) return pos.kind ~= "tool" end)
end

---@return string|nil part_id
---@return table|nil tool_info
---@return string|nil root_id
function M.get_tool_at_cursor()
	local id, pos, root_id = widget_support.find_widget_context_at_cursor(state.tools, state.winid)
	if id then return id, pos, root_id end
	return widget_support.find_widget_context_at_cursor(state.tasks, state.winid, function(node) return node.kind == "tool" end)
end

local function find_tool(part_id)
	local pos, root_id = tree.find(state.tools, part_id)
	if pos then return pos, root_id end
	pos, root_id = tree.find(state.tasks, part_id)
	return pos, root_id, true
end

-- ─── In-place widget rendering ────────────────────────────────────────────────

---Re-render a task widget in place (expand/collapse).
---@param part_id string
---@param focus_id? string child row to retain when its section closes
function M.rerender_task(part_id, focus_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local pos = state.tasks[part_id]
	if not pos then
		return
	end

	local is_expanded = state.expanded_tasks[part_id] or false
	local tool_part = M.resolve_tool_part(pos)
	local cursor = cs.module(view, require("opencode.ui.chat.cursor"))
	local context = cursor.capture_widget_cursor_context()
	local updated = tool_part ~= nil and widget_support.replace_rendered_block(pos, M.render_task_tool(tool_part, is_expanded))
	if updated and context then
		if focus_id and not tree.find(state.tasks, context.id) and tree.find(state.tasks, focus_id) then
			context.id, context.relative_line = focus_id, 0
		end
		cursor.restore_widget_cursor_context(context)
	end
	return updated
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
		tree.collapse(pos.children, state.expanded_tools)
		M.rerender_task(part_id)
		return
	end

	state.expanded_tasks[part_id] = true

	M.rerender_task(part_id)
	task_children.ensure_task_child_loaded(pos)
end

---Re-render a regular tool widget in place (expand/collapse).
---@param part_id string
function M.rerender_tool(part_id)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
		return
	end

	local _, root_id, task = find_tool(part_id)
	if task then return root_id and M.rerender_task(root_id, part_id) end
	local pos = root_id and state.tools[root_id]
	if not pos then
		return
	end
	-- Permissions attached below the row follow what it shows; the full render lays both out.
	if pos.attached then
		return false
	end

	local is_expanded = state.expanded_tools[root_id] or false
	local tool_part = M.resolve_tool_part(pos)
	local cursor = (pos.activity_group or pos.kind == "tool")
		and cs.module(view, require("opencode.ui.chat.cursor")).capture_widget_cursor_context()
	local updated = tool_part ~= nil and widget_support.replace_rendered_block(pos, M.render_regular_tool(tool_part, is_expanded, {
		separator_before = pos.separator_before,
	}))
	if updated and cursor then
		if not tree.find(state.tools, cursor.id) and tree.find(state.tools, part_id) then
			cursor.id, cursor.relative_line = part_id, 0
		end
		cs.module(view, require("opencode.ui.chat.cursor")).restore_widget_cursor_context(cursor)
	end
	return updated
end

---Handle tool toggle (expand/collapse tool input/output).
---@param part_id string
function M.handle_tool_toggle(part_id)
	local pos, root_id = find_tool(part_id)
	if not pos then
		return
	end
	-- Sections fold their own execute invocation, even inside an activity group.
	if pos.execute_action then
		part_id = pos.toggle_id or pos.part_id or root_id
		pos = find_tool(part_id) or state.tools[root_id]
	end

	local expanded = pos.activity_group and cs.module(view, require("opencode.ui.chat.activity")).is_expanded(pos.activity_group, state.expanded_tools[part_id])
		or state.expanded_tools[part_id] == true
	if expanded then
		state.expanded_tools[part_id] = nil
		if pos.activity_group and cs.module(view, require("opencode.ui.chat.activity")).is_expanded(pos.activity_group) then
			state.expanded_tools[part_id] = false
		end
		-- Collapsing a container closes its descendants as well. Merely hiding
		-- the chat or rebuilding its render surface does not change expansion.
		tree.collapse(pos.children, state.expanded_tools)
	else
		state.expanded_tools[part_id] = true
	end
	if not M.rerender_tool(part_id) then
		require("opencode.ui.chat.render_coordinator").request({ reason = "tool_toggle", session_id = cs.session(view).id })
	end
end

---Activate an execute section without changing the synchronized tool data.
function M.handle_tool_confirm(part_id, pos)
	if not pos or not pos.execute_action then return false end
	local part = M.resolve_tool_part(pos)
	if part then
		cs.module(view, require("opencode.ui.chat.execute_details")).open(part, { view = pos.execute_action })
	end
	return true
end

return M

end)
