-- Dedicated ripgrep tool widget renderer for the chat buffer.

local M = {}

local tool_panel = require("opencode.ui.chat.tool_panel")
local text_util = require("opencode.util.text")

local panel_helpers = tool_panel.create_panel({
	prefix = "  ",
	default_hl = "OpenCodeRgValue",
})

local function ensure_highlights()
	-- Custom tool fields use plain text on the chat background, like the TUI.
	for name, source in pairs({
		OpenCodeRgLabel = "Comment",
		OpenCodeRgValue = "Normal",
		OpenCodeRgFailure = "DiagnosticError",
	}) do
		local hl = panel_helpers.get_hl(source)
		vim.api.nvim_set_hl(0, name, { fg = hl.fg, italic = false })
	end
end

require("opencode.ui.highlights").register("opencode.ui.chat.rg", ensure_highlights)

---@param value any
---@return string
local function stringify(value)
	if text_util.is_nil(value) then
		return ""
	end
	if type(value) == "table" then
		if type(value.output) == "string" then
			return value.output
		end
		if type(value.content) == "string" then
			return value.content
		end
		return vim.inspect(value)
	end
	return tostring(value)
end

---@param value any
---@return string
local function normalize_text(value)
	return text_util.normalize_text(value, stringify)
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
	local label = key .. ": "
	local indent = string.rep(" ", #label)
	for i, line in ipairs(vim.split(value, "\n", { plain = true })) do
		local _, _, rows = panel_helpers.add_raw_line(result, line, hl_group, {
			body_prefix = i == 1 and label or indent,
			continuation_prefix = indent,
		})
		if i == 1 then
			panel_helpers.highlight_text(result, rows, label, "OpenCodeRgLabel")
		end
	end
end

local function render_header(result, args, status, has_error)
	local summary = {}
	for _, arg in ipairs(args) do
		summary[#summary + 1] = arg.key .. "=" .. arg.value:gsub("\n", "\\n")
	end
	local icon = has_error and "✗" or (status == "completed" and "✓" or "│")
	local header = icon .. " rg" .. (#summary > 0 and " [" .. table.concat(summary, ", ") .. "]" or "")
	local header_hl = has_error and "OpenCodeRgFailure"
		or (status == "completed" and "OpenCodeRgLabel" or "OpenCodeRgValue")
	panel_helpers.add_line(result, header, header_hl, { prefix = "" })
end

---@param tool_part table
---@param expanded boolean
---@return table|nil result
function M.render_tool(tool_part, expanded)
	if type(tool_part) ~= "table" or tool_part.tool ~= "rg" then
		return nil
	end

	local ctx = tool_panel.context(tool_part)
	local body = text_util.trim_edge_newlines(normalize_text(ctx.output))
	local error_body = text_util.trim_edge_newlines(normalize_text(ctx.error))
	local output_is_error = body:match("^ripgrep error:") ~= nil
	local has_error = ctx.status == "error" or error_body ~= "" or output_is_error

	local result = panel_helpers.result()
	local args = arguments(ctx.input, ctx.metadata)
	render_header(result, args, ctx.status, has_error)
	-- The collapsed custom tool is only its summary. Opening it reveals all
	-- fields, with the complete output aligned below the arguments.
	if expanded then
		for _, arg in ipairs(args) do
			render_field(result, arg.key, arg.value)
		end
		if body == "" and ctx.status == "completed" and not has_error then
			body = "No matches found."
		end
		if body ~= "" then
			render_field(result, "output", body, output_is_error and "OpenCodeRgFailure" or nil)
		end
		if error_body ~= "" then
			render_field(result, "error", error_body, "OpenCodeRgFailure")
		end
	end
	panel_helpers.add_separator(result)
	return result
end

return M
