-- Compact reasoning and tool activity timeline groups.
-- These are view-only widgets; their members are always resolved from sync.
local M = {}

local thinking = require("opencode.ui.thinking")
local locale = require("opencode.util.locale")
local tool_group = require("opencode.ui.chat.tool_group")

local function reasoning_text(part)
	return vim.trim((part.text or ""):gsub("%[REDACTED%]", "", 1))
end

function M.kind(part, session_config)
	local thought = part.type == "reasoning" and reasoning_text(part) ~= ""
	session_config = session_config or (require("opencode.state").get_config() or {}).session or {}
	-- Subagents retain their separate navigation and child-session widgets.
	-- Questions and interaction widgets always remain outside a folded summary.
	if session_config.verbosity == "low" and (thought or
		(part.type == "tool" and part.tool ~= "question" and part.tool ~= "task")) then return "activity" end
	if thought then return "thought" end
	if part.type == "tool" and session_config.grouping ~= "none" then return tool_group.kind(part) end
end

function M.is_expanded(group, explicit)
	if explicit ~= nil then return explicit == true end
	if group.kind == "thought" then return thinking.is_expanded() end
	return group.kind ~= "activity" and ((require("opencode.state").get_config() or {}).session or {}).verbosity == "high"
end

-- A group may span assistant steps, but never a visible message, text, other
-- tool, interaction, or final answer boundary. Container IDs are distinct from
-- their first child, so their expansion state can never collide.
function M.collect(messages, get_parts, has_interaction)
	has_interaction = has_interaction or function() return false end
	local session_config = (require("opencode.state").get_config() or {}).session or {}
	local by_part, current = {}, nil
	local function finish()
		if current then current.completed = true end
		current = nil
	end
	for _, message in ipairs(messages) do
		if not message.hidden then
			if message.role ~= "assistant" then
				finish()
			else
				for _, part in ipairs(get_parts(message.id).parts) do
					local kind = M.kind(part, session_config)
					local interaction = has_interaction(message, part)
					if kind and (kind == "thought" or not interaction) then
						if not current or current.kind ~= kind then
							finish()
							current = { id = "activity:" .. kind .. ":" .. part.id, first_part_id = part.id,
								kind = kind, refs = {}, completed = false }
						end
						current.refs[#current.refs + 1] = { part = part, message = message }
						by_part[part.id] = current
					elseif part.type == "tool" or interaction
						or (part.type == "text" and vim.trim(part.text or "") ~= "") then
						finish()
					end
				end
				if has_interaction(message, {}) or message.error or message.error_message or message.retry
					or (message.finish and message.finish ~= "tool-calls" and message.finish ~= "unknown") then
					finish()
				end
			end
		end
	end
	return by_part
end

local function members(group)
	local sync = require("opencode.sync")
	local result = {}
	for _, ref in ipairs(group.refs) do
		local message = sync.get_message(ref.message.sessionID, ref.message.id) or ref.message
		local part = sync.get_part(ref.message.id, ref.part.id) or ref.part
		result[#result + 1] = { part = part, message = message }
	end
	return result
end

-- A boundary closes collection, not a running tool. Thought completion still
-- follows the assistant step; tool status always follows the latest member data.
function M.is_working(group, refs)
	if group.kind == "thought" and group.completed then return false end
	for _, ref in ipairs(refs or members(group)) do
		if ref.part.type == "reasoning" then
			if not (ref.part.time or {}).completed and not (ref.message.time or {}).completed then return true end
		elseif tool_group.is_working(ref.part) then
			return true
		end
	end
	return false
end

local function ensure_highlights()
	local config = thinking.get_config()
	local header = vim.api.nvim_get_hl(0, { name = config.header_highlight, link = false })
	local fg = header.fg or 0xffaf00
	vim.api.nvim_set_hl(0, "OpenCodeThought", { default = true, fg = fg, bold = true })
	vim.api.nvim_set_hl(0, "OpenCodeThoughtBody", { default = true, link = config.highlight })
	vim.api.nvim_set_hl(0, "OpenCodeThoughtBorder", { default = true, link = "NonText" })
end

require("opencode.ui.highlights").register("opencode.ui.chat.activity", ensure_highlights)

local function add_line(result, text, hl, prefix)
	require("opencode.ui.chat.render").add_panel_line(result, text, hl, {
		prefix = prefix or "",
		prefix_hl_group = prefix and "OpenCodeThoughtBorder" or nil,
	})
end

local function append_thought(result, part)
	local render = require("opencode.ui.chat.render")
	local body = require("opencode.ui.markdown").render(reasoning_text(part), {
		width = math.max(1, render.get_chat_text_width() - vim.fn.strdisplaywidth("▏  ")),
	}, render)
	local offset = #result.lines
	for _, line in ipairs(body) do
		render.add_panel_raw_line(result, line:content(), "OpenCodeThoughtBody", {
			prefix = "▏  ", prefix_hl_group = "OpenCodeThoughtBorder", wrap = false,
		})
	end
	for _, mark in ipairs(body._opencode_highlights or {}) do
		local shifted = vim.tbl_extend("force", {}, mark, {
			line = offset + mark.line, col_start = #"▏  " + mark.col_start, col_end = #"▏  " + mark.col_end,
		})
		result.highlights[#result.highlights + 1] = shifted
	end
	result._opencode_syntax_retry = body._opencode_syntax_retry or result._opencode_syntax_retry
end

local function render_low(group, refs, expanded, expansions)
	local result = { lines = {}, highlights = {} }
	local tools, thoughts, failed = 0, 0, 0
	for _, ref in ipairs(refs) do
		if ref.part.type == "reasoning" then thoughts = thoughts + 1
		else tools = tools + 1; if tool_group.failed(ref.part) then failed = failed + 1 end end
	end
	local frame = M.is_working(group, refs) and require("opencode.ui.chat.task_animation").get_task_anim_frame() or nil
	local header = (frame or (expanded and "-" or "+")) .. " Activity · " .. tools .. (tools == 1 and " tool, " or " tools, ")
		.. thoughts .. (thoughts == 1 and " thought" or " thoughts")
	if failed > 0 then header = header .. " · " .. failed .. " failed" end
	add_line(result, header, failed > 0 and "OpenCodeActivityError" or "OpenCodeToolGroup")
	local tree = require("opencode.ui.chat.widget_tree")
	-- Keep every identity when folded. Errors render through their ordinary
	-- widget, while input/output and protected data retain existing policies.
	for _, ref in ipairs(refs) do
		local part = ref.part
		local node = { id = part.id, kind = "tool", tool_part = part,
			session_id = ref.message.sessionID, message_id = ref.message.id, part_id = part.id }
		local rendered
		if part.type == "reasoning" then
			local thought = { id = "activity:thought:" .. part.id, kind = "thought", refs = { ref }, completed = group.completed }
			node.id, node.kind, node.activity_group = thought.id, "activity", thought
			if expanded then rendered = M.render(thought, expansions[thought.id], expansions) end
		elseif expanded or tool_group.failed(part) then
			rendered = require("opencode.ui.chat.tasks").render_regular_tool(part, expansions[part.id] == true)
		end
		tree.append(result, node, rendered)
	end
	result.lines[#result.lines + 1] = ""
	return result
end

function M.render(group, expanded, expansions)
	if expanded == nil then expanded = M.is_expanded(group) end
	expansions = expansions or {}
	local result = { lines = {}, highlights = {} }
	local refs = members(group)
	if group.kind == "activity" then return render_low(group, refs, expanded, expansions) end
	if group.kind ~= "thought" then return tool_group.render(group.kind, refs, expanded, expansions) end
	local working = M.is_working(group, refs)
	local frame = working and require("opencode.ui.chat.task_animation").get_task_anim_frame() or nil
	local duration, title = 0, nil
	for _, ref in ipairs(refs) do
		local time = ref.part.time or {}
		local start, stop = time.created, time.completed
		if type(start) == "number" and type(stop) == "number" then duration = duration + math.max(0, stop - start) end
		local candidate, rest = reasoning_text(ref.part):match("^%*%*([^*\r\n]+)%*%*(.*)$")
		title = candidate and (rest == "" or rest:sub(1, 2) == "\n\n" or rest:sub(1, 4) == "\r\n\r\n")
			and vim.trim(candidate) or nil
	end
	local header = (frame or (expanded and "-" or "+")) .. (working and " Thinking" or " Thought")
	if title and (working or not expanded) then header = header .. ": " .. title end
	if not working then
		if #refs > 1 then header = header .. " · " .. #refs .. " steps" end
		if duration > 0 then header = header .. " · " .. locale.duration(duration) end
	end
	add_line(result, header, "OpenCodeThought")
	if expanded then
		for _, ref in ipairs(refs) do
			result.lines[#result.lines + 1] = ""
			append_thought(result, ref.part)
		end
	end
	result.lines[#result.lines + 1] = ""
	return result
end

return M
