-- Skill tool widget renderer for the chat buffer.

local M = { animation_line = 0 }

local tool_panel = require("opencode.ui.chat.tool_panel")
local tool_group = require("opencode.ui.chat.tool_group")
local style = require("opencode.ui.chat.tool_style")
local render = require("opencode.ui.chat.render")
local text_util = require("opencode.util.text")
local locale = require("opencode.util.locale")
local panel = style.panel

---@param value any
---@return string
local function stringify(value)
	if type(value) == "table" then
		return text_util.first_string(value.output, value.content, value.text, value.message) or ""
	end
	return type(value) == "string" and value or ""
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

local trim_edge_newlines = text_util.trim_edge_newlines

local normalize_path = text_util.normalize_path

---@param text string
---@return string
local function unquote(text)
	text = vim.trim(text or "")
	text = text:gsub("^['\"]", ""):gsub("['\"]$", "")
	return text
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
local function find_skill(name, by_id)
	if type(name) ~= "string" or name == "" then
		return nil
	end

	local ok, sync = pcall(require, "opencode.sync")
	if not ok or type(sync.get_skills) ~= "function" then
		return nil
	end

	local skills = sync.get_skills()
	for _, skill in pairs(type(skills) == "table" and skills or {}) do
		if type(skill) == "table" and ((by_id and skill.id == name) or (not by_id and skill.name == name)) then
			return skill
		end
	end
	return nil
end

local function get_input_names(input, metadata)
	input = type(input) == "table" and input or {}
	local name = first_nonempty_trimmed_text(input.name, metadata.name)
	if name == "" then
		local skill = find_skill(input.id, true)
		name = first_nonempty_trimmed_text(skill and skill.name, input.id)
	end
	return name ~= "" and { name } or {}
end

local function attachment_name(part)
	local skill = find_skill(part.skillID, true)
	local name = first_nonempty_trimmed_text(part.name, skill and skill.name, part.skillID)
	return name ~= "" and name or "unknown", skill
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
		extract_frontmatter_description(parsed.body)
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

local function resolve_context(part, with_body)
	local ctx = tool_panel.context(part)
	local structured = type(ctx.output) == "table" and ctx.output or {}
	local metadata = vim.tbl_extend("keep", ctx.metadata, structured)
	local names = get_input_names(ctx.input, metadata)
	-- The usual native input already identifies the skill; folded rows and cache
	-- lookups should not rescan potentially long instruction bodies.
	local parsed = (with_body or #names == 0) and parse_skill_output(first_nonempty_text(ctx.output)) or {}
	local name = resolve_display_name(names, parsed, metadata)
	return ctx, metadata, parsed, name ~= "" and name or "unknown"
end

-- Catalog details can arrive after a completed call has already been rendered.
function M.cache_key(part)
	if type(part) ~= "table" then return "" end
	if part.type == "skill" then
		local name = attachment_name(part)
		return vim.json.encode({ name })
	end
	local _, _, _, name = resolve_context(part)
	local skill = find_skill(name) or {}
	return vim.json.encode({ name, skill.description or "", skill.location or "" })
end

local function clip(value, width)
	if width <= 0 then return "" end
	value = render.sanitize_buffer_line(value:gsub("%s+", " "))
	if vim.fn.strdisplaywidth(value) <= width then return value end
	local low, high = 0, vim.fn.strchars(value)
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(value, 0, middle)) <= width - 1 then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(value, 0, low) .. "…"
end

local function add_header(result, name, expanded, opts)
	local working, failed = opts.working, opts.failed
	local suffix = opts.status and (" · " .. opts.status) or failed and " · Failed" or ""
	local time = type(opts.time) == "table" and opts.time or {}
	local start = tonumber(time.created or time.start)
	local finish = tonumber(time.completed or time["end"])
	if not working and start and finish and finish >= start then
		suffix = suffix .. " · " .. locale.duration(finish - start)
	end
	local spinner = working and (" " .. tool_panel.anim_frame()) or ""
	local width = math.max(1, render.get_chat_text_width() - 1)
	local prefix = (expanded and "↘" or "→") .. ' Skill "'
	if vim.fn.strdisplaywidth(prefix .. suffix .. spinner .. '"') >= width then suffix = "" end
	local available = width - vim.fn.strdisplaywidth(prefix .. suffix .. spinner .. '"')
	local header = available > 0 and (prefix .. clip(name, available) .. '"' .. suffix)
		or clip(prefix .. name .. '"', width - vim.fn.strdisplaywidth(spinner))
	render.add_panel_line(result, header .. spinner, failed and style.error_hl or style.header_hl, { prefix = " " })
end

local function add_details(result, name, parsed, metadata, source_only)
	local source_name = source_only and first_nonempty_trimmed_text(parsed.name, name) or name
	panel.add_line(result, "Skill: " .. source_name)
	local description = source_only and extract_frontmatter_description(parsed.body) or resolve_description(name, parsed, metadata)
	local dir = source_only and (parsed.dir or "") or resolve_dir(name, parsed, metadata)
	if description ~= "" then panel.add_line(result, description) end
	if dir ~= "" then panel.add_line(result, "Base: " .. normalize_path(dir), style.border_hl) end
	if #parsed.files > 0 then
		panel.add_line(result, "Files: " .. tostring(#parsed.files) .. " sampled", style.border_hl)
		for _, filepath in ipairs(parsed.files) do
			panel.add_line(result, normalize_path(filepath), style.border_hl)
		end
	end
end

local function render_skill(name, parsed, metadata, expanded, opts)
	local working, failed, error_body = opts.working, opts.failed, opts.error_body or ""
	local result = panel.result()
	add_header(result, name, expanded, opts)
	if not expanded then return result end

	style.add_border(result)
	add_details(result, name, parsed, metadata, opts.source_only)
	local body = trim_edge_newlines(strip_markdown_frontmatter(parsed.body))
	if body ~= "" then
		panel.add_blank(result)
		tool_panel.add_markdown_body(result, body, { panel = panel, prefix = style.prefix })
	end
	if error_body ~= "" then
		panel.add_blank(result)
		tool_panel.add_raw_body(result, error_body, { panel = panel, prefix = style.prefix, hl_group = style.body_error_hl })
	elseif body == "" then
		panel.add_blank(result)
		panel.add_line(result, opts.empty_text or (failed and "Skill failed" or working and "Loading skill…" or "No instructions returned"),
			failed and style.body_error_hl or style.border_hl)
	end
	style.add_border(result, true)
	style.contain_background(result)
	return result
end

function M.render_tool(part, expanded)
	if type(part) ~= "table" or part.tool ~= "skill" then return nil end
	local ctx, metadata, parsed, name = resolve_context(part, expanded)
	return render_skill(name, parsed, metadata, expanded, {
		working = tool_group.is_working(part), failed = tool_group.failed(part), time = ctx.state.time,
		error_body = trim_edge_newlines(first_nonempty_text(ctx.error)),
	})
end

-- Attachments are server-projected snapshots, not tool executions. A textual
-- payload (even an empty one) confirms attachment; the catalog only names them.
function M.render_attachment(part, expanded)
	if type(part) ~= "table" or part.type ~= "skill" then return nil end
	local name = attachment_name(part)
	local loaded = type(part.text) == "string"
	local parsed = expanded and parse_skill_output(loaded and first_nonempty_text(part.text) or "") or {}
	return render_skill(name, parsed, {}, expanded, {
		status = loaded and "Attached" or "Unconfirmed", source_only = true,
		empty_text = loaded and "No instructions returned" or "Skill instructions are not available in this message",
	})
end

M.render = M.render_tool
return M
