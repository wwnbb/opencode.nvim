describe("input surface contracts", function()
	local bufnr
	after_each(function()
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		bufnr = nil
	end)

	it("maps queue and steer to separate composer actions in both modes", function()
		local input_keymaps = require("opencode.ui.input.keymaps")
		bufnr = vim.api.nvim_create_buf(false, true)
		local calls, autocomplete_visible = {}, false
		local function callback(mode, lhs)
			local target = vim.api.nvim_replace_termcodes(lhs, true, false, true)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
				if vim.api.nvim_replace_termcodes(mapping.lhs, true, false, true) == target then
					return mapping.callback
				end
			end
			error("Missing " .. mode .. " composer mapping: " .. lhs)
		end
		input_keymaps.setup(bufnr, {
			keymaps = { send = "<C-g>", send_steer = "<C-x><C-s>" },
		}, {
			send = function() calls[#calls + 1] = "queue" end,
			send_steer = function() calls[#calls + 1] = "steer" end,
			autocomplete_visible = function() return autocomplete_visible end,
			autocomplete_confirm = function() calls[#calls + 1] = "confirm" end,
		})

		callback("n", "<C-g>")()
		callback("n", "<C-x><C-s>")()
		assert.same({ "queue", "steer" }, calls)
		assert.equals("", callback("i", "<C-g>")())
		assert.equals("", callback("i", "<C-x><C-s>")())
		assert.is_true(vim.wait(100, function() return #calls == 4 end, 5))
		assert.same({ "queue", "steer", "queue", "steer" }, calls)

		autocomplete_visible = true
		assert.equals("", callback("i", "<C-x><C-s>")())
		assert.is_true(vim.wait(100, function() return #calls == 5 end, 5))
		assert.same({ "queue", "steer", "queue", "steer", "confirm" }, calls)
	end)

end)
