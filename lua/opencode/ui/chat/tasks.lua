-- Task and tool widget management for the chat buffer.
-- Covers: animation timer, task/tool rendering, expand/collapse, child-session resolution.

local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local chat_hl_ns = cs.chat_hl_ns
local render = require("opencode.ui.chat.render")
local chat_todos = require("opencode.ui.chat.todos")
local chat_bash = require("opencode.ui.chat.bash")
local chat_read = require("opencode.ui.chat.read")
local chat_skill = require("opencode.ui.chat.skill")
local chat_search = require("opencode.ui.chat.search")
local chat_file_edit_results = require("opencode.ui.chat.file_edit_results")
local edit_state = require("opencode.edit.state")

-- ─── Animation ────────────────────────────────────────────────────────────────

local TASK_ANIM_FRAMES = { "⠋", "⠙", "⠹", "⠸" }
local TASK_COMPLETE_ICON = "│"
local TASK_ERROR_ICON = "✗"
local TASK_HIGHLIGHT_PRIORITY = 4200

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
	for _, pos in pairs(state.tools) do
		local tool_part = pos and pos.tool_part
		local is_animated_tool = tool_part
			and (
				tool_part.tool == "bash"
				or tool_part.tool == "read"
				or tool_part.tool == "skill"
				or tool_part.tool == "glob"
				or tool_part.tool == "grep"
			)
		local status = tool_part
			and is_animated_tool
			and tool_part.state
			and tool_part.state.status
			or "pending"
		if is_animated_tool and (status == "pending" or status == "running") then
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

			if edit_state.has_pending_edits() then
				return
			end

			if not M.has_active_task_rows() then
				M.stop_task_animation_timer()
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
	skill = "→",
}

local function get_tool_icon(tool_name)
	return TOOL_ICONS[tool_name] or "⚙"
end

