local cs = require("opencode.ui.chat.state")
return cs.factory("rg", function(view)
-- Dedicated ripgrep tool widget renderer for the chat buffer.

local M = {}

local tool_panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local text_util = require("opencode.util.text")
local output_style = cs.module(view, require("opencode.ui.chat.tool_style"))

---@param value any
---@return string
local function normalize_text(value)
	return text_util.normalize_text(value, tool_panel.stringify_output)
end

-- Lua tables do not retain the server's argument order. Keep the common search
-- fields first, followed by every other supplied option in a stable order.
local function arguments(input, metadata)
	local values = type(input) == "table" and vim.tbl_extend("force", {}, input) or {}
	if type(input) == "string" then
		values.pattern = input
	end
	for _, key in ipairs({ "pattern", "path" }) do
		if text_util.is_nil(values[key]) then
			values[key] = metadata[key]
		end
	end

	local result, seen = {}, {}
	local function add(key)
		seen[key] = true
		if text_util.is_nil(values[key]) then
			return
		end
		result[#result + 1] = { key = key, value = normalize_text(values[key]) }
	end
	for _, key in ipairs({ "pattern", "path", "glob", "context", "max_results" }) do
		add(key)
	end
	local keys = {}
	for key in pairs(values) do
		if type(key) == "string" and not seen[key] then
			keys[#keys + 1] = key
		end
	end
	table.sort(keys)
	for _, key in ipairs(keys) do
		add(key)
	end
	return result
end

-- Align multiline values and wrapped rows after the field label. Raw panel
-- rendering preserves ripgrep's indentation, context separators and blank lines.
local function render_field(result, key, value, hl_group)
	local panel = output_style.panel
	local label = key .. ": "
	local indent = string.rep(" ", #label)
	for i, line in ipairs(vim.split(value, "\n", { plain = true })) do
		local _, _, rows = panel.add_raw_line(result, line, hl_group, {
			body_prefix = i == 1 and label or indent,
			continuation_prefix = indent,
		})
		if i == 1 then
			panel.highlight_text(result, rows, label, output_style.border_hl)
		end
	end
end

local function render_header(result, args, has_error, expanded, spinner)
	local summary = {}
	for _, arg in ipairs(args) do
		summary[#summary + 1] = arg.key .. "=" .. arg.value:gsub("\n", "\\n")
	end
	local icon = expanded and "○" or "●"
	local header = icon .. " rg" .. (#summary > 0 and " [" .. table.concat(summary, ", ") .. "]" or "")
	if spinner then header = header .. " " .. spinner end
	cs.module(view, require("opencode.ui.chat.render")).add_panel_line(result, header,
		has_error and output_style.error_hl or output_style.header_hl, { prefix = " " })
end

---@param tool_part table
---@param expanded boolean
---@param opts? table { exploration?: boolean, grouped?: boolean }
---@return table|nil result
function M.render_tool(tool_part, expanded, opts)
	if type(tool_part) ~= "table" or tool_part.tool ~= "rg" then
		return nil
	end

	local ctx = tool_panel.context(tool_part)
	local body = text_util.trim_edge_newlines(normalize_text(ctx.output))
	local error_body = text_util.trim_edge_newlines(normalize_text(ctx.error))
	local output_is_error = body:match("^ripgrep error:") ~= nil
	local has_error = ctx.status == "error" or error_body ~= "" or output_is_error

	local result = { lines = {}, highlights = {} }
	local args = arguments(ctx.input, ctx.metadata)
	-- Inside a group the group header carries the spinner.
	local spinner = ctx.working and not has_error and not (opts or {}).grouped and tool_panel.anim_frame() or nil
	render_header(result, args, has_error, expanded, spinner)
	if not expanded then
		-- A folded call shows what failed, like the other exploration rows.
		if has_error then
			output_style.add_error_lines(result, error_body ~= "" and error_body or body, "Tool failed")
		end
	else
		-- Opening it reveals every field, then the complete output, inside the frame.
		output_style.add_border(result)
		for _, arg in ipairs(args) do
			render_field(result, arg.key, arg.value)
		end
		if body == "" and ctx.status == "completed" and not has_error then
			body = "No matches found."
		end
		if body ~= "" then
			if #args > 0 then output_style.panel.add_blank(result) end
			for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
				output_style.panel.add_raw_line(result, line, output_is_error and output_style.body_error_hl or nil)
			end
		end
		if error_body ~= "" then
			if #args > 0 or body ~= "" then output_style.panel.add_blank(result) end
			render_field(result, "error", error_body, output_style.body_error_hl)
		end
		output_style.add_border(result, true)
		output_style.contain_background(result)
	end
	if not (opts and opts.exploration) then
		result.lines[#result.lines + 1] = ""
	end
	return result
end

return M

end)
