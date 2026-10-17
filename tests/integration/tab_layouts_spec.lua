local api = require("opencode")
local state, sync = require("opencode.state"), require("opencode.sync")
local sessions = require("opencode.session")
local chat, views = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
local workspace = require("opencode.ui.chat.workspace")

local function settle() vim.wait(40, function() return false end, 5) end
local function press(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	settle()
end

local function seed(id)
	local session = { id = id, title = id, directory = "/tmp/layout-project" }
	sessions.remember(session)
	local lines = {}
	for index = 1, 80 do lines[index] = id .. " paragraph " .. index end
	sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
	sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id,
		type = "text", text = table.concat(lines, "\n\n") })
	return session
end

local function normal_windows(tab)
	local result = {}
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
		if vim.api.nvim_win_get_config(win).relative == "" then result[#result + 1] = win end
	end
	return result
end

local function geometry(tab, buffers)
	local result = {}
	for _, win in ipairs(normal_windows(tab)) do
		local buf = vim.api.nvim_win_get_buf(win)
		if buffers[buf] then
			result[#result + 1] = { buf = buf, width = vim.api.nvim_win_get_width(win),
				height = vim.api.nvim_win_get_height(win), position = vim.api.nvim_win_get_position(win) }
		end
	end
	table.sort(result, function(a, b) return a.buf < b.buf end)
	return result
end

local function shared_bar(tab, panes)
	local windows, content = normal_windows(tab), {}
	local top = vim.o.showtabline == 2 or (vim.o.showtabline == 1 and #vim.api.nvim_list_tabpages() > 1)
	for _, view in ipairs(panes) do
		content[view.winid] = true
		assert.equals("", vim.wo[view.winid].winbar, "session tabs must not be repeated in chat panes")
	end
	assert.equals(#panes + 1, #windows, "there should be one shared bar above the content layout")
	for _, win in ipairs(windows) do
		if not content[win] then
			assert.equals(1, vim.api.nvim_win_get_height(win))
			assert.equals(vim.o.columns, vim.api.nvim_win_get_width(win))
			assert.equals(top and 1 or 0, vim.api.nvim_win_get_position(win)[1])
		end
	end
end

describe("OpenCode tabs with independent layouts", function()
	local editor, tab, first, original_layout, saved, creates, files, draft_ids, picker
	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		editor = vim.api.nvim_get_current_tabpage()
		state.reset(); sync.clear_all()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { persist = false } } })
		saved = { messages = client.get_messages, create = client.create_session, inbox = client.get_inbox,
			fork = client.fork_session,
			menu = require("opencode.ui.menu").open,
			ensure = lifecycle.ensure_connected, notify = vim.notify }
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		lifecycle.ensure_connected = function(callback) callback() end
		creates, files, draft_ids, picker = {}, {}, {}, nil
		client.create_session = function(body, callback) creates[#creates + 1] = { body = body, callback = callback } end
		vim.notify = function() end
		seed("layout-a")
		sessions.set_active("layout-a", "layout-a")
		views.state.session_bound = false
		chat.open(); settle()
		first, tab = chat.get_view(), vim.api.nvim_get_current_tabpage()
		original_layout = workspace.current().id
	end)

	after_each(function()
		if picker then picker.close() end
		require("opencode.ui.menu").open = saved.menu
		require("opencode.ui.palette").hide()
		require("opencode.ui.input").close()
		if not views.workspace.tabpage then workspace.reset() end
		for _ = 1, 10 do
			if #workspace.list() == 0 then break end
			workspace.close_current(); settle()
		end
		for _, native_tab in ipairs(vim.api.nvim_list_tabpages()) do
			if native_tab ~= editor then vim.api.nvim_set_current_tabpage(native_tab); vim.cmd("tabclose!") end
		end
		settle()
		for _, buf in ipairs(files) do
			if vim.api.nvim_buf_is_valid(buf) then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		for _, id in ipairs(draft_ids) do require("opencode.ui.input.history").clear_session(id) end
		client.get_messages, client.create_session, client.get_inbox = saved.messages, saved.create, saved.inbox
		client.fork_session = saved.fork
		lifecycle.ensure_connected, vim.notify = saved.ensure, saved.notify
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		sync.clear_all()
	end)

	it("uses one shared bar and keeps all layouts inside one Neovim tab", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		local third = chat.create_split(second, seed("layout-c"), "horizontal")
		settle()
		assert.equals(1, #workspace.list(), "split sessions belong to their existing layout")
		shared_bar(tab, { first, second, third })
		local native_tabs = #vim.api.nvim_list_tabpages()
		vim.wo[third.winid].winhighlight = "Normal:Normal"
		chat.create_layout(seed("layout-d")); settle()
		local next_view = chat.get_view()
		assert.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
		assert.equals(2, #workspace.list())
		assert.equals("layout-d", views.session(next_view).id)
		assert.equals("Normal:Normal", vim.wo[next_view.winid].winhighlight)
		assert.equals(vim.api.nvim_get_option_value("statusline", { scope = "global" }), vim.wo[next_view.winid].statusline)
		for _, view in ipairs({ first, second, third }) do
			assert.is_true(views.valid(view))
			assert.is_true(view.suspended)
			assert.is_false(view.visible)
		end
		shared_bar(tab, { next_view })
	end)

	it("restores nested splits, modified file buffers, focus, scroll and drafts repeatedly", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		local third = chat.create_split(second, seed("layout-c"), "horizontal")
		local file = vim.api.nvim_create_buf(true, false)
		files[#files + 1] = file
		vim.bo[file].bufhidden = "wipe"
		vim.api.nvim_win_call(third.winid, function()
			vim.cmd("rightbelow split")
			vim.api.nvim_win_set_buf(0, file)
		end)
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "Unsaved layout file" })
		vim.api.nvim_win_set_width(second.winid, 55)
		vim.api.nvim_win_set_height(third.winid, 10)
		settle()
		chat.for_view(first).do_render()
		first.auto_scroll, first.expanded_tools["retained-tool"] = false, true
		vim.api.nvim_win_call(first.winid, function()
			vim.api.nvim_win_set_cursor(0, { 30, 0 })
			vim.fn.winrestview({ topline = 15 })
		end)
		local saved_view = vim.api.nvim_win_call(first.winid, vim.fn.winsaveview)
		local buffers = { [first.bufnr] = true, [second.bufnr] = true, [third.bufnr] = true, [file] = true }
		local expected = geometry(tab, buffers)
		chat.focus_view(third)
		chat.focus_input()
		require("opencode.ui.input").set_pending_text("Layout draft survives switching")
		draft_ids[#draft_ids + 1] = third.session_id
		chat.create_layout(seed("layout-d")); settle()
		local other_layout = workspace.current().id
		for _ = 1, 3 do
			workspace.select(original_layout); settle()
			assert.equals(tab, vim.api.nvim_get_current_tabpage())
			assert.same(expected, geometry(tab, buffers))
			assert.equals(third, chat.get_view())
			assert.is_true(first.expanded_tools["retained-tool"])
			assert.is_false(first.auto_scroll)
			local restored = vim.api.nvim_win_call(first.winid, vim.fn.winsaveview)
			assert.equals(saved_view.lnum, restored.lnum)
			assert.equals(saved_view.topline, restored.topline)
			assert.is_true(vim.api.nvim_buf_is_valid(file))
			assert.is_true(vim.bo[file].modified)
			assert.same({ "Unsaved layout file" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
			assert.equals("Layout draft survives switching", require("opencode.ui.input.history").get_pending(third.session_id))
			workspace.select(other_layout); settle()
		end
	end)

	it("switches entire layouts with gt, gT and numbered selection", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		chat.create_layout(seed("layout-c")); settle()
		local second_layout = workspace.current().id
		press("gt")
		assert.equals(original_layout, workspace.current().id)
		assert.equals(second, chat.get_view())
		shared_bar(tab, { first, second })
		press("gT")
		assert.equals(second_layout, workspace.current().id)
		press("1gt")
		assert.equals(original_layout, workspace.current().id)
		press("2gt")
		assert.equals(second_layout, workspace.current().id)
		assert.equals("layout-c", views.session(chat.get_view()).id)
	end)

	it("keeps a delayed new-session response separate from the original split layout", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		chat.focus_view(first)
		press("N")
		assert.equals(1, #creates)
		chat.create_layout(seed("layout-c")); settle()
		local active_layout, active_view = workspace.current().id, chat.get_view()
		creates[1].callback(nil, { id = "layout-delayed", title = "Delayed", directory = "/tmp/layout-project" })
		settle()
		assert.equals(3, #workspace.list())
		assert.equals(active_layout, workspace.current().id, "a late response must not steal layout focus")
		assert.equals(active_view, chat.get_view())
		assert.equals("layout-a", views.session(first).id)
		assert.equals("layout-b", views.session(second).id)
		assert.is_true(views.valid(first))
		workspace.select(original_layout); settle()
		shared_bar(tab, { first, second })
		local layouts = workspace.list()
		workspace.select(layouts[#layouts].id); settle()
		assert.equals("layout-delayed", views.session(chat.get_view()).id)
	end)

	for _, destination in ipairs({ "layout", "editor" }) do
		it("drops a delayed palette opening after switching to another " .. destination, function()
			local connected
			lifecycle.ensure_connected = function(callback) connected = callback end
			api.command_palette()
			if destination == "layout" then chat.create_layout(seed("layout-b"))
			else vim.api.nvim_set_current_tabpage(editor) end
			settle()
			local selected, focused = workspace.current().id, vim.api.nvim_get_current_win()
			connected(); settle()
			assert.is_false(require("opencode.ui.palette").is_visible())
			assert.equals(selected, workspace.current().id)
			assert.equals(focused, vim.api.nvim_get_current_win())
		end)
	end

	for _, suspended in ipairs({ false, true }) do
		it("opens a delayed queue only while its owning pane is visible (suspended=" .. tostring(suspended) .. ")", function()
			local reply
			client.get_inbox = function(_, callback) reply = callback end
			require("opencode.ui.menu").open = function(opts) picker = saved.menu(opts); return picker end
			require("opencode.ui.palette.queue").show({ view = first })
			if suspended then chat.create_layout(seed("layout-b"))
			else chat.create_split(first, seed("layout-b"), "vertical") end
			settle()
			local focused = vim.api.nvim_get_current_win()
			reply(nil, { { id = "queued-a", sessionID = "layout-a", type = "user", delivery = "queue",
				payload = { text = "Prompt for A" }, time = { created = 1 } } }); settle()
			assert.equals("queued", require("opencode.session.pending").get("layout-a", "queued-a").status)
			if suspended then
				assert.is_nil(picker)
				assert.equals(focused, vim.api.nvim_get_current_win())
			else
				assert.is_not_nil(picker)
				assert.equals(first.winid, vim.api.nvim_win_get_config(picker.frame.winid).win)
			end
		end)
	end

	for _, action in ipairs({ "new", "split" }) do
		for _, destination in ipairs({ "editor", "sibling", "composer", "review note", "diff note" }) do
			it("preserves " .. destination .. " focus when a delayed " .. action .. " session arrives", function()
				local sibling = chat.create_split(first, seed("layout-b"), "vertical")
				chat.focus_view(first)
				if action == "new" then api.new_session() else api.split("vertical") end
				if destination == "editor" then vim.api.nvim_set_current_tabpage(editor)
				else chat.focus_view(sibling) end
				local input, submitted = require("opencode.ui.input")
				local note = destination == "review note" or destination == "diff note"
				local composing = destination == "composer" or note
				local note_parent, note_tab
				if destination == "composer" then
					chat.focus_input()
					input.set_pending_text("Unsaved prompt")
					draft_ids[#draft_ids + 1] = sibling.session_id
				elseif note then
					if destination == "diff note" then
						vim.cmd("tabnew")
						note_parent, note_tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
						files[#files + 1] = vim.api.nvim_get_current_buf()
					end
					input.show({ view = sibling, winid = note_parent, text = "Unsaved prompt", persist_pending = false, add_history = false,
						on_send = function(text) submitted = text end })
				end
				if composing then vim.api.nvim_win_set_cursor(0, { 1, 4 }) end
				local focused = vim.api.nvim_get_current_win()
				creates[1].callback(nil, { id = "layout-delayed", title = "Delayed", directory = "/tmp/layout-project" })
				settle()
				if destination == "editor" then assert.equals(focused, vim.api.nvim_get_current_win())
				elseif composing then
					assert.is_true(input.is_visible())
					assert.equals(sibling, input.owner_view())
					assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
					assert.equals("Unsaved prompt", input.get_pending_text())
					assert.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
					if note_parent then
						assert.equals(note_tab, vim.api.nvim_get_current_tabpage())
						assert.equals(note_parent, require("tests.helpers.input_state")().parent_winid)
					end
					if note then
						vim.fn.maparg("<C-g>", "n", false, true).callback()
						assert.equals("Unsaved prompt", submitted)
						assert.equals("", require("opencode.ui.input.history").get_pending(sibling.session_id))
					end
				else assert.equals(sibling.winid, vim.api.nvim_get_current_win()) end
				assert.equals(original_layout, workspace.current().id)
				assert.is_truthy(views.for_session("layout-delayed"))
			end)
		end
	end

	it("opens the forked layout composer with the selected prompt and attachments", function()
		local text = "Review [File 1]"
		sync.handle_session_messages("layout-a", require("opencode.protocol.messages").page("layout-a", {
			{ id = "fork-turn", type = "user", text = text, time = { created = 1 },
				files = { { uri = "file:///tmp/context.txt", name = "context.txt", mime = "text/plain" } } },
		}))
		client.fork_session = function(id, opts, callback)
			assert.equals("layout-a", id)
			assert.equals("fork-turn", opts.before)
			callback(nil, { id = "layout-fork", title = "Fork" })
		end
		draft_ids[#draft_ids + 1] = "layout-fork"
		assert.is_true(require("opencode.ui.timeline").run("fork", "layout-a", "fork-turn"))
		settle()
		local input = require("opencode.ui.input")
		assert.equals("layout-fork", views.session(chat.get_view()).id)
		assert.equals("layout-a", views.session(first).id)
		assert.is_true(input.is_visible())
		assert.equals(chat.get_view(), input.owner_view())
		assert.equals(text, input.get_pending_text())
		local part = input.get_pending_parts()[1]
		assert.equals("file:///tmp/context.txt", part.uri or part.url)
	end)

	for _, suspended in ipairs({ false, true }) do
		it("closes deleted child panes across layouts (suspended=" .. tostring(suspended) .. ")", function()
			local child_session = seed("layout-child")
			sync.record_task_child_session("layout-a", "layout-a-message", "a-task", child_session.id)
			local child = chat.create_split(first, child_session, "vertical")
			if suspended then chat.create_layout(seed("layout-survivor"))
			else chat.create_split(child, seed("layout-survivor"), "vertical") end
			local survivor = chat.get_view()
			assert.is_true(sessions.handle_deleted("layout-a"))
			settle()
			assert.is_nil(views.for_session("layout-a"))
			assert.is_nil(views.for_session("layout-child"))
			assert.equals(survivor, chat.get_view())
			assert.equals("layout-survivor", state.get_session().id)
			assert.is_nil(state.get_session_record("layout-child"))
			assert.equals(1, #workspace.list())
		end)
	end

	it("closes multiwindow popups during N, layout switching and closing", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		local buffers = { [first.bufnr] = true, [second.bufnr] = true }
		local expected = geometry(tab, buffers)
		for _, key in ipairs({ "N", "gt", "x" }) do
			local popup = require("opencode.ui.popup").new({
				frame = { relative = "editor", size = { width = 20, height = 8 }, enter = false },
				content = { size = { width = 18, height = 6 }, enter = false },
				focus_restore = false,
			}):mount()
			local frame, content = popup.frame.winid, popup.content.winid
			vim.fn.maparg(key, "n", false, true).callback()
			if key == "N" then
				assert.equals(1, #creates)
				creates[1].callback(nil, seed("layout-c"))
			end
			settle()
			assert.is_true(popup.closed)
			assert.is_false(vim.api.nvim_win_is_valid(frame))
			assert.is_false(vim.api.nvim_win_is_valid(content))
			assert.is_false(views.workspace.switching)
			if key == "gt" then
				assert.equals(original_layout, workspace.current().id)
				assert.same(expected, geometry(tab, buffers))
				shared_bar(tab, { first, second })
			else
				assert.equals("layout-c", views.session(chat.get_view()).id)
				shared_bar(tab, { chat.get_view() })
			end
		end
		assert.equals(1, #workspace.list())
	end)

	it("adds a delayed split to its original hidden layout without stealing focus", function()
		assert.is_true(api.split("vertical"))
		chat.create_layout(seed("layout-c")); settle()
		local selected = workspace.current().id
		creates[1].callback(nil, { id = "layout-delayed-split", title = "Delayed split" }); settle()
		assert.equals(selected, workspace.current().id)
		assert.equals(2, #workspace.list())
		workspace.select(original_layout); settle()
		shared_bar(tab, { first, views.for_session("layout-delayed-split") })
	end)

	it("renders updates received while a layout is hidden when it returns", function()
		chat.create_layout(seed("layout-b")); settle()
		local part = { id = "layout-a-text", messageID = "layout-a-message", sessionID = "layout-a",
			type = "text", text = "Updated while this layout was hidden" }
		sync.handle_part_updated(part)
		require("opencode.events").emit("chat_stream_part_updated", { part = part }); settle()
		workspace.select(original_layout); settle()
		local text = table.concat(vim.api.nvim_buf_get_lines(first.bufnr, 0, -1, false), "\n")
		assert.is_truthy(text:find(part.text, 1, true))
	end)

	it("keeps layout switching usable when the shared tabbar is disabled", function()
		local config = state.get_config()
		config.chat.session_tabs.enabled = false
		state.set_config(config); settle()
		assert.is_nil(require("opencode.ui.chat.workspace_bar").winid())
		chat.create_layout(seed("layout-b")); settle()
		assert.equals(1, #normal_windows(tab))
		workspace.select(original_layout); settle()
		assert.equals("layout-a", views.session(chat.get_view()).id)
		assert.equals(1, #normal_windows(tab))
	end)

	it("uses the configured navigation keys in the shared tabbar", function()
		local config = state.get_config()
		config.chat.keymaps.next_session = "]t"
		state.set_config(config); settle()
		chat.create_layout(seed("layout-b")); settle()
		vim.api.nvim_set_current_win(require("opencode.ui.chat.workspace_bar").winid())
		assert.equals("", vim.fn.maparg("gt", "n"))
		press("]t")
		assert.equals(original_layout, workspace.current().id)
	end)

	it("moves a whole layout with the existing tab reorder action", function()
		chat.create_split(first, seed("layout-b"), "vertical")
		chat.create_layout(seed("layout-c")); settle()
		local selected = workspace.current().id
		assert.is_true(require("opencode.actions").reorder_session_tab(-1))
		assert.equals(selected, workspace.list()[1].id)
		assert.equals(original_layout, workspace.list()[2].id)
		press("gt")
		assert.equals(original_layout, workspace.current().id)
		shared_bar(tab, { first, views.for_session("layout-b") })
	end)

	it("returns to an existing layout when the current layout closes", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		local buffers = { [first.bufnr] = true, [second.bufnr] = true }
		local expected = geometry(tab, buffers)
		chat.create_layout(seed("layout-c")); settle()
		local native_tabs = #vim.api.nvim_list_tabpages()
		press("x")
		assert.equals(1, #workspace.list())
		assert.equals(original_layout, workspace.current().id)
		assert.equals(tab, vim.api.nvim_get_current_tabpage())
		assert.equals(native_tabs, #vim.api.nvim_list_tabpages())
		assert.same(expected, geometry(tab, buffers))
		assert.equals(second, chat.get_view())
		shared_bar(tab, { first, second })
	end)

	for _, case in ipairs({
		{ name = "middle layout", index = 3, expected = "layout-b" },
		{ name = "last layout", index = 4, expected = "layout-c" },
		{ name = "first layout", index = 1, expected = "layout-b" },
		{ name = "reordered layout from the tabbar", index = 4, expected = "layout-b", reorder = true },
	}) do
		it("selects the adjacent layout when x closes the " .. case.name, function()
			for _, id in ipairs({ "layout-b", "layout-c", "layout-d" }) do chat.create_layout(seed(id)); settle() end
			press(case.index .. "gt")
			if case.reorder then
				assert.is_true(require("opencode.actions").reorder_session_tab(-1))
				assert.equals("layout-d", workspace.list()[3].session_id)
				vim.api.nvim_set_current_win(require("opencode.ui.chat.workspace_bar").winid())
			end
			press("x")
			assert.equals(3, #workspace.list())
			assert.equals(case.expected, workspace.current().session_id)
			assert.equals(case.expected, views.session(chat.get_view()).id)
			shared_bar(tab, { chat.get_view() })
		end)
	end

	it("registers a fresh layout when reopening after q closed the last pane", function()
		press("q")
		chat.open(); settle()
		assert.equals(1, #workspace.list())
		assert.is_not_nil(workspace.current())
		assert.equals("layout-a", views.session(chat.get_view()).id)
		shared_bar(vim.api.nvim_get_current_tabpage(), { chat.get_view() })
	end)

	it("releases hidden layouts when their native OpenCode tab is closed", function()
		chat.create_layout(seed("layout-b")); settle()
		local second = chat.get_view()
		vim.cmd("tabclose!"); settle()
		assert.equals(editor, vim.api.nvim_get_current_tabpage())
		assert.equals(0, #workspace.list())
		assert.is_false(first.suspended == true)
		assert.is_false(second.visible)
		chat.open(); settle()
		assert.equals(1, #workspace.list())
		assert.is_not_nil(workspace.current())
	end)

	it("removes a deleted session from a suspended layout without leaving an empty pane", function()
		local second = chat.create_split(first, seed("layout-b"), "vertical")
		chat.create_layout(seed("layout-c")); settle()
		local active_layout, active_view = workspace.current().id, chat.get_view()
		assert.is_true(sessions.handle_deleted(second.session_id))
		settle()
		assert.equals(active_layout, workspace.current().id)
		assert.equals(active_view, chat.get_view())
		assert.is_false(views.valid(second))
		workspace.select(original_layout); settle()
		assert.equals("layout-a", views.session(chat.get_view()).id)
		shared_bar(tab, { first })
	end)

	it("keeps a modified file window when q closes its final chat pane", function()
		local file = vim.api.nvim_create_buf(true, false)
		files[#files + 1] = file
		vim.cmd("rightbelow split")
		local filewin = vim.api.nvim_get_current_win()
		vim.api.nvim_win_set_buf(filewin, file)
		vim.api.nvim_buf_set_lines(file, 0, -1, false, { "Keep this unsaved file" })
		settle()
		chat.focus_view(first); press("q")
		assert.is_true(vim.api.nvim_tabpage_is_valid(tab))
		assert.is_true(vim.api.nvim_win_is_valid(filewin))
		assert.equals(file, vim.api.nvim_win_get_buf(filewin))
		assert.is_true(vim.bo[file].modified)
		assert.same({ "Keep this unsaved file" }, vim.api.nvim_buf_get_lines(file, 0, -1, false))
		assert.equals(tab, views.workspace.tabpage, "the surviving file layout still belongs to its workspace")
		assert.equals(1, #workspace.list())
		chat.create_layout(seed("layout-file-neighbor")); settle()
		assert.equals(tab, vim.api.nvim_get_current_tabpage())
		workspace.select(original_layout); settle()
		assert.equals(file, vim.api.nvim_get_current_buf())
		assert.is_true(vim.bo[file].modified)
	end)
end)
