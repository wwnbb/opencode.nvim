local input_keymaps = require("opencode.ui.input.keymaps")

describe("configurable composer bindings", function()
	local bufnr, previous_buffer
	before_each(function()
		previous_buffer = vim.api.nvim_get_current_buf()
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_set_current_buf(bufnr)
	end)
	after_each(function()
		vim.api.nvim_set_current_buf(previous_buffer)
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

	it("lets custom send aliases replace Enter and Tab while retaining completion confirmation", function()
		local sent, confirmed, visible = 0, 0, false
		local configured = { send = { "<CR>", "<Tab>" } }
		input_keymaps.setup(bufnr, { keymaps = configured }, {
			send = function() sent = sent + 1 end,
			autocomplete_visible = function() return visible end,
			autocomplete_confirm = function() confirmed = confirmed + 1 end,
		})
		for _, key in ipairs({ "<CR>", "<Tab>" }) do
			assert.equals("", vim.fn.maparg(key, "i", false, true).callback())
		end
		local keymaps = require("opencode.util.keymap")
		assert.equals("<CR> / <Tab>", keymaps.label("input", "send", configured))
		assert.equals("<CR>", keymaps.label("input", "command_enter", configured))
		assert.equals("<Tab>", keymaps.label("input", "autocomplete_confirm", configured))
		assert.is_true(vim.wait(100, function() return sent == 2 end, 5))
		visible = true
		for _, key in ipairs({ "<CR>", "<Tab>" }) do
			assert.equals("", vim.fn.maparg(key, "i", false, true).callback())
		end
		assert.is_true(vim.wait(100, function() return confirmed == 2 end, 5))
		assert.equals(2, sent)
	end)

	it("disables all cancel aliases and independently configures shell, folds, and completion", function()
		local toggled, folded, selected = 0, nil, 0
		input_keymaps.setup(bufnr, { keymaps = {
			cancel = false, toggle_mode = "<M-s>", fold_toggle = "zf", autocomplete_prev = "<M-p>",
		} }, {
			cancel = function() error("cancel is disabled") end,
			toggle_mode = function() toggled = toggled + 1 end,
			fold = function(command) folded = command end,
			autocomplete_visible = function() return true end,
			autocomplete_prev = function() selected = selected + 1 end,
		})
		for _, key in ipairs({ "q", "<Esc>", "<C-c>" }) do
			for _, mode in ipairs({ "n", "i" }) do assert.is_nil(vim.fn.maparg(key, mode, false, true).callback) end
		end
		assert.is_nil(vim.fn.maparg("<C-\\>", "i", false, true).callback)
		assert.is_nil(vim.fn.maparg("za", "n", false, true).callback)
		assert.is_nil(vim.fn.maparg("<C-p>", "i", false, true).callback)
		assert.is_true(vim.fn.maparg("<S-Tab>", "i", false, true).buffer ~= 1)
		vim.fn.maparg("<M-s>", "i", false, true).callback()
		vim.fn.maparg("zf", "n", false, true).callback()
		vim.fn.maparg("<M-p>", "i", false, true).callback()
		assert.equals(1, toggled)
		assert.equals("za", folded)
		assert.is_true(vim.wait(100, function() return selected == 1 end, 5))
	end)

	it("keeps default Escape and q as normal-only cancellation", function()
		local cancelled = 0
		input_keymaps.setup(bufnr, { keymaps = {} }, { cancel = function() cancelled = cancelled + 1 end })
		for _, key in ipairs({ "<Esc>", "q" }) do
			assert.is_nil(vim.fn.maparg(key, "i", false, true).callback)
			vim.fn.maparg(key, "n", false, true).callback()
		end
		vim.fn.maparg("<C-c>", "i", false, true).callback()
		assert.equals(3, cancelled)
	end)
end)
