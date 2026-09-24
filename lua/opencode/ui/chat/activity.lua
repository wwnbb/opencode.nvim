-- Compact Thought / Explore timeline groups, matching opencode2's session view.
-- These are view-only widgets; their members are always resolved from sync.
local M = {}

local thinking = require("opencode.ui.thinking")
local locale = require("opencode.util.locale")
local tree = require("opencode.ui.chat.widget_tree")
local exploration_tool = require("opencode.ui.chat.exploration_tool")

local function reasoning_text(part)
	return vim.trim((part.text or ""):gsub("%[REDACTED%]", "", 1))
end

function M.kind(part)
	if part.type == "reasoning" and reasoning_text(part) ~= "" and thinking.is_enabled() then
		return "thought"
	end
	if part.type == "tool" and exploration_tool.supports(part.tool) then
		return "explore"
	end
end

-- A group may span assistant steps, but never a visible message, text, other
-- tool, interaction, or final answer boundary. Container IDs are distinct from
-- their first child, so their expansion state can never collide.
function M.collect(messages, get_parts, has_interaction)
	has_interaction = has_interaction or function() return false end
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
					local kind = M.kind(part)
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

local function ended(ref)
	local part = ref.part
	local time = part.type == "tool" and (part.state or {}).time or part.time or {}
	return time and time.completed
		or (part.type == "reasoning" and (ref.message.time or {}).completed)
		or (part.type == "tool" and vim.tbl_contains({ "completed", "error", "cancelled", "canceled" }, (part.state or {}).status))
end

-- Rendering can reuse its resolved members instead of querying sync twice.
function M.is_working(group, refs)
	if group.completed then return false end
	for _, ref in ipairs(refs or members(group)) do
		if not ended(ref) then return true end
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
	vim.api.nvim_set_hl(0, "OpenCodeExplore", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "OpenCodeActivityRunning", { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, "OpenCodeActivityError", { default = true, link = "DiagnosticError" })
end

require("opencode.ui.highlights").register("opencode.ui.chat.activity", ensure_highlights)

local function add_line(result, text, hl, prefix)
	require("opencode.ui.chat.render").add_panel_line(result, text, hl, {
		prefix = prefix or "",
		prefix_hl_group = prefix and "OpenCodeThoughtBorder" or nil,
	})
end

function M.render(group, expanded, expansions)
	expansions = expansions or {}
	local result = { lines = {}, highlights = {} }
	local refs = members(group)
	local working = M.is_working(group, refs)
	local frame = working and require("opencode.ui.chat.task_animation").get_task_anim_frame() or nil
	if group.kind == "thought" then
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
				for _, line in ipairs(vim.split(reasoning_text(ref.part), "\n", { plain = true })) do
					add_line(result, line, "OpenCodeThoughtBody", line == "" and "▏" or "▏  ")
				end
			end
		end
	else
		local counts, order = {}, {}
		for _, ref in ipairs(refs) do
			local name = ref.part.tool == "read" and "read" or "search"
			if not counts[name] then order[#order + 1] = name; counts[name] = 0 end
			counts[name] = counts[name] + 1
		end
		local labels = {}
		for _, name in ipairs(order) do
			local count = counts[name]
			labels[#labels + 1] = count .. " " .. (count == 1 and name or name == "search" and "searches" or "reads")
		end
		add_line(result, (frame or "→") .. (working and " Exploring — " or " Explored — ") .. table.concat(labels, ", "), "OpenCodeExplore")
		for _, ref in ipairs(refs) do
			local part = ref.part
			local node = { id = part.id, kind = "tool", tool_part = part,
				session_id = ref.message.sessionID, message_id = ref.message.id, part_id = part.id }
			-- Keep failed calls discoverable while the group is closed; the leaf
			-- still decides how much detail to display from its own state.
			local visible = expanded or (part.state or {}).status == "error"
			tree.append(result, node, visible and exploration_tool.render(part, expansions[part.id] == true) or nil)
		end
	end
	result.lines[#result.lines + 1] = ""
	return result
end

return M
