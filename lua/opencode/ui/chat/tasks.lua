-- Task and tool widget management for the chat buffer.
-- Covers: animation timer, task/tool rendering, expand/collapse, child-session resolution.

local M = {}

local NuiText = require("nui.text")
local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns
local render = require("opencode.ui.chat.render")

-- ─── Animation ────────────────────────────────────────────────────────────────

local TASK_ANIM_FRAMES = { "|", "/", "-", "\\" }

function M.get_task_anim_frame()
	return TASK_ANIM_FRAMES[state.task_anim_frame] or TASK_ANIM_FRAMES[1]
end

local function tick_task_anim_frame()
	state.task_anim_frame = state.task_anim_frame + 1
	if state.task_anim_frame > #TASK_ANIM_FRAMES then
		state.task_anim_frame = 1
	end
end

function M.stop_task_animation_timer()
	if not state.task_anim_timer then
		return
	end
	if vim.uv.is_closing(state.task_anim_timer) then
		state.task_anim_timer = nil
		return
	end
	state.task_anim_timer:stop()
	state.task_anim_timer:close()
	state.task_anim_timer = nil
end

function M.has_active_task_rows()
	for _, pos in pairs(state.tasks) do
		local status = pos
			and pos.tool_part
			and pos.tool_part.state
			and pos.tool_part.state.status
			or "pending"
		if status == "pending" or status == "running" then
			return true
		end
	end
	return false
end

function M.start_task_animation_timer()
	if state.task_anim_timer then
		return
	end

	local timer = vim.uv.new_timer()
	if not timer then
		return
	end

	state.task_anim_timer = timer
	timer:start(
		120,
		120,
		vim.schedule_wrap(function()
			if not state.visible then
				return
			end

			local ok_state, app_state = pcall(require, "opencode.state")
			if not ok_state then
				return
			end
			local status = app_state.get_status()
			if status ~= "streaming" and status ~= "thinking" then
				return
			end

			if not M.has_active_task_rows() then
				return
			end

			tick_task_anim_frame()
			require("opencode.ui.chat").schedule_render()
		end)
	)
end

-- ─── Tool icons & display helpers ────────────────────────────────────────────

local TOOL_ICONS = {
	bash = "$",
	glob = "✱",
	read = "→",
	grep = "✱",
	list = "→",
	write = "←",
	edit = "←",
	webfetch = "%",
	websearch = "◈",
	codesearch = "◇",
	task = "◉",
	todowrite = "⚙",
	todoread = "⊙",
	question = "→",
	apply_patch = "%",
}

local function get_tool_icon(tool_name)
	return TOOL_ICONS[tool_name] or "⚙"
end

-- Format a single tool display line (matches TUI InlineTool style).
function M.format_tool_line(tool_part)
	local tool_name = tool_part.tool or "unknown"
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local icon = get_tool_icon(tool_name)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)

	if tool_name == "glob" then
		local pattern = input.pattern or ""
		local count = metadata.count or 0
		if tool_status == "completed" then
			return string.format('%s Glob "%s" (%d matches)', icon, pattern, count)
		end
		return string.format("~ Finding files...")
	elseif tool_name == "grep" then
		local pattern = input.pattern or ""
		local matches = metadata.matches or 0
		if tool_status == "completed" then
			return string.format('%s Grep "%s" (%d matches)', icon, pattern, matches)
		end
		return string.format("~ Searching content...")
	elseif tool_name == "read" then
		local filepath = input.filePath or input.file_path or ""
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Read %s", icon, filepath)
		end
		return string.format("~ Reading file...")
	elseif tool_name == "write" then
		local filepath = input.filePath or input.file_path or ""
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Wrote %s", icon, filepath)
		end
		return string.format("~ Preparing write...")
	elseif tool_name == "edit" then
		local filepath = input.filePath or input.file_path or ""
		if #filepath > 40 then
			filepath = "..." .. filepath:sub(-37)
		end
		if tool_status == "completed" then
			return string.format("%s Edit %s", icon, filepath)
		end
		return string.format("~ Preparing edit...")
	elseif tool_name == "bash" then
		local desc = input.description or "Shell"
		if tool_status == "completed" then
			return string.format("# %s", desc)
		end
		return string.format("~ Writing command...")
	elseif tool_name == "todoread" or tool_name == "todowrite" then
		if tool_status == "completed" then
			return string.format("%s %s", icon, tool_name)
		end
		return string.format("~ Updating todos...")
	elseif tool_name == "task" then
		local subagent = input.subagent_type or "unknown"
		local desc = input.description or ""
		local agent_label = render.format_title(subagent)
		local complete = input.subagent_type or input.description
		if tool_status ~= "pending" and complete then
			return string.format('◉ %s Task "%s"', agent_label, desc)
		end
		return string.format("~ Delegating... %s", M.get_task_anim_frame())
	else
		if tool_status == "completed" then
			return string.format("%s %s", icon, tool_name)
		end
		return string.format("~ %s...", tool_name)
	end
