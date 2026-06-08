-- Skill tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local syntax = require("opencode.ui.syntax")
local text_util = require("opencode.util.text")

local MAX_COLLAPSED_OUTPUT_LINES = 6
local PANEL_PREFIX = tool_panel.PANEL_PREFIX
local PANEL_BORDER_HL = "OpenCodeSkillMuted"

local panel_helpers = tool_panel.create_panel({
	border_hl = PANEL_BORDER_HL,
	default_hl = "OpenCodeSkillOutput",
})
local add_panel_line = panel_helpers.add_line
local add_panel_raw_line = panel_helpers.add_raw_line
local add_panel_blank = panel_helpers.add_blank
local add_trailing_separator = panel_helpers.add_separator
local highlight_text = panel_helpers.highlight_text

local function ensure_highlights()
	panel_helpers.set_hl("OpenCodeSkillMuted", "Comment", "Normal")
	panel_helpers.set_hl("OpenCodeSkillName", "String", "Normal", { bold = true })
	panel_helpers.set_hl("OpenCodeSkillDescription", "Normal", nil)
	panel_helpers.set_hl("OpenCodeSkillPath", "Directory", "Normal")
	panel_helpers.set_hl("OpenCodeSkillOutput", "Normal", nil)
	panel_helpers.set_hl("OpenCodeSkillError", "DiagnosticError", "ErrorMsg")
end

---@param value any
---@return boolean
local function is_nil(value)
	return text_util.is_nil(value)
end

local function is_present(value)
	return text_util.is_present(value)
end

---@param value any
---@return string
local function stringify(value)
	if is_nil(value) then
		return ""
	end
	if type(value) == "string" then
		return value
	end
	if type(value) == "table" then
		if type(value.output) == "string" then
			return value.output
		end
		if type(value.text) == "string" then
			return value.text
		end
		if type(value.content) == "string" then
			return value.content
		end
		if #value > 0 then
			local lines = {}
			for _, item in ipairs(value) do
				local text
				if type(item) == "table" and item.type == "text" and type(item.text) == "string" then
					text = item.text
				elseif type(item) == "table" and item.type == "file" then
					text = "[file " .. tostring(item.name or item.uri or item.url or "") .. "]"
				else
					text = stringify(item)
				end
				if text ~= "" then
					table.insert(lines, text)
				end
			end
			return table.concat(lines, "\n")
		end
		return vim.inspect(value)
	end
	return tostring(value)
end

---@param ... any
---@return string
local function first_nonempty_text(...)
	return text_util.first_nonempty_text(stringify, ...)
end

---@param ... any
---@return string
local function first_nonempty_trimmed_text(...)
	return text_util.first_nonempty_trimmed_text(stringify, ...)
end

---@param text string
---@return string
local function trim_edge_newlines(text)
	return text_util.trim_edge_newlines(text)
end

---@param path string
---@return string
local function normalize_path(path)
	if not is_present(path) then
		return ""
	end

	local normalized = tostring(path)
	if normalized:match("^file://") then
		local ok, filepath = pcall(vim.uri_to_fname, normalized)
		if ok and filepath and filepath ~= "" then
			normalized = filepath
		end
	end
	return vim.fn.fnamemodify(normalized, ":~:.")
end

---@param text string
---@return string
local function unquote(text)
	text = vim.trim(text or "")
	text = text:gsub("^['\"]", ""):gsub("['\"]$", "")
	return text
end

---@param names string[]
---@param seen table<string, boolean>
---@param value any
local function add_skill_name(names, seen, value)
	if type(value) ~= "string" then
		return
	end

	local name = unquote(value)
	name = name:gsub("^%[", ""):gsub("%]$", "")
	if name == "" or seen[name] then
		return
	end

	seen[name] = true
	table.insert(names, name)
end

