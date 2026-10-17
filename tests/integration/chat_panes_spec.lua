local app_state = require("opencode.state")
local sync = require("opencode.sync")
local events = require("opencode.events")
local chat = require("opencode.ui.chat")
local cs = require("opencode.ui.chat.state")
local coordinator = require("opencode.ui.chat.render_coordinator")

local function text(view)
	return table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
end

local function syntax_marks(view)
	local marks = {}
	for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(view.bufnr, cs.chat_hl_ns, 0, -1, { details = true })) do
		local details = mark[4]
		if details.hl_group and (details.hl_group:sub(1, 1) == "@" or details.hl_group:find("OpenCodeSyntax", 1, true)) then
			marks[#marks + 1] = { mark[2], mark[3], details.end_row, details.end_col, details.hl_group, details.priority }
		end
	end
	table.sort(marks, function(a, b) return vim.inspect(a) < vim.inspect(b) end)
	return marks
end

local function seed(id, content)
	app_state.upsert_session({ id = id, title = id })
	sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
	sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id,
		type = "text", text = content })
	return { id = id, title = id }
end

local function update(id, content, delta)
	sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id,
		type = "text", text = content })
	events.emit("sync_changed", { kind = "part", action = "updated", session_id = id,
		message_id = id .. "-message", part_id = id .. "-text", field = delta and "text", delta = delta })
end

local function wait_for(predicate, reason)
	assert.is_true(vim.wait(1000, predicate, 10), reason)
end