end

-- Build renderable content from a child session's messages.
function M.build_child_session_content(session_id)
	local sync = require("opencode.sync")
	local messages = sync.get_messages(session_id)
	local result_lines = {}
	local result_highlights = {}

	local function add_line(text, hl_group)
		table.insert(result_lines, text)
		if hl_group then
			table.insert(result_highlights, {
				line = #result_lines - 1,
				col_start = 0,
				col_end = #text,
				hl_group = hl_group,
			})
		end
	end

	for _, message in ipairs(messages) do
		if message.role == "user" then
			local text = sync.get_message_text(message.id)
			if text and text ~= "" then
				local text_lines = vim.split(text, "\n", { plain = true })
				for i, line in ipairs(text_lines) do
					if i == 1 then
						add_line("  >> " .. line, "Special")
					else
						add_line("     " .. line, "Special")
					end
				end
			end
		elseif message.role == "assistant" then
			local tool_parts = sync.get_message_tools(message.id)
			for _, tp in ipairs(tool_parts) do
				local tool_line = M.format_tool_line(tp)
				add_line("  " .. tool_line, "Comment")
			end
			local text = sync.get_message_text(message.id)
			if text and text ~= "" then
				local text_lines = vim.split(text, "\n", { plain = true })
				for _, line in ipairs(text_lines) do
					add_line("  " .. line, nil)
				end
			end
		end
	end

	return { lines = result_lines, highlights = result_highlights }
end

-- Render a task tool part as multi-line display showing subagent activity.
function M.render_task_tool(tool_part, expanded, child_content)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local subagent = input.subagent_type or "unknown"
	local desc = input.description or ""
	local summary = render.normalize_task_summary(metadata.summary)

	if #summary == 0 then
		local child_session_id = metadata.sessionId or metadata.sessionID or metadata.childSessionID or metadata.child_session_id
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
									title = status == "completed" and part_state.title or nil,
								},
							})
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
	end

	local agent_label = render.format_title(subagent)
	local task_frame = M.get_task_anim_frame()
	local working = tool_status == "pending" or tool_status == "running"

	local result_lines = {}
	local result_highlights = {}

	local function add_line(text, hl_group)
		table.insert(result_lines, text)
		if hl_group then
			table.insert(result_highlights, {
				line = #result_lines - 1,
				col_start = 0,
				col_end = #text,
				hl_group = hl_group,
			})
		end
	end

	local complete = input.subagent_type or input.description
	if not complete then
		add_line("~ Delegating...", "Comment")
		return { lines = result_lines, highlights = result_highlights }
	end

	local count = #summary
	if count == 0 then
		local line = M.format_tool_line(tool_part)
		if working and not line:find(task_frame, 1, true) then
			line = line .. " " .. task_frame
		end
		local line_hl
		if tool_status == "error" then
			line_hl = "DiagnosticError"
		elseif working then
			line_hl = "Special"
		else
			line_hl = render.get_agent_hl(subagent)
		end
		add_line(line, line_hl)
		return { lines = result_lines, highlights = result_highlights }
	end

	local header_hl = tool_status == "error" and "DiagnosticError" or render.get_agent_hl(subagent)
	add_line(string.format("# %s Task", agent_label), header_hl)
	local status_prefix = working and (task_frame .. " ") or ""
	local detail_hl = working and "Special" or "Comment"
	add_line(string.format("  %s%s (%d toolcalls)", status_prefix, desc, count), detail_hl)

	for _, item in ipairs(summary) do
		local item_state = item.state or {}
		local item_status = item_state.status or "pending"
		local tool_name = tostring(item.tool or "unknown")
		local title = item_status == "completed" and tostring(item_state.title or "") or ""
		local icon
		if item_status == "error" then
			icon = "✖"
		elseif item_status == "running" then
			icon = task_frame
		elseif item_status == "completed" then
			icon = "●"
		else
			icon = "○"
		end
		local line = vim.trim(string.format("  ▸ %s %s %s", icon, tool_name, title))
		local line_hl
		if item_status == "error" then
			line_hl = "DiagnosticError"
		elseif item_status == "running" then
			line_hl = "Special"
		else
			line_hl = "Comment"
		end
		add_line(line, line_hl)
	end

	if expanded then
		local offset = #result_lines
		if child_content then
			for _, cl in ipairs(child_content.lines) do
				table.insert(result_lines, cl)
			end
			for _, hl in ipairs(child_content.highlights) do
				table.insert(result_highlights, {
					line = hl.line + offset,
					col_start = hl.col_start,
					col_end = hl.col_end,
					hl_group = hl.hl_group,
				})
			end
		else
			add_line("  (loading...)", "Comment")
		end
	end

	return { lines = result_lines, highlights = result_highlights }