---@param names string[]
---@param seen table<string, boolean>
---@param value any
local function add_skill_names(names, seen, value)
	if type(value) == "table" then
		for _, key in ipairs({ "name", "skill", "skillName", "skill_name", "value", "label" }) do
			add_skill_names(names, seen, value[key])
		end
		for _, key in ipairs({ "names", "skills" }) do
			if type(value[key]) == "table" then
				for _, item in ipairs(value[key]) do
					add_skill_names(names, seen, item)
				end
			else
				add_skill_names(names, seen, value[key])
			end
		end
		return
	end

	if type(value) ~= "string" then
		return
	end

	local text = vim.trim(value)
	if text == "" then
		return
	end

	local json_name = text:match('"name"%s*:%s*"([^"]+)"') or text:match("'name'%s*:%s*'([^']+)'")
	if json_name then
		add_skill_name(names, seen, json_name)
		return
	end
	if text:sub(1, 1) == "{" then
		return
	end

	local load_args = text:match("^load_skill%s+%[(.-)%]$") or text:match("^load_skill%s+(.+)$")
	if load_args then
		text = load_args
	end

	if text:find(",", 1, true) then
		for part in text:gmatch("[^,]+") do
			add_skill_name(names, seen, part)
		end
		return
	end

	add_skill_name(names, seen, text)
end

---@param input table|string
---@param metadata table
---@return string[]
local function get_input_names(input, metadata)
	local names = {}
	local seen = {}
	add_skill_names(names, seen, input)
	add_skill_names(names, seen, metadata.name)
	add_skill_names(names, seen, metadata.skill)
	add_skill_names(names, seen, metadata.skills)
	return names
end