---@param value any
---@return number|nil
local function normalize_count(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" and value ~= "" then
		return tonumber(value)
	end
	return nil
end

---@param count number
---@return string
local function format_match_count(count)
	return tostring(count) .. " " .. (count == 1 and "match" or "matches")
end

---@param count number
---@return string
local function format_toolcall_count(count)
	return tostring(count) .. " " .. (count == 1 and "toolcall" or "toolcalls")
end

---@param metadata table
---@return number|nil
local function get_metadata_toolcall_count(metadata)
	return normalize_count(metadata.toolcalls)
		or normalize_count(metadata.toolCalls)
		or normalize_count(metadata.calls)
end

---@param value any
---@return string
local function trim_string(value)
	if type(value) ~= "string" then
		return ""
	end
	return vim.trim(value)
end

---@param value any
---@return string
local function skill_name_from_value(value)
	if type(value) == "table" then
		for _, key in ipairs({ "name", "skill", "skillName", "skill_name", "value", "label" }) do
			local text = trim_string(value[key])
			if text ~= "" then
				return text
			end
		end
		return ""
	end
	if type(value) ~= "string" then
		return ""
	end

	local text = trim_string(value)
	if text == "" then
		return ""
	end

	return text:match('"name"%s*:%s*"([^"]+)"')
		or text:match("'name'%s*:%s*'([^']+)'")
		or (text:sub(1, 1) == "{" and "")
		or text:match("^load_skill%s+%[(.-)%]$")
		or text:match("^load_skill%s+(.+)$")
		or text
end

---@param input table|string
---@param metadata table
---@param title string|nil
---@param raw string|nil
---@return string
local function get_skill_name(input, metadata, title, raw)
	local from_title = type(title) == "string" and title:match("Loaded skill:%s*(.+)") or nil
	local name = skill_name_from_value(input)
	if name == "" then
		name = skill_name_from_value(metadata.name)
	end
	if name == "" then
		name = skill_name_from_value(metadata.skill)
	end
	if name == "" then
		name = trim_string(from_title)
	end
	if name == "" then
		name = skill_name_from_value(raw)
	end
	name = name:gsub("^%[", ""):gsub("%]$", "")
	return name
end

---@param text string
---@param max_len number
---@return string
local function truncate_label(text, max_len)
	if #text <= max_len then
		return text
	end
	return text:sub(1, max_len - 3) .. "..."
end

-- Format a task child-tool label, matching the TUI's concise "Tool title" row.
---@param item table  { tool: string, state: { status: string, title: string|nil, input: table|nil } }
---@return string label
local function format_summary_item_label(item)
	local tool_name = tostring(item.tool or "unknown")
	local item_state = item.state or {}
	local item_status = item_state.status or "pending"
	local input = item_state.input or {}
	local metadata = item_state.metadata or item.metadata or {}

	-- Prefer the server-supplied title while it describes visible activity.
	local title = (item_status == "completed" or item_status == "running") and trim_string(item_state.title) or ""
	if title and title ~= "" then
		return render.format_title(tool_name) .. " " .. truncate_label(title, 52)
	end

	-- Tool-specific fallback
	if tool_name == "read" then
		local fp = input.filePath or input.file_path or ""
		if fp ~= "" then
			if #fp > 40 then fp = "..." .. fp:sub(-37) end
			return "Read " .. fp
		end
	elseif tool_name == "write" then
		local fp = input.filePath or input.file_path or ""
		if fp ~= "" then
			if #fp > 40 then fp = "..." .. fp:sub(-37) end
			return "Write " .. fp
		end
	elseif tool_name == "edit" then
		local fp = input.filePath or input.file_path or ""
		if fp ~= "" then
			if #fp > 40 then fp = "..." .. fp:sub(-37) end
			return "Edit " .. fp
		end
	elseif tool_name == "bash" then
		local d = input.description or ""
		if d ~= "" then
			if #d > 40 then d = d:sub(1, 37) .. "..." end
			return "Bash " .. d
		end
	elseif tool_name == "glob" then
		local pat = input.pattern or ""
		if pat ~= "" then
			local count = normalize_count(metadata.count)
			local suffix = count and (" (" .. format_match_count(count) .. ")") or ""
			return "Glob " .. pat .. suffix
		end
	elseif tool_name == "grep" then
		local pat = input.pattern or ""
		if pat ~= "" then
			local matches = normalize_count(metadata.matches)
			local suffix = matches and (" (" .. format_match_count(matches) .. ")") or ""
			return "Grep " .. pat .. suffix
		end
	elseif tool_name == "task" then
		local agent = input.subagent_type or ""
		local d = input.description or ""
		if agent ~= "" then
			return render.format_title(agent) .. " Task" .. (d ~= "" and (" — " .. d) or "")
		end
	elseif tool_name == "skill" then
		local name = get_skill_name(input, metadata, item_state.title, item_state.raw)
		if name ~= "" then
			return 'Skill "' .. truncate_label(name, 40) .. '"'
		end
	end

	-- Generic: capitalised tool name
	return render.format_title(tool_name)
end

---@param summary table[]
---@return table|nil item
local function find_current_summary_item(summary)
	for i = #summary, 1, -1 do
		local item = summary[i]
		local item_state = item and item.state or {}
		local status = item_state.status or "pending"
		local title = trim_string(item_state.title)
		if (status == "running" or status == "completed") and title ~= "" then
			return item
		end
	end
	return nil
end

---@param state_time table|nil
---@return string|nil duration
local function format_state_duration(state_time)
	if type(state_time) ~= "table" then
		return nil
	end

	local start_time = normalize_count(state_time.start or state_time.created)
	local end_time = normalize_count(state_time["end"] or state_time.completed or state_time.updated)
	if not start_time or not end_time or end_time <= start_time then
		return nil
	end

	local duration = end_time - start_time
	if duration >= 1000 then
		duration = duration / 1000
	end
	if duration < 1 then
		return string.format("%dms", math.floor(duration * 1000 + 0.5))
	end
	if duration < 10 then
		return string.format("%.1fs", duration)
	end
	if duration < 60 then
		return string.format("%ds", math.floor(duration + 0.5))
	end

	local minutes = math.floor(duration / 60)
	local seconds = math.floor(duration % 60 + 0.5)
	return string.format("%dm%02ds", minutes, seconds)
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
		local count = normalize_count(metadata.count) or 0
		if tool_status == "completed" then
			return string.format('%s Glob "%s" (%s)', icon, pattern, format_match_count(count))
		end
		return string.format("~ Finding files...")
	elseif tool_name == "grep" then
		local pattern = input.pattern or ""
		local matches = normalize_count(metadata.matches) or 0
		if tool_status == "completed" then
			return string.format('%s Grep "%s" (%s)', icon, pattern, format_match_count(matches))
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
	elseif tool_name == "skill" then
		local raw = tool_part.state and tool_part.state.raw or nil
		local title = tool_part.state and tool_part.state.title or nil
		local name = get_skill_name(input, metadata, title, raw)
		if tool_status == "completed" then
			if name ~= "" then
				return string.format('%s Skill "%s"', icon, name)
			end
			return string.format("%s Skill", icon)
		end
		if name ~= "" then
			return string.format('~ Loading skill "%s"...', name)
		end
		return string.format("~ Loading skill...")
	elseif tool_name == "task" then
		local subagent = input.subagent_type or "unknown"
		local desc = input.description or ""
		local agent_label = render.format_title(subagent)
		if desc ~= "" and tool_status ~= "pending" then
			local prefix = tool_status == "running" and M.get_task_anim_frame() or TASK_COMPLETE_ICON
			if tool_status == "error" then
				prefix = TASK_ERROR_ICON
			end
			return string.format("%s %s Task – %s", prefix, agent_label, desc)
		end
		return string.format("%s Delegating...", M.get_task_anim_frame())
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
				priority = TASK_HIGHLIGHT_PRIORITY,
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

-- Render a task tool part as a compact TUI-style subagent summary.
--
-- Layout (collapsed, running):
--   ⠋ Explore Task — Inventory user commands
--     ↳ Grep nvim_create_user_command
--
-- Layout (collapsed, completed):
--   │ Explore Task — Inventory user commands
--     └ 1 toolcall · 1.2s
--
-- Layout (expanded, after O):
--   │ Explore Task — Inventory user commands
--     └ 1 toolcall · 1.2s
--
--     >> <first line of child user message>
--
--     ↳ Grep nvim_create_user_command
--
function M.render_task_tool(tool_part, expanded, _child_content)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local subagent = input.subagent_type or "unknown"
	local desc = input.description or ""
	local summary = render.normalize_task_summary(metadata.summary)

	-- ── Try to derive summary from child session when server hasn't sent one ──
	local child_session_id = metadata.sessionId
		or metadata.sessionID
		or metadata.childSessionID
		or metadata.child_session_id
	if #summary == 0 then
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

	-- ── Gather the first child user message for the expanded prompt preview ──
	local child_user_prompt = nil
	if child_session_id then
		local ok_sync2, sync2 = pcall(require, "opencode.sync")
		if ok_sync2 then
			local child_msgs = sync2.get_messages(child_session_id)
			for _, msg in ipairs(child_msgs) do
				-- First user message → the task prompt
				if msg.role == "user" and not child_user_prompt then
					child_user_prompt = sync2.get_message_text(msg.id)
					if child_user_prompt == "" then child_user_prompt = nil end
				end
				if child_user_prompt then break end
			end
		end
	end

	local agent_label = render.format_title(subagent)
	local task_frame = M.get_task_anim_frame()
	local working = tool_status == "pending" or tool_status == "running"
	local completed = tool_status == "completed"
	local metadata_count = get_metadata_toolcall_count(metadata) or 0
	local count = math.max(#summary, metadata_count)
	local duration = format_state_duration(tool_part.state and tool_part.state.time)

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
				priority = TASK_HIGHLIGHT_PRIORITY,
			})
		end
	end

	local function add_spans_line(segments)
		local line = {}
		local spans = {}
		local col = 0
		for _, segment in ipairs(segments) do
			local text = segment.text or ""
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
		local line = working and (task_frame .. " Delegating...") or (TASK_COMPLETE_ICON .. " " .. agent_label .. " Task")
		add_line(line, tool_status == "error" and "DiagnosticError" or "Comment")
		return { lines = result_lines, highlights = result_highlights }
	end

	local line_hl = "Comment"
	local task_icon = TASK_COMPLETE_ICON
	local agent_hl = render.get_agent_hl(subagent)
	if tool_status == "error" then
		line_hl = "DiagnosticError"
		task_icon = TASK_ERROR_ICON
	elseif working then
		task_icon = task_frame
	end

	add_task_header(task_icon, line_hl, agent_hl)

	if tool_status == "error" then
		local err = tool_part.state and tool_part.state.error or nil
		if err then
			add_line("  ✗ " .. tostring(err), "DiagnosticError")
		end
	elseif working and count > 0 then
		local current_item = find_current_summary_item(summary)
		if not current_item and #summary == 1 then
			current_item = summary[1]
		end
		if current_item then
			add_task_detail(format_summary_item_label(current_item), " · " .. format_toolcall_count(count))
		else
			add_line("  ↳ " .. format_toolcall_count(count), "Comment")
		end
	elseif completed and count > 0 then
		local suffix = duration and (" · " .. duration) or ""
		add_line("  └ " .. format_toolcall_count(count) .. suffix, "Comment")
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
				add_line("  ↳ " .. prefix .. format_summary_item_label(item), item_hl)
			end
		end
	end

	if #result_lines > 1 then
		add_line("", nil)
	end

	return { lines = result_lines, highlights = result_highlights }
