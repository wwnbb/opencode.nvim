describe("integration forms", function()
	local dialog, original_open, original_popup
	local float = require("opencode.ui.float")
	before_each(function()
		dialog, original_open, original_popup = nil, vim.ui.open, float.create_input_popup
	end)
	after_each(function()
		if dialog then dialog.close() end
		vim.ui.open, float.create_input_popup = original_open, original_popup
	end)
	it("renders the shared form widget and submits typed false/number/hidden values", function()
		local result, count = nil, 0
		dialog = require("opencode.ui.form").open({
			{ key = "hidden", type = "string", hidden = true, default = "kept" },
			{ key = "enabled", type = "boolean", required = true, title = "Enabled" },
			{ key = "count", type = "integer", required = true, default = 2, minimum = 1 },
		}, { title = "Integration setup" }, function(answer) result = answer; count = count + 1 end)
		local bufnr = vim.api.nvim_get_current_buf()
		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do keys[map.lhs] = map.callback end
		keys["2"]()
		keys["<C-G>"]()
		assert.same({ hidden = "kept", enabled = false, count = 2 }, result)
		dialog.close()
		assert.equals(1, count)
	end)
	it("requires a separate external completion confirmation before integration setup", function()
		local opened, result = {}, nil
		vim.ui.open = function(url) opened[#opened + 1] = url; return {} end
		dialog = require("opencode.ui.form").open({
			{ key = "authorization", type = "external", url = "https://example.com/connect" },
			{ key = "name", type = "string", required = true, default = "integration" },
		}, { title = "Integration setup" }, function(answer) result = answer end)
		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do keys[map.lhs] = map.callback end
		keys["<C-G>"]()
		assert.is_nil(result)
		keys["<CR>"]()
		assert.same({ "https://example.com/connect" }, opened)
		keys["<C-G>"]()
		assert.is_nil(result)
		keys["<CR>"]()
		keys["<C-G>"]()
		assert.same({ authorization = true, name = "integration" }, result)
		assert.equals(1, #opened)
	end)
	it("omits a cleared optional multiselect and its conditional integration field", function()
		local result
		dialog = require("opencode.ui.form").open({
			{ key = "choices", type = "multiselect", options = { { label = "A", value = "a" } } },
			{ key = "dependent", type = "string", default = "stale", when = {
				{ key = "choices", op = "neq", value = "a" },
			} },
		}, { title = "Integration setup" }, function(answer) result = answer end)
		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do keys[map.lhs] = map.callback end
		keys["1"]()
		keys["1"]()
		keys["<C-G>"]()
		assert.same({}, result)
	end)
	it("applies delayed custom input to the field that opened it", function()
		local pending
		float.create_input_popup = function(opts) pending = opts end
		local result
		dialog = require("opencode.ui.form").open({
			{ key = "first", type = "string", required = true },
			{ key = "second", type = "string", default = "kept" },
		}, { title = "Integration setup" }, function(answer) result = answer end)
		local keys = {}
		for _, map in ipairs(vim.api.nvim_buf_get_keymap(vim.api.nvim_get_current_buf(), "n")) do keys[map.lhs] = map.callback end
		keys.c()
		keys["<Tab>"]()
		pending.on_submit("first value")
		keys["<C-G>"]()
		dialog.close()
		assert.same({ first = "first value", second = "kept" }, result)
	end)
end)

describe("integration form layout", function()
	local dialog, old_config
	local chat_state = require("opencode.ui.chat.state").state
	before_each(function() dialog, old_config = nil, chat_state.config end)
	after_each(function()
		if dialog then dialog.close() end
		chat_state.config = old_config
	end)
	it("wraps for the popup width and keeps keyboard focus on wrapped options", function()
		chat_state.config = vim.tbl_deep_extend("force", chat_state.config or {}, { width = 120 })
		dialog = require("opencode.ui.form").open({
			{ key = "choice", type = "string", title = "Region", options = {
				{ label = string.rep("Long option ", 20), value = "one" }, { label = "SECOND_OPTION", value = "two" },
			} },
		}, { title = "Popup width" }, function() end)
		local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
		local width = vim.api.nvim_win_get_width(win)
		for _, line in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do assert.is_true(vim.fn.strdisplaywidth(line) <= width) end
		vim.fn.maparg("j", "n", false, true).callback()
		local row = vim.api.nvim_win_get_cursor(win)[1]
		assert.is_truthy(vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]:find("SECOND_OPTION", 1, true))
	end)
end)
