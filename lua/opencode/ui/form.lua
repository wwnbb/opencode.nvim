-- Local forms (integration setup) share typed projection and rendering with chat forms.
local M = {}
function M.open(fields, opts, callback)
	local forms = require("opencode.question.forms")
	local form_external = require("opencode.ui.form_external")
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
		popup:render(lines, highlights)
		if popup.winid and meta.option_count and meta.option_count > 0 then
			local option = math.min(cursor, meta.option_count)
			pcall(vim.api.nvim_win_set_cursor, popup.winid, { meta.option_lines[option] + 1, 0 })
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
			selection.is_answered = #selection.selected_indices > 0 or selection.custom_present == true
		else
			selection.selected_indices, selection.custom_present = { index }, false
			selection.is_answered = true
		end
		cursor = index
		render()
	end
	local function custom()
		local q, selection = current()
		if not q then return end
		if q.field_type == "external" then
			if not form_external.copy(q.url) then return end
			forms.mark_external_ready(item, q.key)
			render()
			return
		end
		if not q.custom then return end
		local tab_index = item.current_tab
		float.create_input_popup({ title = " " .. q.header .. " ", default = selection.custom_input,
			on_submit = function(value)
				if closed then return end
				forms.set_custom_input(item, tab_index, value)
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
		local q, selection = current()
		if not q then submit()
		elseif q.field_type == "external" then
			if not selection.external_ready then
				if not form_external.open(q.url) then return end
				forms.mark_external_ready(item, q.key)
			elseif not selection.is_answered then
				forms.acknowledge_external(item, q.key)
				if item.current_tab < #item.questions then item.current_tab = item.current_tab + 1 end
			end
			render()
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
