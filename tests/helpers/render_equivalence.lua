-- Compare each observable frame with the existing full render path. Keep IDs
-- allocated by Neovim and render generations out of value comparisons only.
local M = {}

local cs = require("opencode.ui.chat.state")
local state = cs.state
local render_state = require("opencode.ui.chat.render_state")

local range_fields = {
	"id", "kind", "status", "session_id", "message_id", "part_id", "start_line", "end_line",
	"separator", "meta", "highlights",
}

local function ranges(nodes)
	local result = {}
	for id, node in pairs(nodes or {}) do
		local copy = {}
		for _, field in ipairs(range_fields) do copy[field] = vim.deepcopy(node[field]) end
		if node.children then copy.children = ranges(node.children) end
		result[id] = copy
	end
	return result
end

---Capture pure render values before NuiLine highlighting mutates extmark IDs.
function M.rendered(raw_lines, nui_lines, content_highlights)
	local result = { lines = vim.deepcopy(raw_lines), blank_flags = {}, highlights = {}, content_highlights = {} }
	for row, line in ipairs(nui_lines or {}) do
		result.blank_flags[row] = line._opencode_preserve_blank == true
		local column = 0
		for _, text in ipairs(line._texts or {}) do
			local length = #text:content()
			if text.extmark then
				local options = vim.deepcopy(text.extmark)
				options.id, options.end_col = nil, column + length
				result.highlights[#result.highlights + 1] = { row = row - 1, column = column, options = options }
			end
			column = column + length
		end
	end
	for index, highlight in ipairs(content_highlights or {}) do
		result.content_highlights[index] = vim.deepcopy(highlight)
	end
	return result
end

local function extmarks(bufnr, namespace)
	local result = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
		result[#result + 1] = { row = mark[2], column = mark[3], options = vim.deepcopy(mark[4]) }
	end
	-- IDs and insertion order can differ while all displayed byte ranges agree.
	table.sort(result, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
	return result
end

---Capture actual buffer/UI state without running a render or changing focus.
---@param opts? table { rendered?: table, animation?: boolean, windows?: number[] }
function M.snapshot(opts)
	opts = opts or {}
	assert(state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr), "A valid chat buffer is required")
	local result = {
		lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false),
		highlights = extmarks(state.bufnr, cs.chat_hl_ns),
		ranges = {},
		expanded_tasks = vim.deepcopy(state.expanded_tasks),
		expanded_tools = vim.deepcopy(state.expanded_tools),
		spinner_line = require("opencode.ui.chat.positions").spinner_line(),
		windows = {},
		rendered = vim.deepcopy(opts.rendered),
	}
	for _, field in ipairs({ "questions", "permissions", "edits", "tasks", "tools",
		"message_positions", "pending_inputs", "stream_blocks" }) do
		result.ranges[field] = ranges(state[field])
	end
	if opts.animation then result.animation = extmarks(state.bufnr, cs.chat_anim_ns) end
	for _, winid in ipairs(opts.windows or vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(winid)
			and (vim.api.nvim_win_get_buf(winid) == state.bufnr or winid == state.winid) then
			result.windows[winid] = {
				buffer = vim.api.nvim_win_get_buf(winid),
				cursor = vim.api.nvim_win_get_cursor(winid),
				view = vim.api.nvim_win_call(winid, vim.fn.winsaveview),
				winbar = vim.wo[winid].winbar,
			}
		end
	end
	return result
end

---Keep widget/scroll state intact; reset_chat_surface also closes detail pages.
---@param extra? function[] Additional memo-cache clearers introduced by later stages.
function M.clear_caches(extra)
	render_state.clear_render_cache()
	render_state.clear_code_cache()
	local memo = package.loaded["opencode.util.memo"]
	if memo then memo.clear_all() end
	state.task_summary_cache = { entries = {}, order = {} }
	for _, clear in ipairs(extra or {}) do clear() end
end

---Run the existing full path with cold computational caches and collect both
---its pure output and applied state. Freeze animation/time in the caller when
---those values can change between the optimized and reference frames.
---@param opts? table { clear?: function[], animation?: boolean, windows?: number[] }
function M.cold_snapshot(opts)
	opts = opts or {}
	local chat = require("opencode.ui.chat").for_view(state)
	local original_render, rendered = chat.render, nil
	chat.render = function(...)
		local raw, nui, highlights, blocks = original_render(...)
		rendered = M.rendered(raw, nui, highlights)
		return raw, nui, highlights, blocks
	end
	local ok, result = xpcall(function()
		M.clear_caches(opts.clear)
		state.force_full_render = true
		chat.do_render()
		assert(rendered and not state.force_full_render, "Full render failed before applying the reference frame")
		return M.snapshot({ rendered = rendered, animation = opts.animation, windows = opts.windows })
	end, debug.traceback)
	chat.render = original_render
	if not ok then error(result) end
	return result
end

---Each consumer receives its own event value, so replaying the same trace for
---another implementation cannot inherit mutations from the previous replay.
function M.replay(trace, apply, after_event)
	for index, event in ipairs(trace) do
		apply(vim.deepcopy(event), index)
		if after_event then after_event(index, vim.deepcopy(event)) end
	end
end

---Every mark in a namespace as a comparable value: no ids, sorted.
function M.marks(bufnr, namespace)
	local result = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace or cs.chat_hl_ns, 0, -1, { details = true })) do
		local details = mark[4]
		result[#result + 1] = string.format("%d:%d-%s:%s %s p%s%s", mark[2], mark[3], tostring(details.end_row),
			tostring(details.end_col), tostring(details.hl_group), tostring(details.priority), details.hl_eol and " eol" or "")
	end
	table.sort(result)
	return result
