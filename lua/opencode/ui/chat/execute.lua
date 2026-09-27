-- Universal code-mode widget. Child calls come from server metadata; the
-- script's result belongs to execute, never to an individual MCP call.
local M = {}

local render = require("opencode.ui.chat.render")
local panel = require("opencode.ui.chat.tool_panel")
local text = require("opencode.util.text")
local locale = require("opencode.util.locale")
local tool_group = require("opencode.ui.chat.tool_group")
local list_style = require("opencode.ui.chat.exploration_style")

M.animation_line = 0

-- Execute reads as a compact transcript, with the chat's own background.
local PREFIX = ""
local helpers = panel.create_panel({ prefix = PREFIX, blank_prefix = "", default_hl = "OpenCodeExecuteOutput" })
require("opencode.ui.highlights").register("opencode.ui.chat.execute", function()
	helpers.set_hl("OpenCodeExecuteMuted", "Comment", "Normal", { bg = "NONE", bold = false, italic = false })
	helpers.set_hl("OpenCodeExecuteOutput", "Normal", nil, { bg = "NONE", bold = false, italic = false })
	helpers.set_hl("OpenCodeExecuteCall", "String", "Normal", { bg = "NONE", bold = false, italic = false })
	helpers.set_hl("OpenCodeExecuteSuccess", "DiagnosticOk", "Normal", { bg = "NONE", bold = false, italic = false })
	helpers.set_hl("OpenCodeExecuteRunning", "DiagnosticWarn", "Normal", { bg = "NONE", bold = false, italic = false })
	helpers.set_hl("OpenCodeExecuteError", "DiagnosticError", "ErrorMsg", { bg = "NONE", bold = false, italic = false })
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
	local source = tostring(value or "")
	local bounded = vim.fn.strcharpart(source, 0, width + 1)
	local line = render.expand_tabs(text.strip_ansi(bounded), 0)
	if #bounded == #source and vim.fn.strdisplaywidth(line) <= width then return line end
	local lo, hi = 0, vim.fn.strchars(line)
	while lo < hi do
		local mid = math.ceil((lo + hi) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(line, 0, mid)) <= width - 1 then lo = mid else hi = mid - 1 end
	end
	return vim.fn.strcharpart(line, 0, lo) .. "…"
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

-- Like an Explore leaf, a folded invocation occupies one row. Opening it
-- reveals the recorded MCP calls; their inspector holds the result and code.
function M.render(part, expanded, opts)
	if type(part) ~= "table" or part.tool ~= "execute" then return nil end
	if expanded then return M.render_tool(part, true, opts) end
	local ctx = panel.context(part)
	local calls, failed_calls = calls_from(ctx.metadata), 0
	for _, call in ipairs(calls) do
		if call.status == "error" then failed_calls = failed_calls + 1 end
	end
	local failed, working = M.failed(part), M.is_working(part)
	local animated = working and not (opts or {}).grouped
	local name = calls[1] and calls[1].tool or "JavaScript"
	name = name:gsub("[%c]", " ")
	local suffix = {}
	if #calls > 1 then suffix[#suffix + 1] = "+" .. (#calls - 1) .. " more" end
	if failed_calls > 0 then suffix[#suffix + 1] = failed_calls .. " failed" end
	local time = type(ctx.state.time) == "table" and ctx.state.time or {}
	local started, ended = tonumber(time.start), tonumber(time["end"])
	if not working and started and ended and ended >= started then
		suffix[#suffix + 1] = locale.duration(ended - started)
	end
	local tail = #suffix > 0 and " · " .. table.concat(suffix, " · ") or ""
	if animated then tail = tail .. " " .. panel.anim_frame() end
	local prefix = failed and " ✗ " or " → "
	local width = body_width()
	-- Keep the status at the start and spinner at the end on narrow windows.
	if vim.fn.strdisplaywidth(prefix .. tail) >= width then
		tail = animated and " " .. panel.anim_frame() or ""
	end
	local name_width = math.max(1, width - vim.fn.strdisplaywidth(prefix .. tail))
	local result = helpers.result()
	result.children = {}
	add_line(result, prefix .. clip(name, name_width) .. tail,
		failed and list_style.error_hl or list_style.header_hl)
	return result
end

function M.render_tool(part, expanded, opts)
	if type(part) ~= "table" or part.tool ~= "execute" then return nil end
	local ctx = panel.context(part)
	local working = M.is_working(part)
	local animated = working and not (opts or {}).grouped
	local failed = tool_group.execution_failed(part)
	local calls = calls_from(ctx.metadata)
	local failed_calls = 0
	for _, call in ipairs(calls) do if call.status == "error" then failed_calls = failed_calls + 1 end end
	local result = helpers.result()
	result.children = {}
	local status_icon = failed and "✗" or working and "○" or ctx.status == "completed" and "✓" or "○"
	local header = panel.fold_prefix(expanded) .. status_icon .. " execute"
	local metadata = {}
	if type(ctx.metadata.toolCalls) == "table" then
		metadata[#metadata + 1] = #calls .. (#calls == 1 and " tool" or " tools")
	end
	if failed_calls > 0 then metadata[#metadata + 1] = failed_calls .. " failed" end
	local time = type(ctx.state.time) == "table" and ctx.state.time or {}
	local started, ended = tonumber(time.start), tonumber(time["end"])
	if not working and started and ended and ended >= started then
		metadata[#metadata + 1] = locale.duration(ended - started)
	end
	if animated then metadata[#metadata + 1] = panel.anim_frame() end
	local available = body_width() - vim.fn.strdisplaywidth(header) - 2
	local right = table.concat(metadata, " · ")
	if animated and available < vim.fn.strdisplaywidth(right) then right = panel.anim_frame() end
	if available > 0 and right ~= "" then
		right = clip(right, available)
		header = header .. string.rep(" ", body_width() - vim.fn.strdisplaywidth(header .. right)) .. right
	elseif animated then
		header = clip(header, body_width() - 2) .. " " .. panel.anim_frame()
	else
		right = ""
	end
	local _, _, header_rows = add_line(result, header, "OpenCodeExecuteOutput")
	if right ~= "" then helpers.highlight_text(result, header_rows, right, "OpenCodeExecuteMuted") end
	helpers.highlight_text(result, header_rows, status_icon, failed and "OpenCodeExecuteError"
		or working and "OpenCodeExecuteRunning" or "OpenCodeExecuteSuccess")

	local calls_start = #result.lines
	local limit = expanded and 6 or 2
	for i = 1, math.min(limit, #calls) do
		local call = calls[i]
		local symbol = call.status == "error" and "✗" or call.status == "completed" and "✓" or working and "◐" or "○"
		local hl = call.status == "error" and "OpenCodeExecuteError" or call.status == "running" and "OpenCodeExecuteRunning"
			or "OpenCodeExecuteCall"
		local _, _, rows = add_line(result, "  ↳ " .. symbol .. " " .. call.tool, hl)
		if symbol == "✓" then helpers.highlight_text(result, rows, symbol, "OpenCodeExecuteSuccess") end
	end
	if #calls > limit then add_line(result, "  … " .. (#calls - limit) .. " more calls ↗", "OpenCodeExecuteMuted") end
	local hidden_failures = 0
	for i = limit + 1, #calls do if calls[i].status == "error" then hidden_failures = hidden_failures + 1 end end
	if hidden_failures > 0 then
		add_line(result, "✗ " .. hidden_failures .. " failed calls ↗", "OpenCodeExecuteError")
	end
	if #calls > 0 then section(result, part, "calls", calls_start) end
	return result
end

return M