end

---Render a regular non-task tool through specialized widgets before generic I/O.
---@param tool_part table
---@param is_expanded boolean
---@return table { lines: string[], highlights: table[] }
function M.render_regular_tool(tool_part, is_expanded)
	local result = not is_expanded and chat_todos.render_tool(tool_part) or nil
	result = result or chat_bash.render_tool(tool_part, is_expanded)
	result = result or chat_read.render_tool(tool_part, is_expanded)
	result = result or chat_skill.render_tool(tool_part, is_expanded)
	result = result or chat_search.render_tool(tool_part, is_expanded)
	result = result or chat_file_edit_results.render_tool(tool_part, is_expanded)
	return result or render.render_tool_line(tool_part, is_expanded)
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
	render.apply_extmark_highlights(state.bufnr, chat_hl_ns, result.highlights, pos.start_line)
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
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.end_line + 1)
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	apply_result_highlights(result, pos)
	vim.bo[state.bufnr].modifiable = false

	state.tasks[part_id].end_line = pos.start_line + new_line_count - 1
	state.tasks[part_id].highlights = result.highlights
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
	local result = M.render_regular_tool(pos.tool_part, is_expanded)

	local old_line_count = pos.end_line - pos.start_line + 1
	local new_line_count = #result.lines
	local delta = new_line_count - old_line_count

	vim.bo[state.bufnr].modifiable = true
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.end_line + 1)
	vim.api.nvim_buf_set_lines(state.bufnr, pos.start_line, pos.end_line + 1, false, result.lines)
	vim.api.nvim_buf_clear_namespace(state.bufnr, chat_hl_ns, pos.start_line, pos.start_line + new_line_count)
	apply_result_highlights(result, pos)
	vim.bo[state.bufnr].modifiable = false

	state.tools[part_id].end_line = pos.start_line + new_line_count - 1
	state.tools[part_id].highlights = result.highlights
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
