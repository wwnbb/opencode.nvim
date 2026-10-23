describe("hidden chat cursor", function()
	local saved_normal

	before_each(function()
		saved_normal = vim.api.nvim_get_hl(0, { name = "Normal" })
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false } })
	end)
	after_each(function()
		vim.api.nvim_set_hl(0, "Normal", saved_normal)
	end)

	it("matches the Normal background and follows colorscheme changes", function()
		vim.api.nvim_set_hl(0, "Normal", { fg = 0xffffff, bg = 0x112233 })
		vim.api.nvim_exec_autocmds("ColorScheme", { pattern = "test" })
		local hl = vim.api.nvim_get_hl(0, { name = "OpenCodeHiddenCursor" })
		assert.equals(0x112233, hl.fg)
		assert.equals(0x112233, hl.bg)
		assert.equals(100, hl.blend)
		assert.is_true(hl.nocombine)
	end)

	it("hides the cursor in opencode filetype windows", function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		local win = vim.api.nvim_open_win(bufnr, true, { relative = "editor", row = 1, col = 1, width = 10, height = 2 })
		vim.wo[win].winhighlight = "Normal:Normal"
		vim.wo[win].cursorline = true
		vim.bo[bufnr].filetype = "opencode"
		assert.equals("Normal:Normal,Cursor:OpenCodeHiddenCursor,lCursor:OpenCodeHiddenCursor,"
			.. "CursorLine:OpenCodeHiddenCursor,CursorColumn:OpenCodeHiddenCursor", vim.wo[win].winhighlight)
		assert.is_false(vim.wo[win].cursorline)
		vim.api.nvim_win_close(win, true)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)
end)
