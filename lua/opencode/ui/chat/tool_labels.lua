-- Pure label/summary formatting for tool widgets.
-- Extracted from tasks.lua: tool icons, count/label helpers, and the
-- TUI-style one-line tool labels. No buffer access, no state mutation.

local M = {}

local render = require("opencode.ui.chat.render")
local chat_todos = require("opencode.ui.chat.todos")
local task_animation = require("opencode.ui.chat.task_animation")
local tool_part_resolver = require("opencode.ui.chat.tool_part")

-- ─── Tool icons & display helpers ────────────────────────────────────────────

local TOOL_ICONS = {
	bash = "$",
	glob = "✱",
	rg = "✱",
	read = "→",
	grep = "✱",
	list = "→",
	write = "←",
	edit = "←",
	webfetch = "%",
	websearch = "◈",
	codesearch = "◇",
	task = "◉",
	todolist = "⊙",
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
function M.normalize_count(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local text = vim.trim(value)
		if text ~= "" then
			return tonumber(text)
		end
	end
	if type(value) == "table" then
		local count = 0
		for _ in pairs(value) do
			count = count + 1
		end
		if count > 0 then
			return count
		end
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
function M.format_toolcall_count(count)
	return tostring(count) .. " " .. (count == 1 and "toolcall" or "toolcalls")
end

---@param tool_part table
---@return string|nil progress
local function format_todo_progress(tool_part)
	local todos = chat_todos.extract_tool_todos(tool_part)
	if #todos == 0 then
		return nil
	end
	local completed = 0
	for _, todo in ipairs(todos) do
		if todo.status == "completed" then
			completed = completed + 1
		end
	end
	return string.format("%d/%d done", completed, #todos)
end

---@param metadata table
---@return number|nil
function M.get_metadata_toolcall_count(metadata)
	for _, key in ipairs({
		"toolcalls",
		"toolCalls",
		"tool_calls",
		"toolCallCount",
		"tool_call_count",
		"calls",
		"callCount",
		"call_count",
	}) do
		local count = M.normalize_count(metadata[key])
		if count ~= nil then
			return count
		end
	end
	return nil
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

---Truncate a long path to its last 37 characters prefixed by "..." (max 40).
---@param path string
---@return string
local function truncate_path_end(path)
	if #path <= 40 then
		return path
	end
	return "..." .. path:sub(-37)
end

---Resolve the ripgrep match count across known metadata key spellings.
---@param metadata table
---@return number|nil
local function rg_match_count(metadata)
	return M.normalize_count(metadata.matches)
		or M.normalize_count(metadata.matchCount)
		or M.normalize_count(metadata.match_count)
		or M.normalize_count(metadata.count)
end

-- Format a task child-tool label, matching the TUI's concise "Tool title" row.
---@param item table  { tool: string, state: { status: string, title: string|nil, input: table|nil } }
---@return string label
function M.format_summary_item_label(item)
	item = type(item) == "table" and item or {}
	local tool_name = tostring(item.tool or "unknown")
	local item_state = type(item.state) == "table" and item.state or {}
	local item_status = item_state.status or "pending"
	local metadata = vim.tbl_deep_extend(
		"force",
		{},
		type(item.metadata) == "table" and item.metadata or {},
		type(item_state.metadata) == "table" and item_state.metadata or {}
	)
	local input = item_state.input
	if type(input) ~= "table" then
		input = item.input
	end
	if type(input) ~= "table" then
		input = metadata.input
	end
	if type(input) == "table" then
		input = vim.tbl_deep_extend(
			"force",
			{},
			type(metadata.input) == "table" and metadata.input or {},
			type(item.input) == "table" and item.input or {},
			type(item_state.input) == "table" and item_state.input or {}
		)
	elseif input == nil then
		input = {}
	end
	local input_table = type(input) == "table" and input or {}
	if chat_todos.is_todo_tool(tool_name) then
		local progress = format_todo_progress(item)
		local action = chat_todos.is_todo_read_tool(tool_name) and "Read Todos" or "Update Todos"
		return progress and (action .. " " .. progress) or action
	end

	-- Prefer the server-supplied title while it describes visible activity.
	local title = (item_status == "completed" or item_status == "running") and trim_string(item_state.title) or ""
	if title and title ~= "" then
		return render.format_title(tool_name) .. " " .. truncate_label(title, 52)
	end

	-- Tool-specific fallback
	if tool_name == "read" then
		local fp = input_table.filePath or input_table.file_path or ""
		if fp ~= "" then
			return "Read " .. truncate_path_end(fp)
		end
	elseif tool_name == "write" then
		local fp = input_table.filePath or input_table.file_path or ""
		if fp ~= "" then
			return "Write " .. truncate_path_end(fp)
		end
	elseif tool_name == "edit" then
		local fp = input_table.filePath or input_table.file_path or ""
		if fp ~= "" then
			return "Edit " .. truncate_path_end(fp)
		end
	elseif tool_name == "bash" then
		local d = input_table.description or ""
		if d ~= "" then
			if #d > 40 then
				d = d:sub(1, 37) .. "..."
			end
			return "Bash " .. d
		end
	elseif tool_name == "glob" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local count = M.normalize_count(metadata.count)
			local suffix = count and (" (" .. format_match_count(count) .. ")") or ""
			return "Glob " .. pat .. suffix
		end
	elseif tool_name == "grep" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local matches = M.normalize_count(metadata.matches)
			local suffix = matches and (" (" .. format_match_count(matches) .. ")") or ""
			return "Grep " .. pat .. suffix
		end
	elseif tool_name == "rg" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local matches = rg_match_count(metadata)
			local suffix = matches and (" (" .. format_match_count(matches) .. ")") or ""
			return "Ripgrep " .. pat .. suffix
		end
	elseif tool_name == "task" then
		local agent = input_table.subagent_type or ""
		local d = input_table.description or ""
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
function M.find_current_summary_item(summary)
	for i = #summary, 1, -1 do
		local item = summary[i]
		local item_state = type(item and item.state) == "table" and item.state or {}
		local status = item_state.status or "pending"
		local title = trim_string(item_state.title)
		if status == "running" or status == "completed" then
			if title ~= "" then
				return item
			end

			local label = trim_string(M.format_summary_item_label(item))
			local generic = render.format_title(tostring(item and item.tool or "unknown"))
			if label ~= "" and label ~= generic then
				return item
			end
		end
	end
	return nil
end

---@param state_time table|nil
---@return string|nil duration
function M.format_state_duration(state_time)
	if type(state_time) ~= "table" then
		return nil
	end

	local start_time = M.normalize_count(state_time.start or state_time.created)
	local end_time = M.normalize_count(state_time["end"] or state_time.completed or state_time.updated)
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
	tool_part = tool_part_resolver.resolve(tool_part)
	local tool_name = tool_part.tool or "unknown"
	local tool_status = tool_part.state and tool_part.state.status or "pending"
	local icon = get_tool_icon(tool_name)
	local input = tool_part.state and tool_part.state.input or {}
	local metadata = render.get_tool_metadata(tool_part)

	if tool_name == "glob" then
		local pattern = input.pattern or ""
		local count = M.normalize_count(metadata.count) or 0
		if tool_status == "completed" then
			return string.format('%s Glob "%s" (%s)', icon, pattern, format_match_count(count))
		end
		return "~ Finding files..."
	elseif tool_name == "grep" then
		local pattern = input.pattern or ""
		local matches = M.normalize_count(metadata.matches) or 0
		if tool_status == "completed" then
			return string.format('%s Grep "%s" (%s)', icon, pattern, format_match_count(matches))
		end
		return "~ Searching content..."
	elseif tool_name == "rg" then
		local pattern = input.pattern or ""
		local matches = rg_match_count(metadata)
		if tool_status == "completed" then
			if matches then
				return string.format('%s Ripgrep "%s" (%s)', icon, pattern, format_match_count(matches))
			end
			return string.format('%s Ripgrep "%s"', icon, pattern)
		end
		return "~ Searching content..."
	elseif tool_name == "read" then
		local filepath = input.filePath or input.file_path or ""
		filepath = truncate_path_end(filepath)
		if tool_status == "completed" then
			return string.format("%s Read %s", icon, filepath)
		end
		return "~ Reading file..."
	elseif tool_name == "write" then
		local filepath = input.filePath or input.file_path or ""
		filepath = truncate_path_end(filepath)
		if tool_status == "completed" then
			return string.format("%s Wrote %s", icon, filepath)
		end
		return "~ Preparing write..."
	elseif tool_name == "edit" then
		local filepath = input.filePath or input.file_path or ""
		filepath = truncate_path_end(filepath)
		if tool_status == "completed" then
			return string.format("%s Edit %s", icon, filepath)
		end
		return "~ Preparing edit..."
	elseif tool_name == "bash" then
		local desc = input.description or "Shell"
		if tool_status == "completed" then
			return string.format("# %s", desc)
		end
		return "~ Writing command..."
	elseif chat_todos.is_todo_tool(tool_name) then
		if tool_status == "completed" then
			local progress = format_todo_progress(tool_part)
			local action = chat_todos.is_todo_read_tool(tool_name) and "Read Todos" or "Updated Todos"
			return progress and string.format("%s %s %s", icon, action, progress)
				or string.format("%s %s", icon, action)
		end
		return chat_todos.is_todo_read_tool(tool_name) and "~ Reading todos..." or "~ Updating todos..."
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
		return "~ Loading skill..."
	elseif tool_name == "task" then
		local subagent = input.subagent_type or "unknown"
		local desc = input.description or ""
		local agent_label = render.format_title(subagent)
		if desc ~= "" and tool_status ~= "pending" then
			local prefix = task_animation.get_task_status_icon(tool_status)
			return string.format("%s %s Task – %s", prefix, agent_label, desc)
		end
		if task_animation.is_task_working(tool_status) then
			return string.format("%s Delegating...", task_animation.get_task_anim_frame())
		end
		return string.format("%s %s Task", task_animation.get_task_status_icon(tool_status), agent_label)
	else
		if tool_status == "completed" then
			return string.format("%s %s", icon, tool_name)
		end
		return string.format("~ %s...", tool_name)
	end
end

return M
