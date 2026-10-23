describe("searchable surface", function()
	local surface = require("opencode.ui.search_surface")
	local menu, palette = require("opencode.ui.menu"), require("opencode.ui.palette")

	it("keeps the layer specs menu and palette used to write by hand", function()
		local options = surface.window_options("Normal:X")
		assert.same({ winhighlight = "Normal:X", winblend = 0, wrap = false, cursorline = false, scrolloff = 0 }, options)
		local layers = surface.layers({ relative = "editor", row = 2, col = 3, zindex = 80, width = 40, frame_height = 12,
			list_row = 5, list_height = 4, frame = { enter = false }, content = { focusable = true }, input = false })
		assert.same({ relative = "editor", position = { row = 2, col = 3 }, size = { width = 40, height = 12 }, zindex = 80, enter = false }, layers.frame)
		assert.same({ position = { row = 5, col = 1 }, size = { width = 38, height = 4 }, zindex = 81, focusable = true }, layers.content)
		assert.is_nil(layers.input)
		layers = surface.layers({ relative = "editor", row = 0, col = 0, zindex = 50, width = 9, frame_height = 8, list_row = 5, list_height = 1 })
		assert.same({ position = { row = 3, col = 4 }, size = { width = 1, height = 1 }, zindex = 52 }, layers.input)
	end)

	local function configs(wins)
		local result = {}
		for _, win in ipairs(wins) do result[#result + 1] = vim.api.nvim_win_get_config(win) end
		return result
	end

	it("stacks the search input over the list over the frame in menu and palette", function()
		local ctx = menu.open({ items = { "alpha", "beta" }, searchable = true, width = 40, refocus_chat = false })
		local frame, content, input = unpack(configs({ ctx.frame.winid, ctx.popup.winid, ctx.input.winid }))
		assert.equals(frame.zindex + 1, content.zindex); assert.equals(frame.zindex + 2, input.zindex)
		assert.same({ 3, 4, 32 }, { input.row, input.col, input.width })
		assert.same({ 5, 1, 38 }, { content.row, content.col, content.width })
		local marks = vim.api.nvim_buf_get_extmarks(ctx.input.bufnr, -1, 0, -1, { details = true })
		assert.equals("Search", marks[1][4].virt_text[1][1])
		ctx.close()

		palette.show()
		local wins = configs(palette.get_winids())
		assert.equals(wins[3].zindex + 1, wins[2].zindex); assert.equals(wins[3].zindex + 2, wins[1].zindex)
		assert.same({ 3, 4 }, { wins[1].row, wins[1].col }); assert.same({ 5, 1 }, { wins[2].row, wins[2].col })
		palette.hide()
	end)
end)
