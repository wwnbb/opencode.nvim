local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local perf = require("opencode.perf")

local RENDER_CACHE_MAX_BLOCKS = 1000

function M.ensure_render_cache()
	if type(state.render_cache) ~= "table" then
		state.render_cache = { blocks = {}, order = {} }
	end
	state.render_cache.blocks = state.render_cache.blocks or {}
	state.render_cache.order = state.render_cache.order or {}
	return state.render_cache
end

function M.clear_render_cache()
	state.render_cache = { blocks = {}, order = {} }
	state.last_render_highlight_signature = nil
end

---@param opts? table { reset_expansions?: boolean, preserve_render_cache?: boolean, force_full_render?: boolean }
function M.reset_chat_surface(opts)
	opts = opts or {}
	state.questions = {}
	state.permissions = {}
	state.edits = {}
	state.tasks = {}
	state.task_child_cache = {}
	state.tools = {}
	if opts.reset_expansions then
		state.expanded_tasks = {}
		state.expanded_tools = {}
	end
	state.stream_blocks = {}
	state.spinner_footer_line = nil
	if opts.force_full_render ~= false then
		state.force_full_render = true
	end
	if not opts.preserve_render_cache then
		M.clear_render_cache()
	end
end

---@param ... any
function M.render_cache_key(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = tostring(select(i, ...) or "")
	end
	return table.concat(parts, "\0")
end

---@param session_id string|nil
---@param message_id string|nil
---@param part_id string|nil
---@param kind string|nil
---@return string|nil
function M.stream_block_key(session_id, message_id, part_id, kind)
	if not session_id or not message_id or not part_id or not kind then
		return nil
	end
	return M.render_cache_key("stream", session_id, message_id, part_id, kind)
end

---@param key string|nil
function M.render_cache_get(key)
	local done = perf.start("chat.render_state.render_cache_get")
	local cache = M.ensure_render_cache()
	local value = cache.blocks[key]
	done({ hit = value ~= nil })
	return value
end

---@param key string|nil
---@param value any
function M.render_cache_put(key, value)
	if not key or not value then
		return value
	end
	local done = perf.start("chat.render_state.render_cache_put")
	local cache = M.ensure_render_cache()
	if cache.blocks[key] == nil then
		table.insert(cache.order, key)
	end
	cache.blocks[key] = value
	while #cache.order > RENDER_CACHE_MAX_BLOCKS do
		local oldest = table.remove(cache.order, 1)
		cache.blocks[oldest] = nil
	end
	done({ cache_size = #cache.order })
	return value
end

---@param parts string[]
---@param highlights table|nil
---@param start_line number|nil
local function append_highlight_signature(parts, highlights, start_line)
	if type(highlights) ~= "table" then
		return
	end
	start_line = start_line or 0
	for _, hl in ipairs(highlights) do
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			table.insert(
				parts,
				table.concat({
					tostring(line),
					tostring(end_line),
					tostring(hl.col_start or 0),
					tostring(hl.col_end or hl.end_col or ""),
					tostring(hl.hl_group or ""),
					tostring(hl.priority or ""),
					tostring(hl.hl_eol or ""),
				}, ":")
			)
		end
	end
end

---@param content_highlights table|nil
---@return string
function M.render_highlight_signature(content_highlights)
	local done = perf.start("chat.render_state.render_highlight_signature")
	local parts = {}
	if type(content_highlights) == "table" and content_highlights._opencode_signature then
		table.insert(parts, tostring(content_highlights._opencode_signature))
	end
	append_highlight_signature(parts, content_highlights, 0)

	local function append_line_map(line_map)
		local keys = {}
		for key in pairs(line_map or {}) do
			table.insert(keys, key)
		end
		table.sort(keys, function(a, b)
			return tostring(a) < tostring(b)
		end)
		for _, key in ipairs(keys) do
			local pos = line_map[key]
			append_highlight_signature(parts, pos and pos.highlights, pos and pos.start_line or 0)
		end
	end

	for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
		append_line_map(line_map)
	end
	local result = table.concat(parts, "|")
	done({ parts = #parts, bytes = #result })
	return result
end

---@param changed_start number|nil
---@param content_highlights table|nil
---@return number
function M.highlight_clear_start(changed_start, content_highlights)
	local done = perf.start("chat.render_state.highlight_clear_start")
	local clear_start = changed_start or 0
	local function consider(highlights, start_line)
		local moved = false
		if type(highlights) ~= "table" then
			return moved
		end
		start_line = start_line or 0
		for _, hl in ipairs(highlights) do
			if type(hl) == "table" then
				local line = start_line + (hl.line or 0)
				local end_line = hl.end_line and (start_line + hl.end_line) or line
				if line < clear_start and end_line >= clear_start then
					clear_start = line
					moved = true
				end
			end
		end
		return moved
	end

	local moved = true
	while moved do
		moved = consider(content_highlights, 0)
		for _, line_map in ipairs({ state.questions, state.permissions, state.edits, state.tasks, state.tools }) do
			for _, pos in pairs(line_map or {}) do
				moved = consider(pos.highlights, pos.start_line or 0) or moved
			end
		end
	end
	local result = math.max(0, clear_start)
	done({ changed_start = changed_start, clear_start = result })
	return result
end

return M
