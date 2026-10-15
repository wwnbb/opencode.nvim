local M = {}
local autocomplete = require("opencode.ui.input.autocomplete")
local preview_ns = vim.api.nvim_create_namespace("opencode_input_history_preview")

local function query(state)
	return table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
end

function M.preview(state)
	if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then return end
	vim.api.nvim_buf_clear_namespace(state.bufnr, preview_ns, 0, -1)
	local search, ac = state.history_search, state.autocomplete or {}
	if not search or search.loading or not state.visible or not ac.visible or ac.kind ~= "history"
		or not state.winid or not vim.api.nvim_win_is_valid(state.winid)
		or vim.api.nvim_win_get_buf(state.winid) ~= state.bufnr then return end
	local item = (ac.items or {})[ac.selected or 1]
	if not item or not item.entry or item.entry.text == "" then return end
	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	if table.concat(lines, "\n") ~= search.query then return end
	local line = lines[#lines]
	local width = vim.api.nvim_win_get_width(state.winid) - vim.fn.strdisplaywidth(line) - 1
	local text = (search.query == "" and "" or " → ") .. item.entry.text:gsub("[%c]", " ")
	text = require("opencode.util.text").truncate(text, width, "…")
	if text == "" then return end
	vim.api.nvim_buf_set_extmark(state.bufnr, preview_ns, #lines - 1, #line, {
		virt_text = { { text, "OpenCodeInputAutocompleteDescription" } }, virt_text_pos = "eol", hl_mode = "combine",
	})
end

local function display(state, search)
	local items = search.items
	if #items == 0 then
		items = { { label = search.loading and "Searching history…" or "No matching prompts", kind = "history_status" } }
	end
	autocomplete.show_items(state, "history", { query = search.query, row = 0, start_col = 0 }, items)
	M.preview(state)
end

function M.refresh(state)
	local search = state.history_search
	if not search then return false end
	local text = query(state)
	if text == search.query then display(state, search); return true end
	search.query = text
	search.engine.search(text, function(items, loading)
		if state.history_search ~= search or not state.visible then return end
		search.items, search.loading = items, loading
		display(state, search)
	end)
	return true
end

function M.start(state, draft, callbacks)
	local engine = require("opencode.ui.history_search").new(state.config)
	if not engine then return false end
	state.history_search = { engine = engine, draft = draft, callbacks = callbacks, items = {} }
	callbacks.prepare()
	M.refresh(state)
	return true
end

function M.cancel(state)
	local search = state.history_search
	if not search then return false end
	state.history_search = nil
	M.preview(state)
	search.engine.close()
	autocomplete.close(state)
	search.callbacks.restore()
	return true
end

function M.confirm(state)
	local search = state.history_search
	if not search then return false end
	if query(state) ~= search.query then M.refresh(state); return true end
	local ac = state.autocomplete or {}
	local item = (ac.items or {})[ac.selected or 1]
	if item and item.entry then
		M.cancel(state)
		search.callbacks.select(item.entry)
	end
	return true
end

return M
