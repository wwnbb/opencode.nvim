local api = require("opencode")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local views = require("opencode.ui.chat.state")
local lifecycle = require("opencode.lifecycle")
local client = require("opencode.client")
local sync = require("opencode.sync")

local function settle() vim.wait(40, function() return false end, 5) end

describe("tab split keyboard input", function()
	local editor, first, created, saved
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor = vim.api.nvim_get_current_tabpage()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "tab" } })
		saved = { lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify }
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		vim.notify = function() end
		created = {}
		client.create_session = function(body, callback) created[#created + 1] = { body = body, callback = callback } end
		app.upsert_session({ id = "keyboard-a", title = "Original", directory = "/tmp/keyboard-project" })
		app.set_session("keyboard-a", "Original")
		views.state.session_bound = false
		chat.open()
		first = chat.get_view()
		sync.handle_message_updated({ id = "keyboard-message", sessionID = "keyboard-a", role = "assistant", time = { created = 1 } })
		sync.handle_part_updated({ id = "keyboard-text", messageID = "keyboard-message", sessionID = "keyboard-a",
			type = "text", text = "Original transcript survives the split" })
		chat.for_view(first).do_render()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(views.all()) do if view.visible then chat.close_view(view) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = unpack(saved)
		sync.clear_all()
	end)

	for _, keys in ipairs({ "<C-w>v", "<C-w>s" }) do
		it("creates an independent chat with " .. keys, function()
			local original_win, original_buf = first.winid, first.bufnr
			local windows = #vim.api.nvim_tabpage_list_wins(first.tabpage)
			vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
			settle()
			assert.equals(1, #created, "split keys must reach session creation instead of a native buffer copy")
			assert.equals(windows, #vim.api.nvim_tabpage_list_wins(first.tabpage))
			assert.equals("/tmp/keyboard-project", created[1].body.location.directory)
			created[1].callback(nil, { id = "keyboard-b", title = "Independent" })
			settle()
			local second = chat.get_view()
			assert.equals(windows + 1, #vim.api.nvim_tabpage_list_wins(first.tabpage))
			assert.is_not.equals(first.bufnr, second.bufnr)
			assert.equals("keyboard-a", views.session(first).id)
			assert.equals("keyboard-b", views.session(second).id)
			assert.equals(original_win, first.winid)
			assert.equals(original_buf, vim.api.nvim_win_get_buf(original_win))
			assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(original_buf, 0, -1, false), "\n")
				:find("Original transcript survives the split", 1, true))
			local left = vim.api.nvim_win_get_position(first.winid)
			local right = vim.api.nvim_win_get_position(second.winid)
			if keys:find("v", 1, true) then
				assert.equals(left[1], right[1])
				assert.is_true(left[2] < right[2])
			else
				assert.equals(left[2], right[2])
				assert.is_true(left[1] < right[1])
			end
		end)
	end
end)
