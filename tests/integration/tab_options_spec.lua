describe("tab layout window options after Neovim startup", function()
	local editor
	before_each(function() editor = require("tests.helpers.embedded_editor").new() end)
	after_each(function() if editor then editor.close() end end)

	it("restores local folds without refreshing deleted Treesitter buffers or changing defaults", function()
		local result = editor.lua([[
			vim.go.foldmethod = "expr"
			vim.go.foldexpr = "v:lua.vim.treesitter.foldexpr()"
			vim.go.foldnestmax, vim.go.scrolloff = 20, 7
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = "tab", session_tabs = { persist = false } } })
			local sessions = require("opencode.session")
			local chat = require("opencode.ui.chat")
			local workspace = require("opencode.ui.chat.workspace")
			local function seed(id)
				local session = { id = id, title = id }
				sessions.remember(session)
				return session
			end
			seed("options-a"); sessions.set_active("options-a", "options-a")
			chat.open()
			local first = chat.get_view()
			local second = chat.create_split(first, seed("options-b"), "vertical")
			local original = workspace.current().id
			vim.api.nvim_set_option_value("foldnestmax", 3, { win = first.winid, scope = "local" })
			vim.api.nvim_set_option_value("foldnestmax", 5, { win = second.winid, scope = "local" })
			vim.api.nvim_set_option_value("scrolloff", -1, { win = first.winid, scope = "local" })
			vim.api.nvim_set_option_value("scrolloff", 2, { win = second.winid, scope = "local" })
			chat.create_layout(seed("options-c"))
			local other = workspace.current().id

			-- Popup teardown can wipe a buffer without firing Treesitter's BufUnload hook.
			local scratch = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_call(scratch, function() vim.treesitter.foldexpr(1) end)
			vim.cmd("noautocmd bwipeout! " .. scratch)
			assert(not vim.api.nvim_buf_is_valid(scratch))
			local changes = {}
			vim.api.nvim_create_autocmd("OptionSet", { pattern = { "foldnestmax", "foldminlines" },
				callback = function() changes[#changes + 1] = vim.v.option_type end })
			vim.v.errmsg = ""
			-- Keep failures in v:errmsg without blocking RPC on the hit-enter prompt.
			for _ = 1, 3 do
				vim.cmd("silent! lua require('opencode.ui.chat.workspace').select(" .. original .. ")")
				vim.cmd("silent! lua require('opencode.ui.chat.workspace').select(" .. other .. ")")
			end
			vim.cmd("silent! lua require('opencode.ui.chat.workspace').select(" .. original .. ")")
			local function options(view)
				return {
					vim.api.nvim_get_option_value("foldnestmax", { win = view.winid, scope = "local" }),
					vim.api.nvim_get_option_value("scrolloff", { win = view.winid, scope = "local" }),
				}
			end
			return { error = vim.v.errmsg, changes = changes, first = options(first), second = options(second),
				defaults = { vim.go.foldnestmax, vim.go.scrolloff }, current = chat.get_view().session_id }
		]])
		assert.equals("", result.error)
		assert.is_true(#result.changes > 0, "OptionSet must run after startup")
		for _, scope in ipairs(result.changes) do assert.equals("local", scope) end
		assert.same({ 3, -1 }, result.first)
		assert.same({ 5, 2 }, result.second)
		assert.same({ 20, 7 }, result.defaults)
		assert.equals("options-b", result.current)
	end)
end)
