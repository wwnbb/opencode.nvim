-- Each exploration leaf owns its compact and expanded presentation.
local M = {}

local function add_line(result, text, hl, prefix)
	require("opencode.ui.chat.render").add_panel_line(result, text, hl, { prefix = prefix or "" })
end

local function path(value)
	return type(value) == "string" and vim.fn.fnamemodify(value, ":~:.") or "unknown"
end

local function render_summary(part)
	local result = { lines = {}, highlights = {} }
	local state = part.state or {}
	local input = type(state.input) == "table" and state.input or {}
	local metadata = require("opencode.ui.chat.render").get_tool_metadata(part)
	local label
	if part.tool == "read" then
		label = "→ Read " .. path(input.filePath or input.path or metadata.path)
	else
		label = '✱ ' .. (part.tool == "glob" and "Glob" or "Grep") .. ' "' .. tostring(input.pattern or "") .. '"'
		if input.path then label = label .. " in " .. path(input.path) end
		local count = tonumber(metadata.matches or metadata.count)
		if count then label = label .. string.format(" (%d %s)", count, count == 1 and "match" or "matches") end
	end
	local failed = state.status == "error" or state.error ~= nil
	add_line(result, label, failed and "OpenCodeActivityError" or "OpenCodeExplore")
	if failed then
		local err = type(state.error) == "table" and state.error.message or state.error
		for _, line in ipairs(vim.split(tostring(err or "Tool failed"), "\n", { plain = true })) do
			add_line(result, line, "OpenCodeActivityError", "   ")
		end
	end
	if state.status == "completed" then
		for _, loaded in ipairs(type(metadata.loaded) == "table" and metadata.loaded or {}) do
			if type(loaded) == "string" then add_line(result, "↳ Loaded " .. path(loaded), "OpenCodeExplore", "   ") end
		end
	end
	return result
end

function M.render(part, expanded)
	local result
	if part.tool == "rg" then
		result = require("opencode.ui.chat.rg").render_tool(part, expanded)
	elseif not expanded then
		return render_summary(part)
	elseif part.tool == "read" then
		result = require("opencode.ui.chat.read").render_tool(part, true)
	else
		result = require("opencode.ui.chat.search").render_tool(part, true)
	end
	-- Separators belong to the containing block, not individual tree leaves.
	if result.lines[#result.lines] == "" then table.remove(result.lines) end
	return result
end

return M
