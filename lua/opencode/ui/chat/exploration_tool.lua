local cs = require("opencode.ui.chat.state")
return cs.factory("exploration_tool", function(view)
-- Each exploration leaf owns its compact and expanded presentation.
local M = { animation_line = 0 }

local style = cs.module(view, require("opencode.ui.chat.tool_style"))
local tool_group = cs.module(view, require("opencode.ui.chat.tool_group"))
local search = cs.module(view, require("opencode.ui.chat.search"))
local renderers = {
	read = cs.module(view, require("opencode.ui.chat.read")).render_tool,
	glob = search.render_tool,
	grep = search.render_tool,
	rg = cs.module(view, require("opencode.ui.chat.rg")).render_tool,
}

local text = require("opencode.util.text")

local function add_line(result, value, hl)
	cs.module(view, require("opencode.ui.chat.render")).add_panel_line(result, value, hl, { prefix = " " })
end

local function path(value)
	return text.is_present(value) and text.normalize_path(value) or "unknown"
end

local function render_summary(part, expanded, opts)
	local result = { lines = {}, highlights = {} }
	local state = part.state or {}
	local input = type(state.input) == "table" and state.input or {}
	local metadata = cs.module(view, require("opencode.ui.chat.render")).get_tool_metadata(part)
	local label
	if part.tool == "read" then
		label = (expanded and "↘ Read " or "→ Read ") .. path(input.filePath or input.path or metadata.path)
		local first, last = cs.module(view, require("opencode.ui.chat.read")).output_range(state.output)
		if first then
			label = label .. " · lines " .. first .. "–" .. last
		else
			if input.offset then
				label = label .. " offset=" .. tostring(input.offset)
			end
			if input.limit then
				label = label .. " limit=" .. tostring(input.limit)
			end
		end
	else
		label = (expanded and "○ " or "● ")
			.. (part.tool == "glob" and "Glob" or "Grep")
			.. ' "'
			.. tostring(input.pattern or metadata.pattern or "")
			.. '"'
		if text.is_present(input.path) then
			label = label .. " in " .. path(input.path)
		end
		if input.include then
			label = label .. " include=" .. tostring(input.include)
		end
		local count = tonumber(metadata.matches or metadata.count or state.matches or state.count)
		if count then
			-- Glob counts files; grep counts matching lines.
			local noun = part.tool == "glob" and (count == 1 and "file" or "files") or (count == 1 and "match" or "matches")
			label = label .. string.format(" (%d %s)", count, noun)
		end
	end
	local failed = tool_group.failed(part)
	-- Inside a group the group header carries the spinner.
	if not failed and not (opts or {}).grouped and tool_group.is_working(part) then
		label = label .. " " .. cs.module(view, require("opencode.ui.chat.tool_panel")).anim_frame()
	end
	add_line(result, label, failed and style.error_hl or style.header_hl)
	if expanded then
		return result
	end
	if failed then
		local err = type(state.error) == "table" and state.error.message or state.error
		style.add_error_lines(result, type(err) == "string" and err or nil)
	end
	if state.status == "completed" then
		for _, loaded in ipairs(type(metadata.loaded) == "table" and metadata.loaded or {}) do
			if type(loaded) == "string" then
				style.add_sub_line(result, "↳ Loaded " .. path(loaded))
			end
		end
	end
	return result
end

function M.render(part, expanded, opts)
	local renderer = renderers[part.tool]
	if not renderer then
		return nil
	end
	if part.tool == "rg" then
		return renderer(part, expanded, { exploration = true, grouped = (opts or {}).grouped })
	end
	local result = render_summary(part, expanded, opts)
	if not expanded then
		return result
	end
	local body = renderer(part, true, { body_only = true })
	if body._opencode_syntax_retry then result._opencode_syntax_retry = true end
	style.add_border(result)
	local offset = #result.lines
	vim.list_extend(result.lines, body.lines)
	for _, hl in ipairs(body.highlights) do
		local shifted = vim.tbl_extend("force", {}, hl)
		shifted.line = offset + (hl.line or 0)
		if hl.end_line then
			shifted.end_line = offset + hl.end_line
		end
		result.highlights[#result.highlights + 1] = shifted
	end
	style.add_border(result, true)
	style.contain_background(result)
	return result
end

return M

end)
