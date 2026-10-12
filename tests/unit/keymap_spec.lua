local keymaps = require("opencode.util.keymap")

describe("temporary buffer mappings", function()
	local bufnr
	before_each(function() bufnr = vim.api.nvim_create_buf(true, false) end)
	after_each(function() vim.api.nvim_buf_delete(bufnr, { force = true }) end)

	it("restores the previous mapping for a literal less-than key", function()
		vim.keymap.set("n", "<", function() return "h" end, { buffer = bufnr, expr = true, nowait = true })
		local previous = vim.api.nvim_buf_get_keymap(bufnr, "n")
		local installed = keymaps.install("n", bufnr, "<", function() end)
		keymaps.restore(installed)
		assert.same(previous, vim.api.nvim_buf_get_keymap(bufnr, "n"))
	end)

	it("removes a literal less-than mapping when there was no previous owner", function()
		local installed = keymaps.install("n", bufnr, "<", function() end)
		keymaps.restore(installed)
		assert.same({}, vim.api.nvim_buf_get_keymap(bufnr, "n"))
	end)

	it("preserves a literal less-than mapping installed by a new owner", function()
		local installed = keymaps.install("n", bufnr, "<", function() end)
		local replacement = function() end
		vim.keymap.set("n", "<", replacement, { buffer = bufnr })
		keymaps.restore(installed)
		assert.equals(replacement, vim.api.nvim_buf_get_keymap(bufnr, "n")[1].callback)
	end)
end)
