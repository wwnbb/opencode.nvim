-- Local forms (integration setup) share typed projection and rendering with chat forms.
local M = {}
function M.open(fields, opts, callback)
	local forms = require("opencode.question.forms")
	local widget = require("opencode.ui.question_widget")
	local float = require("opencode.ui.float")
	local item = { questions = {}, current_tab = 1, status = "pending" }
	forms.init(item, { title = opts.title, fields = fields })
	item.hint = "1-9 select · Space toggle · c text · Tab/S-Tab field · Ctrl-g submit · Esc cancel"
	local popup, bufnr = float.create_centered_popup({ title = " " .. opts.title .. " ",
		width = math.min(72, math.max(10, vim.o.columns - 4)), height = math.min(20, math.max(4, vim.o.lines - 6)) })
	popup:mount()
	vim.wo[popup.winid].wrap = false
	local closed, cursor = false, 1
	local function finish(answer)
		if closed then return end
		closed = true
		popup:unmount()
		callback(answer)
	end
	local function current() return item.questions[item.current_tab], item.selections[item.current_tab] end
	local function render()
		if closed or not vim.api.nvim_buf_is_valid(bufnr) then return end
		forms.pull(item); forms.rebuild(item)
		local lines, highlights, meta = widget.get_lines_for_question("integration", item.questions, item, "pending",
			{ width = vim.api.nvim_win_get_width(popup.winid) })
		vim.bo[bufnr].modifiable = true
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.bo[bufnr].modifiable = false
		local ns = vim.api.nvim_create_namespace("opencode_form")
		vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
		if popup.winid and meta.option_count and meta.option_count > 0 then
			local option = math.min(cursor, meta.option_count)
			pcall(vim.api.nvim_win_set_cursor, popup.winid, { meta.option_lines[option] + 1, 0 })
		end
		for _, hl in ipairs(highlights) do
			pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, hl.line, hl.col_start, { end_col = hl.col_end, hl_group = hl.hl_group })
		end
	end
	local function choose(index)
		local q, selection = current()
		if not q or not q.options[index] then return end
		if q.multiple then
			local next_indices, found = {}, false
			for _, selected in ipairs(selection.selected_indices) do
				if selected == index then found = true else next_indices[#next_indices + 1] = selected end
			end
			if not found then next_indices[#next_indices + 1] = index end
			selection.selected_indices = next_indices
		else selection.selected_indices, selection.custom_present = { index }, false end
		selection.is_answered, cursor = true, index
		render()
	end
	local function custom()
		local q, selection = current()
		if not q or not q.custom then return end
		float.create_input_popup({ title = " " .. q.header .. " ", default = selection.custom_input,
			on_submit = function(value)
				if closed then return end
				selection.custom_input, selection.custom_present, selection.is_answered = value, true, true
				if not q.multiple then selection.selected_indices = {} end
				render()
			end })
	end
	local function submit()
		if forms.validate(item) then finish(forms.answer(item)); return end
		for i, q in ipairs(item.questions) do if item.field_errors[q.key] then item.current_tab = i; break end end
		render()
	end
	local function map(key, fn) vim.keymap.set("n", key, fn, { buffer = bufnr, silent = true }) end
	for i = 1, 9 do map(tostring(i), function() choose(i) end) end
	for key, direction in pairs({ ["<Tab>"] = 1, ["<S-Tab>"] = -1 }) do
		map(key, function() item.current_tab = ((item.current_tab - 1 + direction) % math.max(1, #item.questions)) + 1; cursor = 1; render() end)
	end
	for key, direction in pairs({ j = 1, k = -1 }) do
		map(key, function()
			local q = current()
			if q and #q.options > 0 then cursor = ((cursor - 1 + direction) % #q.options) + 1; render() end
		end)
	end
	map("<Space>", function() choose(cursor) end)
	map("<CR>", function()
		local q = current()
		if not q then submit()
		elseif q.field_type == "external" then vim.ui.open(q.url)
		elseif #q.options > 0 then choose(cursor)
		else custom() end
	end)
	map("c", custom); map("<C-g>", submit); map("<Esc>", function() finish(nil) end); map("q", function() finish(nil) end)
	vim.api.nvim_create_autocmd("BufWipeout", { buffer = bufnr, once = true, callback = function()
		if not closed then closed = true; callback(nil) end
	end })
	render()
	return { close = function() finish(nil) end }
end
return M
