describe("input surface contracts", function()
	local bufnr
	after_each(function()
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		bufnr = nil
	end)

	it("maps steer and queue to separate composer actions in both modes", function()
		local input_keymaps = require("opencode.ui.input.keymaps")
		bufnr = vim.api.nvim_create_buf(false, true)
		local calls, autocomplete_visible = {}, false
		local function find(mode, lhs)
			local target = vim.api.nvim_replace_termcodes(lhs, true, false, true)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
				if vim.api.nvim_replace_termcodes(mapping.lhs, true, false, true) == target then
					return mapping.callback
				end
			end
		end
		local function callback(mode, lhs)
			return find(mode, lhs) or error("Missing " .. mode .. " composer mapping: " .. lhs)
		end
		-- Default keys: the main send steers, as Enter does in the TUI, and Ctrl+Shift+G queues.
		input_keymaps.setup(bufnr, { keymaps = {} }, {
			send_queue = function() calls[#calls + 1] = "queue" end,
			send_steer = function() calls[#calls + 1] = "steer" end,
			autocomplete_visible = function() return autocomplete_visible end,
			autocomplete_confirm = function() calls[#calls + 1] = "confirm" end,
		})

		callback("n", "<C-g>")()
		callback("n", "<C-S-g>")()
		assert.same({ "steer", "queue" }, calls)
		assert.equals("", callback("i", "<C-g>")())
		assert.equals("", callback("i", "<C-S-g>")())
		assert.is_true(vim.wait(100, function() return #calls == 4 end, 5))
		assert.same({ "steer", "queue", "steer", "queue" }, calls)
		assert.is_nil(find("i", "<C-x><C-s>"))

		autocomplete_visible = true
		assert.equals("", callback("i", "<C-S-g>")())
		assert.is_true(vim.wait(100, function() return #calls == 5 end, 5))
		assert.same({ "steer", "queue", "steer", "queue", "confirm" }, calls)
	end)
end)
