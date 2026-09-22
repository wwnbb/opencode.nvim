local input = require("opencode.ui.input")
local history = require("opencode.ui.input.history")
local app_state = require("opencode.state")
local defaults = require("opencode.config").defaults
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")

describe("input code highlighting", function()
	local config, previous_config, previous_columns, previous_lines, history_file

	local function buffer()
		return vim.api.nvim_win_get_buf(input.get_winids()[1])
	end

	local function marks()
		return vim.api.nvim_buf_get_extmarks(buffer(), namespace, 0, -1, { details = true })
	end

	local function fragments(group)
		local result = {}
		for _, mark in ipairs(marks()) do
			local row, col, detail = mark[2], mark[3], mark[4]
			if not group or detail.hl_group:find(group, 1, true) then
				local line = vim.api.nvim_buf_get_lines(buffer(), row, row + 1, false)[1]
				result[#result + 1] = line:sub(col + 1, detail.end_col)
			end
		end
		return table.concat(result, "|")
	end

	local function wait_for(predicate)
		assert.is_true(vim.wait(1000, predicate, 5), "Input highlights did not update")
	end

	local function keys(text)
		vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(text, true, false, true), "nxt", false)
	end

	before_each(function()
		previous_config = app_state.get_config()
		previous_columns, previous_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 100, 40
		config = vim.deepcopy(defaults)
		history_file = vim.fn.tempname()
		config.input.history_file = history_file
		config.syntax.user_markdown = false -- The input has its own switch.
		app_state.set_config(config)
		history.clear_pending()
		assert.is_true(pcall(vim.treesitter.language.add, "lua"))
		assert.is_not_nil(vim.treesitter.query.get("lua", "highlights"))
	end)

	after_each(function()
		input.close(false)
		history.clear()
		app_state.set_config(previous_config)
		vim.o.columns, vim.o.lines = previous_columns, previous_lines
		vim.wait(20, function() return false end, 5)
	end)

	it("highlights restored code with Unicode and indentation without modifying the draft or cursor", function()
		local draft = '@src/example.lua#1-2\n  ```lua\n  local text = "Привет 猫🙂"\n  return text\n  ```\nExplain the code'
		input.set_pending_text(draft)
		input.show()
		local win, buf = input.get_winids()[1], buffer()
		local cursor = vim.api.nvim_win_get_cursor(win)
		wait_for(function() return fragments("@keyword"):find("return", 1, true) ~= nil end)
		assert.is_truthy(fragments("@string"):find("Привет 猫🙂", 1, true))
		for _, mark in ipairs(marks()) do
			assert.is_true(mark[2] == 2 or mark[2] == 3)
			assert.is_true(mark[3] >= 2)
			assert.is_true(mark[4].priority < 200, "Input syntax should use normal editing priorities")
		end
		assert.equals("opencode_input", vim.bo[buf].filetype)
		assert.equals(draft, input.get_pending_text())
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.same(cursor, vim.api.nvim_win_get_cursor(win))
	end)

	it("updates open fences while typing, undoing and editing the language or delimiters", function()
		input.show({ text = "```lua\n" })
		local buf = buffer()
		keys("Areturn 1<Esc>")
		wait_for(function() return fragments("@keyword"):find("return", 1, true) ~= nil end)
		keys("u")
		wait_for(function() return #marks() == 0 end)
		keys("<C-r>")
		wait_for(function() return #marks() > 0 end)
		vim.api.nvim_buf_set_text(buf, 0, 3, 0, 6, { "missing_parser" })
		wait_for(function() return #marks() == 0 end)
		vim.api.nvim_buf_set_text(buf, 0, 3, 0, #"```missing_parser", { "lua" })
		wait_for(function() return #marks() > 0 end)
		vim.api.nvim_buf_set_lines(buf, -1, -1, false, { "```", "return is prose here" })
		vim.wait(20, function() return false end, 5)
		for _, mark in ipairs(marks()) do assert.equals(1, mark[2]) end
		vim.api.nvim_buf_set_lines(buf, 0, 1, false, {})
		wait_for(function() return #marks() == 0 end)
	end)

	it("clears disabled and over-limit blocks and resumes after a draft replacement", function()
		local draft = "```lua\nreturn 1\nreturn 2\n```"
		input.show({ text = draft })
		wait_for(function() return #marks() > 0 end)
		for _, setting in ipairs({
			{ "syntax", "input_markdown", false }, { "syntax", "enabled", false },
			{ "markdown", "enable_code_highlight", false }, { "syntax", "max_lines", 1 },
			{ "syntax", "max_bytes", 3 },
		}) do
			local section, key, value = unpack(setting)
			local old = config[section][key]
			config[section][key] = value
			app_state.set_config(config)
			input.set_pending_text(draft)
			wait_for(function() return #marks() == 0 end)
			config[section][key] = old
			app_state.set_config(config)
			input.set_pending_text(draft)
			wait_for(function() return #marks() > 0 end)
		end
	end)

	it("refreshes theme wrappers without changing the input background", function()
		input.show({ text = "```lua\nreturn 1" })
		wait_for(function() return #marks() > 0 end)
		local group = marks()[1][4].hl_group
		local original = vim.api.nvim_get_hl(0, { name = group })
		local ok, err = pcall(function()
			vim.api.nvim_set_hl(0, group, { fg = 0xAABBCC, bg = 0x123456 })
			vim.api.nvim_exec_autocmds("ColorScheme", {})
			wait_for(function() return marks()[1][4].hl_group:match("^OpenCodeSyntax_") ~= nil end)
			local updated = vim.api.nvim_get_hl(0, { name = marks()[1][4].hl_group, link = false })
			assert.equals(0xAABBCC, updated.fg)
			assert.is_nil(updated.bg)
		end)
		vim.api.nvim_set_hl(0, group, original)
		vim.api.nvim_exec_autocmds("ColorScheme", {})
		assert.is_true(ok, err)
	end)

	it("discards queued work and color callbacks when closing and restores highlights on reopen", function()
		input.show({ text = "```lua\nreturn 1" })
		wait_for(function() return #marks() > 0 end)
		local old_buf = buffer()
		input.set_pending_text("```lua\nreturn 2")
		input.close()
		assert.is_false(vim.api.nvim_buf_is_valid(old_buf))
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputSyntax" }))
		input.show()
		wait_for(function() return fragments("@number"):find("2", 1, true) ~= nil end)
		assert.equals("```lua\nreturn 2", input.get_pending_text())
		assert.equals(1, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputSyntax" }))
	end)

	it("highlights history navigation and sends the original text before clearing the input", function()
		local sent
		input.show({ text = "", close_on_send = false, add_history = false, on_send = function(text) sent = text end })
		local draft = "```lua\nreturn 42\n```"
		history.add(draft)
		local keymap = vim.fn.maparg(config.input.keymaps.history_prev, "i", false, true)
		keymap.callback()
		wait_for(function() return #marks() > 0 end)
		vim.fn.maparg(config.input.keymaps.send, "n", false, true).callback()
		assert.equals(draft, sent)
		wait_for(function() return #marks() == 0 end)
		assert.equals("", input.get_pending_text())
	end)
end)
