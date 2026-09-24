-- Each exploration leaf owns its compact and expanded presentation.
local M = {}

local style = require("opencode.ui.chat.exploration_style")
local search = require("opencode.ui.chat.search")
local renderers = {
	read = require("opencode.ui.chat.read").render_tool,
	glob = search.render_tool,
	grep = search.render_tool,
	rg = require("opencode.ui.chat.rg").render_tool,
}

function M.supports(tool)
	return renderers[tool] ~= nil
end

local function add_line(result, text, hl, prefix)
	require("opencode.ui.chat.render").add_panel_line(result, text, hl, { prefix = " " .. (prefix or "") })
end

local function path(value)
	return type(value) == "string" and vim.fn.fnamemodify(value, ":~:.") or "unknown"
end

local function render_summary(part, expanded)
	local result = { lines = {}, highlights = {} }
	local state = part.state or {}
	local input = type(state.input) == "table" and state.input or {}
	local metadata = require("opencode.ui.chat.render").get_tool_metadata(part)
	local label
	if part.tool == "read" then
		label = "→ Read " .. path(input.filePath or input.path or metadata.path)
		local first, last = require("opencode.ui.chat.read").output_range(state.output)
		if first then
			label = label .. " · lines " .. first .. "–" .. last
		else
			if input.offset then label = label .. " offset=" .. tostring(input.offset) end
			if input.limit then label = label .. " limit=" .. tostring(input.limit) end
		end
	else
		label = '✱ ' .. (part.tool == "glob" and "Glob" or "Grep") .. ' "' .. tostring(input.pattern or metadata.pattern or "") .. '"'
		if input.path then label = label .. " in " .. path(input.path) end
		if input.include then label = label .. " include=" .. tostring(input.include) end
		local count = tonumber(metadata.matches or metadata.count or state.matches or state.count)
		if count then label = label .. string.format(" (%d %s)", count, count == 1 and "match" or "matches") end
	end
	local failed = state.status == "error" or state.error ~= nil
	add_line(result, label, failed and style.error_hl or style.header_hl)
	if expanded then return result end
	if failed then
		local err = type(state.error) == "table" and state.error.message or state.error
		for _, line in ipairs(vim.split(tostring(err or "Tool failed"), "\n", { plain = true })) do
			add_line(result, line, style.error_hl, "    ")
		end
	end
	if state.status == "completed" then
		for _, loaded in ipairs(type(metadata.loaded) == "table" and metadata.loaded or {}) do
			if type(loaded) == "string" then add_line(result, "↳ Loaded " .. path(loaded), style.header_hl, "    ") end
		end
	end
	return result
end

function M.render(part, expanded)
	local renderer = renderers[part.tool]
	if not renderer then return nil end
	if part.tool == "rg" then
		return renderer(part, expanded, { exploration = true })
	end
	local result = render_summary(part, expanded)
	if not expanded then return result end
	local body = renderer(part, true, { body_only = true })
	style.add_border(result)
	local offset = #result.lines
	vim.list_extend(result.lines, body.lines)
	for _, hl in ipairs(body.highlights) do
		local shifted = vim.tbl_extend("force", {}, hl)
		shifted.line = offset + (hl.line or 0)
		if hl.end_line then shifted.end_line = offset + hl.end_line end
		result.highlights[#result.highlights + 1] = shifted
	end
	style.add_border(result, true)
	style.contain_background(result)
	return result
end

return M
