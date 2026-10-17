local api = require("opencode")
local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local views = require("opencode.ui.chat.state")
local lifecycle = require("opencode.lifecycle")
local client = require("opencode.client")
local pending = require("opencode.session.pending")

local function settle() vim.wait(40, function() return false end, 5) end

describe("tab lifecycle asynchronous boundaries", function()
	local editor, first, create, saved
	before_each(function()
		editor = vim.api.nvim_get_current_tabpage()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "tab" } })
		saved = { lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify }
		lifecycle.ensure_connected = function(callback) callback() end
		client.create_session = function(_, callback) create = callback end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		vim.notify = function() end
		app.upsert_session({ id = "review-a", title = "A", directory = "/tmp/review" })
		app.set_session("review-a", "A")
		views.state.session_bound = false
		chat.open()
		first = chat.get_view()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(views.all()) do if view.visible then chat.close_view(view) end end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		lifecycle.ensure_connected, client.create_session, client.get_messages, vim.notify = unpack(saved)
	end)

	it("does not open a split after its connection attempt was invalidated", function()
		api.split("vertical")
		pending.invalidate()
		create(nil, { id = "review-stale", title = "Old server session" })
		settle()
		assert.is_true(views.for_session("review-stale") == nil)
		assert.equals(first.winid, vim.api.nvim_get_current_win())
	end)

	it("opens the newly created session after all chat panes were closed", function()
		chat.close_view(first)
		settle()
		api.new_session()
		create(nil, { id = "review-new", title = "New" })
		settle()
		chat.open()
		assert.equals("review-new", views.session(chat.get_view()).id)
	end)

	it("saves the composer before native tabclose tears down all chat panes", function()
		local input, history = require("opencode.ui.input"), require("opencode.ui.input.history")
		local second = chat.create_split(first, { id = "review-b", title = "B" }, "vertical")
		chat.focus_input()
		input.set_pending_text("Draft survives tabclose")
		vim.cmd("tabclose!")
		settle()
		assert.is_false(first.visible)
		assert.is_false(second.visible)
		assert.is_false(input.is_visible())
		assert.equals("Draft survives tabclose", history.get_pending("review-b"))
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
	end)
end)
