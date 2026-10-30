local api = require("opencode")
local state, sync = require("opencode.state"), require("opencode.sync")
local sessions = require("opencode.session")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
local workspace = require("opencode.ui.chat.workspace")
local context = require("opencode.context")

local function settle() vim.wait(40, function() return false end, 5) end

local function seed(id)
	local session = { id = id, title = id, directory = vim.fn.getcwd() }
	sessions.remember(session)
	return session
end

local function placeholders()
	return #vim.tbl_filter(function(buf)
		return vim.bo[buf].buflisted and vim.api.nvim_buf_get_name(buf) == "" and vim.bo[buf].buftype == ""
	end, vim.api.nvim_list_bufs())
end

describe("switching the tab workspace", function()
	local editor, editor_window, source, saved, files
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor, editor_window = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
		state.reset(); sync.clear_all()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "tab" } })
		saved = { messages = client.get_messages, ensure = lifecycle.ensure_connected }
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		lifecycle.ensure_connected = function(callback) callback() end
		source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".lua")
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local first = 1", "local second = 2", "local third = 3" })
		vim.api.nvim_win_set_buf(editor_window, source)
		vim.api.nvim_win_set_cursor(editor_window, { 2, 6 })
		files = { source }
		seed("switch-a")
		sessions.set_active("switch-a", "switch-a")
		chat.open(); settle()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		if not views.workspace.tabpage then workspace.reset() end
		for _ = 1, 10 do
			if #workspace.list() == 0 then break end
			workspace.close_current(); settle()
		end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		for _, buf in ipairs(files) do
			if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		client.get_messages, lifecycle.ensure_connected = saved.messages, saved.ensure
	end)

	local function sidebar()
		vim.cmd("topleft vsplit")
		local tree = vim.api.nvim_create_buf(false, true)
		files[#files + 1] = tree
		vim.api.nvim_win_set_buf(0, tree)
		vim.wo.winfixbuf = true
		return vim.api.nvim_get_current_win(), tree
	end

	it("creates and cycles layouts while a 'winfixbuf' pane leads the workspace", function()
		local first, original = chat.get_view(), workspace.current().id
		local _, tree = sidebar()
		vim.api.nvim_set_current_win(first.winid)
		assert.is_true(vim.wo[vim.api.nvim_tabpage_list_wins(views.workspace.tabpage)[1]].winfixbuf)
		local created = chat.create_layout(seed("switch-b")); settle()
		assert.equals(2, #workspace.list())
		assert.is_true(views.is_chat_buffer_displayed(created))
		assert.is_false(vim.wo[created.winid].winfixbuf)
		workspace.select(original); settle()
		assert.is_true(views.is_chat_buffer_displayed(first))
		local restored = vim.fn.win_findbuf(tree)
		assert.equals(1, #restored)
		assert.is_true(vim.wo[restored[1]].winfixbuf)
		workspace.cycle(1); settle()
		assert.is_true(views.is_chat_buffer_displayed(created))
		workspace.cycle(-1); settle()
		assert.equals(original, workspace.current().id)
	end)

	it("keeps the editor as the context source across park and resume", function()
		local before = placeholders()
		for cursor = 1, 3 do
			chat.toggle(); settle()
			assert.is_true(workspace.is_parked())
			assert.equals(editor_window, vim.api.nvim_get_current_win())
			vim.api.nvim_win_set_cursor(editor_window, { cursor, 0 })
			chat.toggle(); settle()
			assert.equals(views.workspace.tabpage, vim.api.nvim_get_current_tabpage())
			local current = context.source()
			assert.equals(source, current.bufnr)
			assert.equals(cursor - 1, current.row)
		end
		assert.equals(before, placeholders(), "workspace tabs must not leave [No Name] buffers")
	end)

	it("keeps the context source when switching between layouts with file panes", function()
		local first, original = chat.get_view(), workspace.current().id
		for _, name in ipairs({ "pane-one", "pane-two" }) do
			vim.cmd("rightbelow vsplit")
			local file = vim.api.nvim_create_buf(true, false)
			files[#files + 1] = file
			vim.api.nvim_buf_set_name(file, vim.fn.tempname() .. "-" .. name .. ".lua")
			vim.api.nvim_win_set_buf(0, file)
		end
		vim.api.nvim_set_current_win(first.winid)
		local expected = context.source()
		chat.create_layout(seed("switch-c")); settle()
		workspace.select(original); settle()
		assert.same(expected, context.source())
	end)
end)
