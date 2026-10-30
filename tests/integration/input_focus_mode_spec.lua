-- Insert mode across composer focus changes, driven with real key input.
describe("composer Insert mode across focus changes", function()
	local client
	local function open(layout)
		client = require("tests.helpers.embedded_editor").new()
		client.request("nvim_ui_attach", { 160, 48, { rgb = true, ext_linegrid = true } })
		client.lua([[
			local layout = ...
			require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
				chat = { layout = layout, session_tabs = { enabled = false } },
				input = { history_file = vim.fn.tempname() } })
			require("opencode.client").get_messages = function(_, _, callback) callback(nil, {}) end
			require("opencode.lifecycle").ensure_connected = function(callback) callback() end
			vim.cmd("edit " .. vim.fn.tempname() .. ".txt")
			vim.api.nvim_buf_set_lines(0, 0, -1, false, { "editor line" })
			_G.file = vim.api.nvim_get_current_buf()
			_G.input, _G.chat = require("opencode.ui.input"), require("opencode.ui.chat")
			_G.mode = function() return vim.api.nvim_get_mode().mode end
			local app = require("opencode.state")
			for _, id in ipairs({ "mode-a", "mode-b" }) do app.upsert_session({ id = id, title = id }) end
			app.set_session("mode-a", "mode-a")
			chat.open()
		]], { layout })
	end
	local function wait(expression)
		assert.is_true(vim.wait(2000, function() return client.lua("return " .. expression) end, 10), expression .. "\n"
			.. vim.inspect(client.lua("return { mode = mode(), text = input.get_pending_text(), ft = vim.bo.filetype }")))
	end
	-- Let deferred closes and any pending :stopinsert take effect before asserting.
	local function settle() vim.wait(150, function() return false end, 10); client.lua("return true") end
	after_each(function() if client then client.close(); client = nil end end)

	it("keeps editing the window the user moves to from an Insert-mode composer", function()
		open("vertical")
		client.lua("chat.focus_input()")
		wait("input.is_visible() and mode() == 'i'")
		client.feed("draft")
		wait("input.get_pending_text() == 'draft'")
		client.feed("<C-o><C-w>t")
		wait("not input.is_visible() and vim.api.nvim_get_current_buf() == file")
		settle()
		assert.equals("i", client.lua("return mode()"))
		client.feed("x")
		wait("vim.api.nvim_buf_get_lines(file, 0, 1, false)[1] == 'xeditor line'")
		assert.equals("draft", client.lua([[return require("opencode.ui.input.history").get_pending("mode-a")]]))
	end)

	it("returns to Insert mode after another pane's navigation finishes in the background", function()
		open("tab")
		client.lua([[
			_G.A = chat.get_view()
			_G.B = chat.create_split(A, require("opencode.state").get_session_record("mode-b"), "vertical")
			require("opencode.client").create_session = function(_, callback) _G.created = callback end
			vim.api.nvim_set_current_win(B.winid)
			require("opencode").new_session({ view = B })
			vim.api.nvim_set_current_win(A.winid)
			chat.for_view(A).focus_input()
		]])
		wait("created ~= nil and input.owner_view() == A and mode() == 'i'")
		client.feed("hello wor")
		wait("input.get_pending_text() == 'hello wor'")
		client.lua([[created(nil, { id = "mode-new", title = "mode-new", time = { created = 2, updated = 2 } })]])
		wait("#require('opencode.ui.chat.workspace').list() == 2 and input.owner_view() == A")
		settle()
		assert.equals("i", client.lua("return mode()"))
		client.feed("ld")
		wait("input.get_pending_text() == 'hello world'")
	end)
end)