end

local TRACKED = { "questions", "permissions", "edits", "tasks", "tools", "message_positions", "pending_inputs",
	"stream_blocks", "spinner_footer", "block_index" }

---Render the current frame with the full path into a scratch buffer. Tracked
---positions are restored afterwards, so the caller's sequence is unaffected.
---@return table { lines: string[], marks: string[] }
function M.full_render_reference()
	local chat = require("opencode.ui.chat").for_view(state)
	local chat_highlights = require("opencode.ui.chat.highlights")
	local render_blocks = require("opencode.ui.chat.render_blocks")
	local saved = {}
	for _, field in ipairs(TRACKED) do saved[field] = state[field] end
	local lines, nui_lines, highlights = chat.render()
	local scratch = vim.api.nvim_create_buf(false, true)
	local ok, result = xpcall(function()
		vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
		chat_highlights.write_nui_lines(scratch, cs.chat_hl_ns, nui_lines, 1, #nui_lines, 0)
		for _, name in ipairs(render_blocks.WIDGET_MAPS) do
			for _, pos in pairs(state[name] or {}) do
				if pos.highlights and pos.start_line then
					chat_highlights.apply_extmark_highlights(scratch, cs.chat_hl_ns, pos.highlights, pos.start_line)
				end
			end
		end
		chat_highlights.apply_extmark_highlights(scratch, cs.chat_hl_ns, highlights, 0)
		return { lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false), marks = M.marks(scratch) }
	end, debug.traceback)
	vim.api.nvim_buf_delete(scratch, { force = true })
	for _, field in ipairs(TRACKED) do state[field] = saved[field] end
	if not ok then error(result) end
	return result
end

---Assert that the chat buffer shows exactly what a full render of the current
---frame would: the same lines and the same marks in the chat namespace.
function M.assert_matches_full_render(label)
	local expected = M.full_render_reference()
	local actual = { lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), marks = M.marks(state.bufnr) }
	assert.same(expected.lines, actual.lines, label .. ": lines")
	assert.same(expected.marks, actual.marks, label .. ": marks")
end

return M