end

-- ─── Child session resolution ─────────────────────────────────────────────────

---@param tool_part table
---@return string|nil
local function get_task_child_session_id(tool_part)
	local metadata = render.get_tool_metadata(tool_part)
	return metadata.sessionId or metadata.sessionID or metadata.childSessionID or metadata.child_session_id
end

---@param children any
---@param input table
---@param start_time number|nil
---@return string|nil
local function pick_child_session_id(children, input, start_time)
	if type(children) ~= "table" or #children == 0 then
		return nil
	end

	local desc = type(input.description) == "string" and input.description or nil
	local subagent = type(input.subagent_type) == "string" and input.subagent_type or nil
	local candidates = {}

	for _, child in ipairs(children) do
		if type(child) == "table" and type(child.id) == "string" and child.id ~= "" then
			table.insert(candidates, child)
		end
	end

	if #candidates == 0 then
		return nil
	end

	local function score(child)
		local title = type(child.title) == "string" and child.title or ""
		local created = child.time and child.time.created or 0
		local updated = child.time and child.time.updated or created
		local value = 0

		if desc and desc ~= "" and title:find(desc, 1, true) then
			value = value + 2
		end

		if subagent and subagent ~= "" then
			local marker = "@" .. subagent .. " subagent"
			if title:find(marker, 1, true) then
				value = value + 3
			end
		end

		if type(start_time) == "number" and start_time > 0 and created > 0 then
			local delta = math.abs(created - start_time)
			if delta <= 120000 then
				value = value + 2
			end
		end

		return value, updated, created
	end

	table.sort(candidates, function(a, b)
		local a_score, a_updated, a_created = score(a)
		local b_score, b_updated, b_created = score(b)

		if a_score ~= b_score then
			return a_score > b_score
		end
		if a_updated ~= b_updated then
			return a_updated > b_updated
		end
		if a_created ~= b_created then
			return a_created > b_created
		end
		return a.id > b.id
	end)

	return candidates[1] and candidates[1].id or nil
end

---@param tool_part table
---@param callback function(err: any, child_session_id: string|nil)
function M.resolve_task_child_session_id(tool_part, callback)
	local child_session_id = get_task_child_session_id(tool_part)
	if child_session_id then
		callback(nil, child_session_id)
		return
	end

	local ok_state, app_state = pcall(require, "opencode.state")
	local ok_client, client = pcall(require, "opencode.client")
	if not ok_state or not ok_client then
		callback("Missing required modules", nil)
		return
	end

	local current = app_state.get_session()
	if not current or not current.id then
		callback(nil, nil)
		return
	end

	local input = tool_part and tool_part.state and tool_part.state.input or {}
	local start_time = tool_part and tool_part.state and tool_part.state.time and tool_part.state.time.start or nil

	client.get_session_children(current.id, function(err, children)
		vim.schedule(function()
			if err then
				callback(err, nil)
				return
			end
			callback(nil, pick_child_session_id(children, input, start_time))
		end)
	end)
end

-- ─── Cursor position queries ──────────────────────────────────────────────────

---@return string|nil part_id
---@return table|nil task_info
function M.get_task_at_cursor()
	local winid = vim.api.nvim_get_current_win()
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(winid)
	local cursor_line = cursor[1] - 1

	for part_id, pos in pairs(state.tasks) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line then
			return part_id, pos
		end
	end

	return nil, nil
