describe("input resize", function()
	local app, chat, input = require("opencode"), require("opencode.ui.chat"), require("opencode.ui.input")
	local old_columns, old_lines

	local function geometry(winid)
		local position = vim.api.nvim_win_get_position(winid)
		return {
			row = position[1],
			col = position[2],
			width = vim.api.nvim_win_get_width(winid),
			height = vim.api.nvim_win_get_height(winid),
		}
	end

	local function flush_scheduled()
		vim.wait(50, function() return false end, 5)
	end

	before_each(function()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 40
		require("opencode.ui.input.history").clear_pending()
	end)

	after_each(function()
		input.close(false)
		chat.close()
		require("opencode.cleanup").reset_all()
		flush_scheduled()
		vim.o.columns, vim.o.lines = old_columns, old_lines
	end)

	it("keeps floating input anchored while typing, growing and shrinking", function()
		app.setup({ server = { auto_start = false }, chat = { layout = "float", close_on_focus_lost = false }, lualine = { enabled = false } })
		chat.open()
		chat.focus_input()
		local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		local info_win = input.get_winids()[2]
		local initial, info_initial, chat_initial = geometry(win), geometry(info_win), geometry(chat.get_winid())

		for _, draft in ipairs({ { "Привет" }, { "Привет", "second line", "third line" }, { "short again" } }) do
			vim.api.nvim_buf_set_lines(buf, 0, -1, false, draft)
			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
			assert.is_true(vim.wait(500, function() return vim.api.nvim_win_get_height(win) == #draft end, 5))
			-- Headless Neovim needs the resize event normally emitted by the UI.
			vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { win } } })
			flush_scheduled()

			local current = geometry(win)
			assert.equals(initial.row + initial.height, current.row + current.height)
			assert.equals(initial.col, current.col)
			assert.equals(initial.width, current.width)
			assert.same(info_initial, geometry(info_win))
			assert.same(chat_initial, geometry(chat.get_winid()))
			assert.equals(win, vim.api.nvim_get_current_win())
			assert.same(draft, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		end
	end)

	it("moves floating input with its parent without changing its offsets", function()
		app.setup({ server = { auto_start = false }, chat = { layout = "float", close_on_focus_lost = false }, lualine = { enabled = false } })
		chat.open()
		chat.focus_input()
		local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		local info_win = input.get_winids()[2]
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Draft survives moving the float", "Привет" })
		vim.api.nvim_exec_autocmds("TextChangedI", { buffer = buf })
		flush_scheduled()
		local initial, info_initial, parent_initial = geometry(win), geometry(info_win), geometry(chat.get_winid())

		local popup = require("opencode.ui.chat.state").state.layout
		popup:update_layout({ position = { row = 2, col = 5 }, size = { width = 80, height = 24 } })
		vim.api.nvim_exec_autocmds("WinResized", { data = { windows = { chat.get_winid() } } })
		flush_scheduled()
		local parent = geometry(chat.get_winid())
		for _, pair in ipairs({ { win, initial }, { info_win, info_initial } }) do
			local current, previous = geometry(pair[1]), pair[2]
			assert.equals(previous.row + parent.row - parent_initial.row + parent.height - parent_initial.height, current.row)
			assert.equals(previous.col + parent.col - parent_initial.col, current.col)
			assert.equals(previous.width + parent.width - parent_initial.width, current.width)
			assert.equals(previous.height, current.height)
		end
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.same({ "Draft survives moving the float", "Привет" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
	end)

	it("keeps draft, focus and both input surfaces inside a smaller parent", function()
		app.setup({ server = { auto_start = false }, chat = { width = 80, close_on_focus_lost = false }, lualine = { enabled = false } })
		chat.open(); chat.focus_input()
		local win, buf = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Draft survives resize Привет" })
		vim.o.columns, vim.o.lines = 80, 30
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.is_true(vim.wait(1000, function()
			for _, id in ipairs(input.get_winids()) do
				local pos = vim.api.nvim_win_get_position(id)
				if pos[1] + vim.api.nvim_win_get_height(id) >= vim.o.lines - vim.o.cmdheight then return false end
			end
			return #input.get_winids() == 2
		end, 10))
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.same({ "Draft survives resize Привет" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
		input.close(false)
		assert.equals(0, #vim.api.nvim_get_autocmds({ group = "OpenCodeInputResize" }))
	end)
end)
