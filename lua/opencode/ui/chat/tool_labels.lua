local cs = require("opencode.ui.chat.state")
return cs.factory("tool_labels", function(view)
-- Pure label/summary formatting for tool widgets.
-- Extracted from tasks.lua: count/label helpers, durations and the
-- TUI-style one-line tool labels. No buffer access, no state mutation.

local M = {}

local render = cs.module(view, require("opencode.ui.chat.render"))
local text_util = require("opencode.util.text")
local tool_names = require("opencode.util.tool_names")
local locale = require("opencode.util.locale")

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
---@param noun? "match"|"file"
---@return string
local function format_match_count(count, noun)
	if noun == "file" then return tostring(count) .. " " .. (count == 1 and "file" or "files") end
	return tostring(count) .. " " .. (count == 1 and "match" or "matches")
end

---@param count number
---@return string
function M.format_toolcall_count(count)
	return tostring(count) .. " " .. (count == 1 and "tool call" or "tool calls")
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

---@param input table
---@param metadata table
---@return string
local function get_skill_name(input, metadata)
	return trim_string((type(input) == "table" and input.name) or metadata.name)
end

---@param text string
---@param max_len number
---@return string
local function truncate_label(text, max_len)
	return text_util.truncate(text, max_len, "…")
end

---A path as rows show it, keeping its last 39 characters after "…" (max 40).
---@param path string
---@return string
local function truncate_path_end(path)
	path = text_util.normalize_path(path)
	local length = vim.fn.strchars(path)
	if length <= 40 then
		return path
	end
	return "…" .. vim.fn.strcharpart(path, length - 39)
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
	local metadata = render.get_tool_metadata(item)
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
	-- Prefer the server-supplied title while it describes visible activity.
	local title = (item_status == "completed" or item_status == "running") and trim_string(item_state.title) or ""
	if title and title ~= "" then
		return tool_names.display_name(tool_name) .. " " .. truncate_label(title, 52)
	end

	-- Tool-specific fallback
	if tool_name == "read" or tool_name == "write" or tool_name == "edit" then
		local fp = input_table.path or input_table.filePath or input_table.file_path or ""
		if fp ~= "" then
			return tool_names.display_name(tool_name) .. " " .. truncate_path_end(fp)
		end
	elseif tool_name == "bash" then
		local d = trim_string(input_table.description)
		if d == "" then d = trim_string(input_table.command) end
		if d ~= "" then
			return tool_names.display_name(tool_name) .. " " .. truncate_label(render.sanitize_buffer_line(d), 40)
		end
	elseif tool_name == "glob" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local count = M.normalize_count(metadata.count)
			local suffix = count and (" (" .. format_match_count(count, "file") .. ")") or ""
			return 'Glob "' .. pat .. '"' .. suffix
		end
	elseif tool_name == "grep" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local matches = M.normalize_count(metadata.matches)
			local suffix = matches and (" (" .. format_match_count(matches) .. ")") or ""
			return 'Grep "' .. pat .. '"' .. suffix
		end
	elseif tool_name == "rg" then
		local pat = input_table.pattern or ""
		if pat ~= "" then
			local matches = rg_match_count(metadata)
			local suffix = matches and (" (" .. format_match_count(matches) .. ")") or ""
			return 'Ripgrep "' .. pat .. '"' .. suffix
		end
	elseif tool_name == "task" then
		local agent = input_table.subagent_type or ""
		local d = input_table.description or ""
		if agent ~= "" then
			return render.format_title(agent) .. " Task" .. (d ~= "" and (" · " .. d) or "")
		end
	elseif tool_name == "skill" then
		local name = get_skill_name(input, metadata)
		if name ~= "" then
			return 'Skill "' .. truncate_label(name, 40) .. '"'
		end
	end

	-- Generic: the tool's display name
	return tool_names.display_name(tool_name)
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
			local generic = tool_names.display_name(tostring(item and item.tool or "unknown"))
			if label ~= "" and label ~= generic then
				return item
			end
		end
	end
	return nil
end

---Elapsed time of a task as every row shows it (locale.duration).
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
	return locale.duration(math.floor(end_time - start_time + 0.5))
end

return M

end)
