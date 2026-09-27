-- Tool activity families are data; grouping, status and tree behavior are shared.
-- Renderer modules are loaded lazily so their widgets can use these same policies.
local M = {}

local render = require("opencode.ui.chat.render")
local tree = require("opencode.ui.chat.widget_tree")
local text = require("opencode.util.text")
local memo = require("opencode.util.memo").new("activity_leaf", { max_entries = 1000 })

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

local function execution_failed(part, metadata)
	local state = type(part.state) == "table" and part.state or {}
	return failures[state.status] == true or metadata.error == true
		or (state.error ~= false and text.is_present(state.error) and vim.trim(tostring(state.error)) ~= "")
end

function M.execution_failed(part)
	if failures[(type(part.state) == "table" and part.state or {}).status] then return true end
	return execution_failed(part, render.get_tool_metadata(part))
end

function M.failed(part)
	if failures[(type(part.state) == "table" and part.state or {}).status] then return true end
	local metadata = render.get_tool_metadata(part)
	if execution_failed(part, metadata) then return true end
	local calls = metadata.toolCalls
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

function M.clear_leaf_cache()
	memo:clear()
end

function M.clear_session(session_id)
	if type(session_id) ~= "string" then return end
	local prefix = session_id .. "\0"
	for owner in pairs(memo.entries) do
		if type(owner) == "string" and owner:sub(1, #prefix) == prefix then memo:delete(owner) end
	end
end

local function leaf_dependencies()
	local style = require("opencode.ui.chat.tool_style")
	local bufnr = require("opencode.ui.chat.state").state.bufnr
	local tabstop = bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].tabstop or vim.bo.tabstop
	return require("opencode.ui.chat.render_state").render_cache_key(
		render.get_chat_text_width(), vim.fn.getcwd(),
		require("opencode.ui.syntax").get_cache_generation(),
		vim.o.ambiwidth, vim.o.emoji, vim.o.display, tabstop, vim.bo.tabstop, vim.bo.vartabstop,
		vim.inspect(vim.fn.exists("*getcellwidths") == 1 and vim.fn.getcellwidths() or {}),
		style.prefix, style.header_hl, style.output_hl, style.error_hl, style.body_error_hl, style.border_hl)
end

-- Rendered child descriptors must follow equal-value replacements too. Keep
-- cached coordinates relative and never retain an exposed part in the memo.
local function copy_leaf(result, part, storing)
	local function children(nodes)
		if not nodes then return nil end
		local copy = {}
		for id, node in pairs(nodes) do
			local child = {}
			for key, value in pairs(node) do
				if key == "children" then child.children = children(value)
				elseif key == "tool_part" and (value == part or value == false) then
					if storing then child.tool_part = false else child.tool_part = part end
				else child[key] = vim.deepcopy(value) end
			end
			copy[id] = child
		end
		return copy
	end
	local copy = {}
	for key, value in pairs(result) do
		if not (storing and key == "highlights") then
			copy[key] = key == "children" and children(value) or vim.deepcopy(value)
		end
	end
	return copy
end

-- The public renderer uses highlight dictionaries. Retain lossless tuples in
-- the memo instead: thousands of repeated field names otherwise consume most
-- of its budget before a large activity group can become warm.
local function pack_highlights(highlights)
	local packed = { shapes = {}, rows = {} }
	local shape_ids = {}
	for _, highlight in ipairs(highlights or {}) do
		local fields = vim.tbl_keys(highlight)
		table.sort(fields)
		local key = table.concat(fields, "\0")
		local shape_id = shape_ids[key]
		if not shape_id then
			shape_id = #packed.shapes + 1
			shape_ids[key], packed.shapes[shape_id] = shape_id, fields
		end
		local row = { shape_id }
		for _, field in ipairs(fields) do
			local value = highlight[field]
			row[#row + 1] = type(value) == "table" and vim.deepcopy(value) or value
		end
		packed.rows[#packed.rows + 1] = row
	end
	return packed
end

local function unpack_highlights(packed)
	local highlights = {}
	for index, row in ipairs(packed.rows) do
		local highlight = {}
		for field_index, field in ipairs(packed.shapes[row[1]]) do
			local value = row[field_index + 1]
			highlight[field] = type(value) == "table" and vim.deepcopy(value) or value
		end
		highlights[index] = highlight
	end
	return highlights
end

local function render_leaf(part, expanded, opts, dependencies, message)
	local widget = renderer(part)
	if not widget then return nil end
	if M.is_working(part) then return widget.render(part, expanded, opts) end
	local sync = require("opencode.sync")
	local message_id = part.messageID or (message and message.id)
	local session_id = part.sessionID or (message and message.sessionID)
	local owned = message_id and sync.get_part(message_id, part.id) == part
	local key = require("opencode.ui.chat.render_state").render_cache_key
	local owner = key(session_id, message_id, part.id or tostring(part))
	local signature = key(dependencies or leaf_dependencies(), expanded == true,
		(opts or {}).grouped == true, widget.render, M.cache_key(part),
		owned and sync.get_part_revision(message_id, part.id) or "detached")
	local cached = memo:get(owner, signature)
	if cached and vim.deep_equal(cached.part, part) then
		local result = copy_leaf(cached.result, part, false)
		result.highlights = unpack_highlights(cached.highlights)
		return result
	end
	local result = widget.render(part, expanded, opts)
	-- Retry outcomes must reach the parser again on the next ordinary frame.
	if result and not result._opencode_syntax_retry then
		memo:put(owner, signature, {
			result = copy_leaf(result, part, true),
			highlights = pack_highlights(result.highlights),
			-- Also protect revision reuse after teardown and detached callers.
			part = vim.deepcopy(part),
		})
	else
		memo:delete(owner)
	end
	return result
end

function M.render_leaf(part, expanded, opts)
	return render_leaf(part, expanded, opts)
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
	local dependencies
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
	-- A folded group without errors needs only fresh identities. Avoid entering
	-- the body-cache path (including its dependency work) for these placeholders.
	if not expanded and failed == 0 then
		for _, ref in ipairs(refs) do
			local part = ref.part
			result.children = result.children or {}
			result.children[part.id] = { id = part.id, kind = "tool", tool_part = part,
				session_id = ref.message.sessionID, message_id = ref.message.id, part_id = part.id }
		end
		result.lines[#result.lines + 1] = ""
		return result
	end
	for _, ref in ipairs(refs) do
		local part = ref.part
		local node = { id = part.id, kind = "tool", tool_part = part,
			session_id = ref.message.sessionID, message_id = ref.message.id, part_id = part.id }
		-- Hidden leaves retain their identity; errors stay reachable when folded.
		local visible = expanded or failed_parts[part.id]
		local leaf
		if visible then
			dependencies = dependencies or leaf_dependencies()
			leaf = render_leaf(part, (expansions or {})[part.id] == true, { grouped = true }, dependencies, ref.message)
		end
		tree.append(result, node, leaf)
	end
	result.lines[#result.lines + 1] = ""
	return result
end

return M
