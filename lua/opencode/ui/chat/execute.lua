local cs = require("opencode.ui.chat.state")
return cs.factory("execute", function(view)
-- Universal code-mode widget. Child calls come from server metadata; the
-- script's result belongs to execute, never to an individual MCP call.
local M = {}

local render = cs.module(view, require("opencode.ui.chat.render"))
local panel = cs.module(view, require("opencode.ui.chat.tool_panel"))
local text = require("opencode.util.text")
local tool_group = cs.module(view, require("opencode.ui.chat.tool_group"))
local list_style = cs.module(view, require("opencode.ui.chat.tool_style"))

M.animation_line = 0

-- The header row is a compact list header; the expanded calls use the shared frame.
local PREFIX = ""
local helpers = panel.create_panel({ prefix = PREFIX, blank_prefix = "", default_hl = list_style.output_hl })
require("opencode.ui.highlights").register("opencode.ui.chat.execute", function()
	-- Call markers inside the frame keep its CursorLine background.
	helpers.set_hl("OpenCodeExecuteSuccess", "DiagnosticOk", "Normal")
	helpers.set_hl("OpenCodeExecuteRunning", "DiagnosticWarn", "Normal")
end)

function M.section_id(part_id, section)
	return "execute:" .. tostring(part_id or "") .. ":" .. section
end

local function body_width()
	return math.max(1, math.min(100, render.get_chat_text_width()) - vim.fn.strdisplaywidth(PREFIX))
end

-- Keep headers and summaries to one screen row without cutting a UTF-8 byte.
local function clip(value, width)
	width = math.max(1, width or body_width())
	return text.truncate(render.expand_tabs(text.strip_ansi(tostring(value or "")), 0), width, "…")
end

local function add_line(result, value, hl)
	return helpers.add_raw_line(result, clip(value), hl)
end

local function section(result, part, name, start_line, end_line, action)
	local id = M.section_id(part.id, name)
	result.children[id] = {
		id = id, kind = "tool", execute_action = action or name,
		part_id = part.id, message_id = part.messageID, session_id = part.sessionID,
		tool_part = part, start_line = start_line, end_line = end_line or #result.lines - 1,
	}
end

local function calls_from(metadata)
	local calls = {}
	for _, call in ipairs(type(metadata.toolCalls) == "table" and metadata.toolCalls or {}) do
		if type(call) == "table" and type(call.tool) == "string" and call.tool ~= ""
			and (call.status == "running" or call.status == "completed" or call.status == "error") then
			calls[#calls + 1] = call
		end
	end
	return calls
end

function M.is_working(part)
	if type(part) ~= "table" or part.tool ~= "execute" then return false end
	return tool_group.is_working(part)
end

function M.failed(part)
	if type(part) ~= "table" or part.tool ~= "execute" then return false end
	return tool_group.failed(part)
end

-- The recorded MCP calls in the shared frame. Hidden calls and the result stay
-- in the inspector, which the calls section opens.
local function append_calls(result, part, calls)
	list_style.add_border(result)
	local calls_start = #result.lines
	local limit = 6
	for i = 1, math.min(limit, #calls) do
		local call = calls[i]
		local symbol = call.status == "error" and "✗" or call.status == "completed" and "✓" or panel.anim_frame()
		local _, _, rows = list_style.panel.add_line(result, "↳ " .. symbol .. " " .. clip(call.tool, body_width() - 9),
			call.status == "error" and list_style.body_error_hl or list_style.output_hl)
		if call.status ~= "error" then
			helpers.highlight_text(result, rows, symbol, call.status == "completed" and "OpenCodeExecuteSuccess"
				or "OpenCodeExecuteRunning")
		end
	end
	if #calls > limit then
		local hidden_failures = 0
		for i = limit + 1, #calls do if calls[i].status == "error" then hidden_failures = hidden_failures + 1 end end
		list_style.panel.add_line(result, panel.overflow_text(#calls - limit, "calls", { action = "confirm", verb = "inspect" }),
			list_style.border_hl)
		if hidden_failures > 0 then
			list_style.panel.add_line(result, "✗ " .. hidden_failures .. " hidden failed calls", list_style.body_error_hl)
		end
	elseif #calls == 0 then
		list_style.panel.add_line(result, "No tool calls recorded", list_style.border_hl)
	end
	if #calls > 0 then section(result, part, "calls", calls_start) end
	list_style.add_border(result, true)
	list_style.contain_background(result)
end

-- Like an Explore leaf, a folded invocation occupies one row. Opening it
-- reveals the recorded MCP calls; their inspector holds the result and code.
function M.render(part, expanded, opts)
	if type(part) ~= "table" or part.tool ~= "execute" then return nil end
	local ctx = panel.context(part)
	local calls, failed_calls = calls_from(ctx.metadata), 0
	for _, call in ipairs(calls) do
		if call.status == "error" then failed_calls = failed_calls + 1 end
	end
	local failed, working = tool_group.latest_failed(part), M.is_working(part)
	local animated = working and not (opts or {}).grouped
	local name = calls[1] and calls[1].tool or "JavaScript"
	name = text.strip_ansi(name):gsub("[%c]", " ")
	local suffix = {}
	if #calls > 1 then suffix[#suffix + 1] = "+" .. (#calls - 1) .. " more" end
	if failed_calls > 0 then suffix[#suffix + 1] = failed_calls .. " failed"
	elseif failed then suffix[#suffix + 1] = "Failed" end
	-- Execute records carry only the native start/end times.
	local elapsed = not working and panel.duration(ctx.state.time, true) or nil
	if elapsed then suffix[#suffix + 1] = elapsed end
	-- Keep the status at the start and spinner at the end on narrow windows.
	local header = panel.fit_header({
		prefix = expanded and " ↘ " or " → ", target = name,
		suffix = #suffix > 0 and " · " .. table.concat(suffix, " · ") or "",
		spinner = animated and " " .. panel.anim_frame() or "",
		width = body_width(), truncate = clip, min_target = 1,
	})
	local result = helpers.result()
	result.children = {}
	add_line(result, header, failed and list_style.error_hl or list_style.header_hl)
	if expanded then append_calls(result, part, calls) end
	return result
end

M.render_tool = M.render

return M

end)
