local app = require("opencode.state")
local chat = require("opencode.ui.chat")
local views = require("opencode.ui.chat.state")
local client = require("opencode.client")

local function settle() vim.wait(40, function() return false end, 5) end

describe("reopening a replaced chat buffer", function()
	local editor, first, original_messages, files
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor, files = vim.api.nvim_get_current_tabpage(), {}
		app.reset(); require("opencode.sync").clear_all()
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { persist = false } } })
		original_messages = client.get_messages
		client.get_messages = function(_, _, done) done(nil, {}) end
		require("opencode.session").set_active("replacement-a", "A")
		chat.open(); settle()
		first = chat.get_view()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(views.all()) do
			views.module(view, require("opencode.ui.chat.execute_details")).close(false)
			if view.visible then chat.close_view(view) end
		end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		for _, file in ipairs(files) do
			if vim.api.nvim_buf_is_valid(file) then vim.api.nvim_buf_delete(file, { force = true }) end
		end
		settle()
		client.get_messages = original_messages
		require("opencode.sync").clear_all()
	end)

	local function replace(view)
		local win, tab = view.winid, view.tabpage
		local file = vim.api.nvim_create_buf(true, false)
		files[#files + 1] = file
		vim.api.nvim_win_set_buf(win, file)
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "Unsaved replacement" })
		return file, win, tab
	end

	local function assert_preserved(file, win, tab)
		assert.is_true(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_true(vim.api.nvim_win_is_valid(win))
		assert.equals(file, vim.api.nvim_win_get_buf(win))
		assert.same({ "Unsaved replacement" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
		assert.is_true(vim.bo[file].modified)
	end

	local function open_details()
		local details = views.module(first, require("opencode.ui.chat.execute_details"))
		local popup = details.open({ type = "tool", tool = "execute", state = {
			status = "completed", input = { code = "return 1" }, output = "Result", metadata = {},
		} })
		assert.is_not_nil(popup)
		return details, popup
	end

	it("opens a new chat tab while leaving the modified file in its original window", function()
		local file, win, tab = replace(first)
		chat.open(); settle()
		assert_preserved(file, win, tab)
		local reopened = chat.get_view()
		assert.is_true(views.is_chat_buffer_displayed(reopened))
		assert.is_not.equals(tab, reopened.tabpage)
		assert.equals("replacement-a", views.session(reopened).id)
	end)

	it("reuses another chat pane when the last focused pane became a file", function()
		app.upsert_session({ id = "replacement-b", title = "B" })
		local second = chat.create_split(first, app.get_session_record("replacement-b"), "vertical")
		local file, win, tab = replace(second)
		chat.open(); settle()
		assert_preserved(file, win, tab)
		assert.equals(first, chat.get_view())
		assert.equals(first.winid, vim.api.nvim_get_current_win())
		assert.is_false(views.valid(second))
		assert.equals("replacement-a", views.session(first).id)
	end)

	it("reassociates a surviving native mirror without replacing the modified file", function()
		local original_win = first.winid
		vim.cmd("vsplit"); settle()
		local file, win, tab = replace(first)
		chat.open(); settle()
		assert_preserved(file, win, tab)
		assert.equals(original_win, first.winid)
		assert.equals(original_win, vim.api.nvim_get_current_win())
		assert.is_true(views.is_chat_buffer_displayed(first))
	end)

	it("keeps an execute detail page as the owned chat surface", function()
		local details, popup = open_details()
		local win, tab = first.winid, first.tabpage
		vim.api.nvim_set_current_tabpage(editor)
		chat.open(); settle()
		assert.equals(first, chat.get_view())
		assert.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.equals(win, vim.api.nvim_get_current_win())
		assert.equals(popup.bufnr, vim.api.nvim_get_current_buf())
		assert.is_true(details.is_open())
	end)
	it("returns from details with q and closes the physical pane through the chat API", function()
		local win, tab = first.winid, first.tabpage
		local details = open_details()
		local close = vim.fn.maparg("q", "n", false, true).callback
		assert.is_function(close)
		close(); settle()
		assert.is_false(details.is_open())
		assert.equals(first.bufnr, vim.api.nvim_win_get_buf(win))
		assert.is_true(first.visible)
		open_details()
		chat.close_view(first); settle()
		assert.is_false(vim.api.nvim_win_is_valid(win))
		assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_false(first.visible)
	end)

	it("preserves the surviving mirror's view state when closing its detail window", function()
		local original_win = first.winid
		vim.cmd("vsplit"); settle()
		local mirror = first.winid
		first.expanded_tools["retained-tool"] = true
		open_details()
		chat.close_view(first); settle()
		assert.is_false(vim.api.nvim_win_is_valid(mirror))
		assert.equals(original_win, first.winid)
		assert.is_true(first.visible)
		assert.is_true(views.is_chat_buffer_displayed(first))
		assert.is_true(first.expanded_tools["retained-tool"])
		assert.equals("replacement-a", views.session(first).id)
	end)

	for _, kind in ipairs({ "details", "file" }) do
		for _, mirror in ipairs({ false, true }) do
			it("closes the session with " .. (mirror and "x across mirrors" or "the global API") .. " while showing " .. kind, function()
				if mirror then vim.cmd("vsplit"); settle() end
				local windows = views.windows(first)
				local close_session
				if mirror then
					close_session = vim.fn.maparg("x", "n", false, true).callback
					assert.is_function(close_session)
				else
					close_session = function() require("opencode").close_session({ silent = true }) end
				end
				local file, win, tab
				if kind == "details" then open_details() else file, win, tab = replace(first) end
				close_session(); settle()
				assert.is_false(first.visible)
				assert.is_nil(views.for_session("replacement-a"))
				assert.is_false(app.is_runtime_session("replacement-a"))
				for _, window in ipairs(windows) do
					if mirror or window ~= win then assert.is_false(vim.api.nvim_win_is_valid(window)) end
				end
				if file then
					if mirror then
						assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
						assert.is_true(vim.api.nvim_buf_is_valid(file))
						assert.same({ "Unsaved replacement" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
						assert.is_true(vim.bo[file].modified)
					else assert_preserved(file, win, tab) end
				end
			end)
		end
	end

end)