describe("independent chat panes", function()
	local original_tab, first, second, tabpage, original_get_messages

	before_each(function()
		vim.o.columns, vim.o.lines = 160, 48
		original_tab = vim.api.nvim_get_current_tabpage()
		require("opencode").setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab", session_tabs = { enabled = false } } })
		local client = require("opencode.client")
		original_get_messages = client.get_messages
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		sync.clear_all()
		app_state.set_session("pane-first", "pane-first")
		seed("pane-first", "First transcript")
		local session = seed("pane-second", "Second transcript")
		chat.open()
		first = chat.get_view()
		tabpage = first.tabpage
		second = chat.create_split(first, session, "vertical")
		assert.is_truthy(second, "split should create a second view")
		coordinator.setup(events)
		chat.for_view(first).do_render()
		chat.for_view(second).do_render()
	end)

	after_each(function()
		require("opencode.ui.input").close()
		for _, view in ipairs(cs.all()) do
			if view.tabpage == tabpage then chat.close_view(view) end
		end
		if vim.api.nvim_tabpage_is_valid(original_tab) then vim.api.nvim_set_current_tabpage(original_tab) end
		require("opencode.client").get_messages = original_get_messages
		sync.clear_all()
	end)

	it("uses independent normal windows and supports nested horizontal splits", function()
		assert.is_not.equals(original_tab, tabpage)
		assert.equals(tabpage, second.tabpage)
		assert.is_not.equals(first.bufnr, second.bufnr)
		assert.equals("", vim.api.nvim_win_get_config(first.winid).relative)
		assert.equals("", vim.api.nvim_win_get_config(second.winid).relative)
		assert.is_truthy(text(first):find("First transcript", 1, true))
		assert.is_nil(text(first):find("Second transcript", 1, true))
		assert.is_truthy(text(second):find("Second transcript", 1, true))
		local third = chat.create_split(second, seed("pane-third", "Third transcript"), "horizontal")
		chat.for_view(third).do_render()
		assert.equals(tabpage, third.tabpage)
		assert.equals(3, #vim.api.nvim_tabpage_list_wins(tabpage))
		assert.is_true(vim.api.nvim_win_get_height(first.winid) > vim.api.nvim_win_get_height(third.winid))
		assert.is_truthy(text(third):find("Third transcript", 1, true))
		assert.equals("pane-first", first.session_id)
		assert.equals("pane-second", second.session_id)
	end)

	it("keeps unfocused panes live and wraps each stream to its own width", function()
		assert.is_true(pcall(vim.treesitter.language.add, "lua"), "Lua parser required")
		vim.api.nvim_win_set_width(first.winid, 45)
		chat.focus_view(second)
		local focused = vim.api.nvim_get_current_win()
		local first_content = "FIRST-STREAM " .. string.rep("alpha beta gamma delta ", 8) .. "\n```lua\nlocal first = 1"
		local second_content = "SECOND-STREAM " .. string.rep("one two three four ", 8) .. "\n```lua\nlocal second = 2"
		update("pane-first", first_content)
		update("pane-second", second_content)
		wait_for(function()
			return text(first):find("FIRST-STREAM", 1, true) and text(second):find("SECOND-STREAM", 1, true)
		end, "both panes should receive their snapshots without a focus change")
		update("pane-first", first_content .. "\n-- FIRST-END", "\n-- FIRST-END")
		update("pane-second", second_content .. "\n-- SECOND-END", "\n-- SECOND-END")
		wait_for(function()
			return text(first):find("FIRST-END", 1, true) and text(second):find("SECOND-END", 1, true)
		end, "both panes should receive interleaved deltas")
		assert.equals(focused, vim.api.nvim_get_current_win())
		assert.is_nil(text(first):find("SECOND-STREAM", 1, true))
		assert.is_nil(text(second):find("FIRST-STREAM", 1, true))
		for _, view in ipairs({ first, second }) do
			local width = vim.api.nvim_win_get_width(view.winid)
			for _, line in ipairs(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false)) do
				assert.is_true(vim.fn.strdisplaywidth(line) <= width, "stream exceeded its owning pane width")
			end
			local streamed = text(view)
			local marks = syntax_marks(view)
			assert.is_true(#marks > 0, "each streaming code block should be highlighted")
			view.force_full_render = true
			chat.for_view(view).do_render()
			assert.equals(streamed, text(view), "incremental stream should match a full pane render")
			assert.same(marks, syntax_marks(view), "incremental highlights should match a full pane render")
		end
	end)

	it("wraps tool and interactive widgets to a narrow nondefault pane on every render path", function()
		local permissions = require("opencode.permission.state")
		local questions = require("opencode.question.state")
		local edits = require("opencode.edit.state")
		vim.api.nvim_win_set_width(second.winid, 42)
		vim.bo[first.bufnr].tabstop, vim.bo[second.bufnr].tabstop = 2, 8
		chat.focus_view(first)
		local long = string.rep("long\tcontent ", 10)
		local sid = second.session_id
		sync.handle_part_updated({ id = "pane-tool", messageID = sid .. "-message", sessionID = sid,
			type = "tool", tool = "bash", state = { status = "completed", input = { command = "echo " .. long }, output = long } })
		second.expanded_tools["pane-tool"] = true
		local permission = permissions.add_permission("pane-permission", sid, "bash", { tool_input = { command = long } })
		local question = questions.add_form({ id = "pane-question", sessionID = sid,
			fields = { { key = "choice", type = "string", title = long, options = { { label = long, value = "yes" } } } } })
		local edit = edits.add_edit("pane-edit", sid, { { filePath = "/tmp/pane-file.lua", before = "", after = long } }, { transport = "review_rpc", native_review = { status = "pending" } })
		edit.message = long
		local function check_width()
			local width = vim.api.nvim_win_get_width(second.winid)
			vim.api.nvim_win_call(second.winid, function()
				for _, line in ipairs(vim.api.nvim_buf_get_lines(second.bufnr, 0, -1, false)) do
					assert.is_true(vim.fn.strdisplaywidth(line) <= width, "widget exceeded owner width/tabstop: " .. line)
				end
			end)
		end
		chat.for_view(second).do_render()
		assert.is_not_nil(second.permissions["pane-permission"])
		assert.is_not_nil(second.questions["pane-question"])
		assert.is_not_nil(second.edits["pane-edit"])
		assert.is_not_nil(second.tools["pane-tool"])
		check_width()
		for _, status in ipairs({ "confirming", "answered", "rejected" }) do
			question.status = status
			question.answers = { { long } }
			cs.module(second, require("opencode.ui.chat.questions")).rerender_question("pane-question")
			check_width()
		end
		for _, status in ipairs({ "approved", "rejected" }) do
			permission.status = status
			cs.module(second, require("opencode.ui.chat.permissions")).rerender_permission("pane-permission")
			check_width()
		end
		edit.status = "sent"
		cs.module(second, require("opencode.ui.chat.edits")).rerender_edit("pane-edit")
		check_width()
		assert.equals(first.winid, vim.api.nvim_get_current_win())
		permissions.clear_all(); questions.clear_all(); edits.clear_all()
	end)

	it("routes permission and question choices through their owning pane after focus moves", function()
		local permissions, questions = require("opencode.permission.state"), require("opencode.question.state")
		local actions = require("opencode.actions")
		local old_permission, old_question = actions.respond_permission, actions.reply_to_question
		local permission_calls, question_calls = {}, {}
		actions.respond_permission = function(id, reply, _, done) permission_calls[#permission_calls + 1] = { id = id, reply = reply, done = done } end
		actions.reply_to_question = function(id, answers, done) question_calls[#question_calls + 1] = { id = id, answers = answers, done = done } end
		local ok, err = xpcall(function()
			for _, owner in ipairs({ first, second }) do
				permissions.add_permission(owner.session_id .. "-permission", owner.session_id, "bash")
				questions.add_form({ id = owner.session_id .. "-question", sessionID = owner.session_id,
					fields = { { key = "choice", type = "string", title = "Pick", options = { { label = "Yes", value = "yes" } } } } })
				chat.for_view(owner).do_render()
			end
			local permission_id, question_id = first.session_id .. "-permission", first.session_id .. "-question"
			local interactions = cs.module(first, require("opencode.ui.chat.interactions"))
			chat.focus_view(second)
			vim.api.nvim_win_set_cursor(first.winid, { first.permissions[permission_id].start_line + 1, 0 })
			interactions.handle_question_confirm()
			assert.equals(permission_id, permission_calls[1].id)
			assert.equals("once", permission_calls[1].reply)
			permission_calls[1].done(nil)
			vim.api.nvim_win_set_cursor(first.winid, { first.questions[question_id].start_line + 1, 0 })
			interactions.handle_question_number_select(1)
			assert.same({ choice = "yes" }, questions.get_answers(question_id))
			interactions.handle_question_confirm()
			assert.equals("confirming", questions.get_question(question_id).status)
			interactions.handle_question_confirm()
			assert.equals(question_id, question_calls[1].id)
			assert.same({ choice = "yes" }, question_calls[1].answers)
			question_calls[1].done(nil)
			wait_for(function() return questions.get_question(question_id).status == "answered" end, "owner answer should complete")
			assert.equals("approved", permissions.get_permission(permission_id).status)
			assert.equals("pending", permissions.get_permission(second.session_id .. "-permission").status)
			assert.equals("pending", questions.get_question(second.session_id .. "-question").status)
			assert.equals(second.winid, vim.api.nvim_get_current_win())
		end, debug.traceback)
		actions.respond_permission, actions.reply_to_question = old_permission, old_question
		permissions.clear_all(); questions.clear_all()
		assert.is_true(ok, err)
	end)

	it("keeps timeline callbacks attached to the pane that opened the picker", function()
		local timeline, menu, actions = require("opencode.ui.timeline"), require("opencode.ui.menu"), require("opencode.actions")
		local old_menu, old_load, old_fork = menu.open, actions.load_session_messages, actions.fork_session
		local loaded, options, target, finish
		menu.open = function(opts) options = opts; return { close = function() end } end
		actions.load_session_messages = function(sid, _, callback) target, loaded = sid, callback end
		actions.fork_session = function(sid, _, callback) target, finish = sid, callback end
		local ok, err = xpcall(function()
			sync.handle_message_updated({ id = "pane-user", sessionID = second.session_id, role = "user", text = "Pane draft", time = { created = 2 } })
			chat.focus_view(second)
			timeline.show_fork_picker({ view = second, session_id = second.session_id, generation = second.generation })
			assert.equals(second.session_id, target)
			loaded(nil)
			assert.is_not_nil(options)
			chat.focus_view(first)
			options.on_select(options.items[1])
			assert.equals(second.session_id, target)
			finish(nil, { id = "pane-fork", title = "Fork" })
			assert.equals("pane-first", first.session_id)
			assert.equals("pane-second", second.session_id)
			assert.equals(first.winid, vim.api.nvim_get_current_win())
			options = nil
			chat.focus_view(second)
			timeline.show({ view = second, generation = second.generation })
			chat.bind_session(second, seed("pane-reassigned", "Another transcript"))
			loaded(nil)
			assert.is_nil(options, "a late picker must not open after owner reassignment")
		end, debug.traceback)
		menu.open, actions.load_session_messages, actions.fork_session = old_menu, old_load, old_fork
		assert.is_true(ok, err)
	end)

	it("keeps inline diffs separate from chat panes and closes only the active diff pair", function()
		local edits = require("opencode.edit.state")
		local path = vim.fn.tempname()
		local owned_first = cs.module(first, require("opencode.ui.chat.edits"))
		local owned_second = cs.module(second, require("opencode.ui.chat.edits"))
		local actual
		local ok, err = xpcall(function()
			vim.fn.writefile({ "before" }, path)
			local config = vim.deepcopy(app_state.get_config()); config.server.shared_filesystem = true; app_state.set_config(config)
			local edit = edits.add_edit("pane-diff", second.session_id, { { fileID = "f", filePath = path, before = "before\n", after = "after\n" } },
				{ transport = "review_rpc", revision = 1, native_review = { status = "pending" } })
			local function marked(owner)
				local result = {}
				for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
					if owner.is_inline_diff_window(win) then result[#result + 1] = win end
				end
				return result
			end
			chat.focus_view(second)
			owned_second.open_inline_diff_split(edit.files[1], { edit_id = "pane-diff", file_index = 1 })
			assert.equals(2, #marked(owned_second))
			assert.equals(0, #marked(owned_first))
			actual = vim.fn.bufnr(path)
			assert.equals(first.bufnr, vim.api.nvim_win_get_buf(first.winid))
			assert.equals(second.bufnr, vim.api.nvim_win_get_buf(second.winid))
			owned_first.close_inline_diff_split()
			assert.equals(2, #marked(owned_second), "closing a sibling's diff must leave the active owner intact")
			chat.focus_view(first)
			owned_first.open_inline_diff_split(edit.files[1], { edit_id = "pane-diff", file_index = 1 })
			assert.equals(0, #marked(owned_second))
			assert.equals(2, #marked(owned_first))
			assert.equals(first.bufnr, vim.api.nvim_win_get_buf(first.winid))
			assert.equals(second.bufnr, vim.api.nvim_win_get_buf(second.winid))
		end, debug.traceback)
		if actual and vim.api.nvim_buf_is_valid(actual) then vim.bo[actual].modified = false end
		owned_first.close_inline_diff_split({ silent = true }); owned_second.close_inline_diff_split({ silent = true })
		if actual and vim.api.nvim_buf_is_valid(actual) then vim.api.nvim_buf_delete(actual, { force = true }) end
		vim.fn.delete(path); edits.clear_all()
		assert.is_true(ok, err)
	end)

	it("keeps a pane's command target when focus changes before its callback", function()
		local actions = require("opencode.actions")
		local abort, received = actions.abort
		actions.abort = function(opts) received = opts end
		local ok, failure = xpcall(function()
			local callback
			for _, map in ipairs(vim.api.nvim_buf_get_keymap(first.bufnr, "n")) do
				if map.desc == "Stop current generation" then callback = map.callback end
			end
			assert.equals("function", type(callback))
			chat.focus_view(second)
			callback()
			assert.equals("pane-first", received.session_id)
			assert.equals(first, received.view)
			assert.equals(second.winid, vim.api.nvim_get_current_win())
		end, debug.traceback)
		actions.abort = abort
		assert.is_true(ok, failure)
	end)

	it("keeps expansion and session reassignment local to their pane", function()
		first.expanded_tools["first-tool"] = true
		first.auto_scroll = true
		second.expanded_tools["second-tool"] = true
		second.auto_scroll = false
		local before = text(second)
		chat.bind_session(first, seed("pane-replacement", "Replacement transcript"))
		chat.for_view(first).do_render()
		assert.equals("pane-replacement", first.session_id)
		assert.equals("pane-second", second.session_id)
		assert.equals(before, text(second))
		assert.is_true(second.expanded_tools["second-tool"])
		assert.is_false(second.auto_scroll)
		assert.is_truthy(text(first):find("Replacement transcript", 1, true))
	end)

	it("ignores queued renders after their owning pane closes", function()
		local original_schedule, queued = vim.schedule, {}
		vim.schedule = function(callback) queued[#queued + 1] = callback end
		local ok, failure = xpcall(function()
			local sibling_buffer = second.bufnr
			local sibling_text = text(second)
			update("pane-first", "Closed owner update")
			chat.close_view(first)
			local count = 0
			while #queued > 0 do
				count = count + 1
				assert.is_true(count < 100, "queued work did not settle")
				table.remove(queued, 1)()
			end
			assert.is_true(vim.api.nvim_win_is_valid(second.winid))
			assert.equals(sibling_buffer, second.bufnr)
			assert.equals(sibling_text, text(second))
			assert.equals("pane-second", second.session_id)
		end, debug.traceback)
		vim.schedule = original_schedule
		assert.is_true(ok, failure)
	end)
end)