end

---@return string|nil part_id
---@return table|nil tool_info
function M.get_tool_at_cursor()
	if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return nil, nil
	end

	local cursor = vim.api.nvim_win_get_cursor(state.winid)
	local cursor_line = cursor[1] - 1

	for part_id, pos in pairs(state.tools) do
		if cursor_line >= pos.start_line and cursor_line <= pos.end_line then
			return part_id, pos
		end
	end

	return nil, nil
end

-- ─── In-place widget rendering ────────────────────────────────────────────────

local function apply_result_highlights(result, pos)
	for _, hl in ipairs(result.highlights) do
		local end_col = hl.col_end
		if end_col == -1 then
			local l = vim.api.nvim_buf_get_lines(
				state.bufnr,
				pos.start_line + hl.line,
				pos.start_line + hl.line + 1,
				false
			)[1]
			end_col = l and #l or 0
		end
		pcall(vim.api.nvim_buf_set_extmark, state.bufnr, chat_hl_ns, pos.start_line + hl.line, hl.col_start, {
			end_col = end_col,
			hl_group = hl.hl_group,
		})
	end
end

local function shift_all_after(anchor_start, delta, skip_task_id, skip_tool_id)
	if delta == 0 then
		return
	end
	for id, qpos in pairs(state.questions) do
		if qpos.start_line > anchor_start then
			state.questions[id].start_line = qpos.start_line + delta
			state.questions[id].end_line = qpos.end_line + delta
		end
	end
	for id, ppos in pairs(state.permissions) do
		if ppos.start_line > anchor_start then
			state.permissions[id].start_line = ppos.start_line + delta
			state.permissions[id].end_line = ppos.end_line + delta
		end
	end
	for id, epos in pairs(state.edits) do
		if epos.start_line > anchor_start then
			state.edits[id].start_line = epos.start_line + delta
			state.edits[id].end_line = epos.end_line + delta
		end
	end
	for id, tpos in pairs(state.tasks) do
		if id ~= skip_task_id and tpos.start_line > anchor_start then
			state.tasks[id].start_line = tpos.start_line + delta
			state.tasks[id].end_line = tpos.end_line + delta
		end
	end
	for id, tlpos in pairs(state.tools) do
		if id ~= skip_tool_id and tlpos.start_line > anchor_start then
			state.tools[id].start_line = tlpos.start_line + delta
			state.tools[id].end_line = tlpos.end_line + delta
		end
	end
end

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
	local cached = state.task_child_cache[part_id]
	local result = M.render_task_tool(pos.tool_part, is_expanded, cached)

	local old_line_count = pos.end_line - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	apply_result_highlights(result, pos)
	vim.bo[state.bufnr].modifiable = false

	state.tasks[part_id].end_line = pos.start_line + new_line_count - 1
	shift_all_after(pos.start_line, delta, part_id, nil)
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

	M.resolve_task_child_session_id(pos.tool_part, function(err, child_session_id)
		if not state.expanded_tasks[part_id] then
			return
		end

		if err or not child_session_id then
			M.rerender_task(part_id)
			return
		end

		local client = require("opencode.client")
		local sync = require("opencode.sync")

		client.get_messages(child_session_id, {}, function(fetch_err, response)
			vim.schedule(function()
				if fetch_err then
					state.expanded_tasks[part_id] = nil
					M.rerender_task(part_id)
					return
				end

				if response and type(response) == "table" then
					for _, msg_with_parts in ipairs(response) do
						local info = msg_with_parts.info
						if info then
							info.sessionID = child_session_id
							sync.handle_message_updated(info)
						end
						local parts = msg_with_parts.parts
						if parts then
							for _, part in ipairs(parts) do
								sync.handle_part_updated(part)
							end
						end
					end
				end

				state.task_child_cache[part_id] = M.build_child_session_content(child_session_id)
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
	local result = render.render_tool_line(pos.tool_part, is_expanded)

	local old_line_count = pos.end_line - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	apply_result_highlights(result, pos)
	vim.bo[state.bufnr].modifiable = false

	state.tools[part_id].end_line = pos.start_line + new_line_count - 1
	shift_all_after(pos.start_line, delta, nil, part_id)
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