---@param value any
---@return string|nil
local function first_string(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

---@param name string
---@return table|nil
local function find_skill(name)
	if name == "" then
		return nil
	end

	local ok, sync = pcall(require, "opencode.sync")
	if not ok or type(sync.get_skills) ~= "function" then
		return nil
	end

	for _, skill in pairs(sync.get_skills() or {}) do
		if type(skill) == "table" and skill.name == name then
			return skill
		end
	end
	return nil
end

---@param text string
---@return string
local function strip_markdown_frontmatter(text)
	if not text:match("^%-%-%-\n") then
		return text
	end

	local finish = text:find("\n%-%-%-\n", 5)
	if not finish then
		return text
	end
	return text:sub(finish + 5)
end

---@param text string
---@return string
local function extract_frontmatter_description(text)
	local frontmatter = text:match("^%-%-%-\n(.-)\n%-%-%-")
	if not frontmatter then
		return ""
	end

	local description = frontmatter:match("\ndescription:%s*([^\n]+)") or frontmatter:match("^description:%s*([^\n]+)")
	return description and unquote(description) or ""
end

---@param body string
---@return string
local function first_body_sentence(body)
	body = strip_markdown_frontmatter(body)
	for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
		local text = vim.trim(line)
		if
			text ~= ""
			and not text:match("^#+%s")
			and not text:match("^<")
			and not text:match("^%-+%s*$")
			and not text:match("^Base directory for this skill:")
			and not text:match("^Relative paths in this skill")
			and not text:match("^Note: file list is sampled")
		then
			return text
		end
	end
	return ""
end

---@param attrs string
---@param key string
---@return string|nil
local function attr_value(attrs, key)
	return attrs:match(key .. '%s*=%s*"([^"]+)"') or attrs:match(key .. "%s*=%s*'([^']+)'")
end

---@param content string
---@return string body
---@return string dir
---@return string[] files
local function parse_skill_block_content(content)
	local files = {}
	for filepath in content:gmatch("<file>(.-)</file>") do
		if filepath ~= "" then
			table.insert(files, filepath)
		end
	end

	local dir = content:match("Base directory for this skill:%s*([^\n]+)") or ""
	local lines = {}
	local in_files = false
	for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
		if line:find("<skill_files>", 1, true) then
			in_files = true
		end

		local trimmed = vim.trim(line)
		if
			not in_files
			and not trimmed:match("^Base directory for this skill:")
			and not trimmed:match("^Relative paths in this skill")
			and not trimmed:match("^Note: file list is sampled")
		then
			table.insert(lines, line)
		end

		if line:find("</skill_files>", 1, true) then
			in_files = false
		end
	end

	local body = trim_edge_newlines(table.concat(lines, "\n"))
	body = body:gsub("^# Skill:[^\n]*\n?", "")
	body = trim_edge_newlines(body)
	return body, dir, files
end

---@param output string
---@return table parsed
local function parse_skill_output(output)
	local parsed = {
		name = nil,
		dir = nil,
		body = "",
		files = {},
		skills = {},
	}
	if output == "" then
		return parsed
	end

	for attrs, content in output:gmatch("<skill_content([^>]*)>\n?(.-)</skill_content>") do
		local body, dir, files = parse_skill_block_content(content)
		local name = attr_value(attrs, "name") or content:match("^# Skill:%s*([^\n]+)")
		table.insert(parsed.skills, {
			name = name,
			dir = dir,
			body = body,
			files = files,
			description = extract_frontmatter_description(body),
		})
	end

	if #parsed.skills == 0 then
		local body, dir, files = parse_skill_block_content(output)
		table.insert(parsed.skills, {
			name = output:match("^# Skill:%s*([^\n]+)"),
			dir = dir,
			body = body,
			files = files,
			description = extract_frontmatter_description(body),
		})
	end

	local primary = parsed.skills[1] or {}
	parsed.name = primary.name
	parsed.dir = primary.dir
	parsed.body = primary.body or ""
	for _, skill in ipairs(parsed.skills) do
		for _, filepath in ipairs(skill.files or {}) do
			table.insert(parsed.files, filepath)
		end
	end

	return parsed
end

---@param names string[]
---@param parsed table
---@param metadata table
---@return string
local function resolve_display_name(names, parsed, metadata)
	if #names > 0 then
		return table.concat(names, ", ")
	end

	return first_nonempty_trimmed_text(parsed.name, metadata.name)
end

---@param name string
---@param parsed table
---@param metadata table
---@return string
local function resolve_description(name, parsed, metadata)
	local skill = find_skill(name)
	local primary = parsed.skills and parsed.skills[1] or {}
	return first_nonempty_trimmed_text(
		metadata.description,
		skill and skill.description,
		primary.description,
		extract_frontmatter_description(parsed.body),
		first_body_sentence(parsed.body)
	)
end

---@param name string
---@param parsed table
---@param metadata table
---@return string
local function resolve_dir(name, parsed, metadata)
	local skill = find_skill(name)
	local location = skill and first_string(skill.location) or nil
	local location_dir = location and vim.fn.fnamemodify(location, ":h") or nil
	return first_nonempty_trimmed_text(metadata.dir, metadata.directory, metadata.path, parsed.dir, location_dir)
end

---@param count number
---@return string
local function line_count_label(count)
	return tostring(count) .. " instruction " .. (count == 1 and "line" or "lines")
end

---@param entries table[]
---@return number
local function count_nonempty_entries(entries)
	local count = 0
	for _, entry in ipairs(entries) do
		if entry.text ~= "" then
			count = count + 1
		end
	end
	return count
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "skill" then
		return nil
	end
	ensure_highlights()

	local ctx = tool_panel.context(tool_part)
	local input = ctx.input
	local metadata = ctx.metadata
	local status = ctx.status
	local working = ctx.working
	local output = first_nonempty_text(ctx.output)
	local error_body = trim_edge_newlines(first_nonempty_text(ctx.error))
	local parsed = parse_skill_output(output)
	local input_names = get_input_names(input, metadata)
	local name = resolve_display_name(input_names, parsed, metadata)

	if name == "" then
		name = "unknown"
	end

	local dir = resolve_dir(name, parsed, metadata)
	local description = resolve_description(name, parsed, metadata)
	local body = parsed.body

	local body_entries = {}
	tool_panel.append_entries(body_entries, body, "OpenCodeSkillOutput")
	tool_panel.append_error_entries(body_entries, error_body, "OpenCodeSkillError", "OpenCodeSkillOutput")

	local has_body = #body_entries > 0
	local has_overflow = has_body and #body_entries > MAX_COLLAPSED_OUTPUT_LINES
	local header = '# Skill "' .. name .. '"'
	if has_body then
		header = tool_panel.header(header, {
			fold = true,
			expanded = expanded,
			working = working,
		})
	elseif working then
		header = tool_panel.header(header, { working = true })
	end

	local header_hl = "OpenCodeSkillMuted"
	if status == "error" or error_body ~= "" then
		header_hl = "OpenCodeSkillError"
	elseif working then
		header_hl = "OpenCodeSkillName"
	end

	local result = panel_helpers.result()
	add_panel_blank(result)
	local _, _, header_rows = add_panel_line(result, header, header_hl)
	highlight_text(result, header_rows, '"' .. name .. '"', "OpenCodeSkillName")

	local has_details = description ~= "" or dir ~= "" or #parsed.files > 0
	if not has_details and #body_entries == 0 then
		add_panel_blank(result)
		add_trailing_separator(result)
		return result
	end

	add_panel_blank(result)

	if description ~= "" then
		add_panel_line(result, description, "OpenCodeSkillDescription")
	end

	if dir ~= "" then
		local display_dir = normalize_path(dir)
		local _, _, dir_rows = add_panel_line(result, "Base: " .. display_dir, "OpenCodeSkillMuted")
		highlight_text(result, dir_rows, display_dir, "OpenCodeSkillPath")
	end

	if #parsed.files > 0 then
		add_panel_line(result, "Files: " .. tostring(#parsed.files) .. " sampled", "OpenCodeSkillMuted")
		if expanded then
			for _, filepath in ipairs(parsed.files) do
				local display_path = normalize_path(filepath)
				local _, _, file_rows = add_panel_line(result, "  " .. display_path, "OpenCodeSkillMuted")
				highlight_text(result, file_rows, display_path, "OpenCodeSkillPath")
			end
		end
	end

	if has_details and has_body then
		add_panel_blank(result)
	end

	if not expanded and has_body and error_body == "" then
		local count = count_nonempty_entries(body_entries)
		local suffix = has_overflow and ", press O to expand" or ", press O to show"
		add_panel_line(result, line_count_label(count) .. suffix, "OpenCodeSkillMuted")
		add_panel_blank(result)
		add_trailing_separator(result)
		return result
	end

	local body_lang = syntax.detect_output_language(body, metadata) or "markdown"
	local body_start_line = nil
	local body_lines = {}
	local can_highlight_body = true
	panel_helpers.render_entries(result, body_entries, {
		expanded = expanded,
		max = MAX_COLLAPSED_OUTPUT_LINES,
		overflow_hl = "OpenCodeSkillMuted",
		render_entry = function(_, entry)
			if body_lang and entry.hl_group == "OpenCodeSkillOutput" then
				local line_index, _, rows = add_panel_raw_line(result, entry.text, entry.hl_group)
				body_start_line = body_start_line or line_index
				table.insert(body_lines, entry.text)
				if #rows > 1 then
					can_highlight_body = false
				end
			else
				panel_helpers.add_entry(result, entry)
			end
		end,
	})
	if body_lang and body_start_line and #body_lines > 0 and can_highlight_body then
		local body_text = table.concat(body_lines, "\n")
		if body_lang == "markdown" then
			syntax.add_markdown_highlights(result, body_text, {
				scope = "tools",
				line_start = body_start_line,
				col_offset = #PANEL_PREFIX,
				compat_markdown = false,
			})
		else
			syntax.add_highlights(result, body_text, body_lang, {
				scope = "tools",
				line_start = body_start_line,
				col_offset = #PANEL_PREFIX,
			})
		end
	end

	add_panel_blank(result)
	add_trailing_separator(result)
	return result
end

return M
