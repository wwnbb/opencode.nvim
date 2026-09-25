-- Tool activity families are data; grouping, status and tree behavior are shared.
-- Renderer modules are loaded lazily so their widgets can use these same policies.
local M = {}

local render = require("opencode.ui.chat.render")
local tree = require("opencode.ui.chat.widget_tree")
local text = require("opencode.util.text")

local definitions = {
	explore = {
		active = "Exploring", completed = "Explored",
		tools = { read = "read", glob = "search", grep = "search", rg = "search" },
		plurals = { read = "reads", search = "searches" },
		renderer = function() return require("opencode.ui.chat.exploration_tool") end,
	},
	execute = {
		active = "Executing", completed = "Executed",
		tools = { execute = "call" }, plurals = { call = "calls" },
		renderer = function() return require("opencode.ui.chat.execute") end,
	},
	web = {
		active = "Browsing", completed = "Browsed",
		tools = { websearch = "search", webfetch = "fetch" },
		plurals = { search = "searches", fetch = "fetches" },
		renderer = function(part)
			if part.tool == "websearch" then return require("opencode.ui.chat.websearch") end
			return require("opencode.ui.chat.webfetch")
		end,
	},
}

local by_tool = {}
for kind, definition in pairs(definitions) do
	for tool in pairs(definition.tools) do by_tool[tool] = kind end
end

function M.kind(part)
	return type(part) == "table" and by_tool[part.tool] or nil
end

local function renderer(part)
	local definition = definitions[M.kind(part)]
	return definition and definition.renderer(part) or nil
end

local failures = { error = true, cancelled = true, canceled = true, interrupted = true, aborted = true }
local active = { pending = true, running = true, streaming = true }

function M.execution_failed(part)
	local state = type(part.state) == "table" and part.state or {}
	return failures[state.status] == true or render.get_tool_metadata(part).error == true
		or (state.error ~= false and text.is_present(state.error) and vim.trim(tostring(state.error)) ~= "")
end

function M.failed(part)
	if M.execution_failed(part) then return true end
	local calls = render.get_tool_metadata(part).toolCalls
	for _, call in ipairs(type(calls) == "table" and calls or {}) do
		if type(call) == "table" and failures[call.status] then return true end
	end
	return false
end

function M.is_working(part)
	local state = type(part.state) == "table" and part.state or {}
	-- Explicit status wins over stale completion timestamps during updates.
	if active[state.status] then return true end
	if state.status == "completed" or failures[state.status] then return false end
	local time = type(state.time) == "table" and state.time or {}
	return text.is_nil(time["end"]) and text.is_nil(time.completed) and not M.execution_failed(part)
end

function M.render_leaf(part, expanded, opts)
	local widget = renderer(part)
	return widget and widget.render(part, expanded, opts) or nil
end

function M.cache_key(part)
	local widget = renderer(part)
	return widget and widget.cache_key and widget.cache_key(part) or ""
end

-- A renderer explicitly identifies its spinner row; never scan result text.
function M.animation_line(part)
	local widget = renderer(part)
	return widget and widget.animation_line or nil
end

require("opencode.ui.highlights").register("opencode.ui.chat.tool_group", function()
	-- Preserve the existing theme override for all tool families.
	vim.api.nvim_set_hl(0, "OpenCodeExplore", { default = true, link = "Comment" })
	vim.api.nvim_set_hl(0, "OpenCodeToolGroup", { default = true, link = "OpenCodeExplore" })
	vim.api.nvim_set_hl(0, "OpenCodeActivityRunning", { default = true, link = "Normal" })
	vim.api.nvim_set_hl(0, "OpenCodeActivityError", { default = true, link = "DiagnosticError" })
end)

function M.render(kind, refs, expanded, expansions)
	local definition = assert(definitions[kind], "Unknown tool activity: " .. tostring(kind))
	local result = { lines = {}, highlights = {} }
	local counts, order, failed_parts = {}, {}, {}
	local working, failed = false, 0
	for _, ref in ipairs(refs) do
		local name = definition.tools[ref.part.tool]
		if not counts[name] then order[#order + 1] = name; counts[name] = 0 end
		counts[name] = counts[name] + 1
		working = M.is_working(ref.part) or working
		failed_parts[ref.part.id] = M.failed(ref.part)
		if failed_parts[ref.part.id] then failed = failed + 1 end
	end
	local labels = {}
	for _, name in ipairs(order) do
		local count = counts[name]
		labels[#labels + 1] = count .. " " .. (count == 1 and name or definition.plurals[name])
	end
	local header = expanded and "↘" or "→"
	if working then header = header .. " " .. require("opencode.ui.chat.task_animation").get_task_anim_frame() end
	header = header .. " " .. (working and definition.active or definition.completed) .. " — " .. table.concat(labels, ", ")
	if failed > 0 then header = header .. " · " .. failed .. " failed" end
	render.add_panel_line(result, header, failed > 0 and "OpenCodeActivityError" or "OpenCodeToolGroup", { prefix = "" })
	for _, ref in ipairs(refs) do
		local part = ref.part
		local node = { id = part.id, kind = "tool", tool_part = part,
			session_id = ref.message.sessionID, message_id = ref.message.id, part_id = part.id }
		-- Hidden leaves retain their identity; errors stay reachable when folded.
		local visible = expanded or failed_parts[part.id]
		tree.append(result, node, visible and M.render_leaf(part, (expansions or {})[part.id] == true, { grouped = true }) or nil)
	end
	result.lines[#result.lines + 1] = ""
	return result
end

return M
