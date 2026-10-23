local api = require("opencode")
local app, sync = require("opencode.state"), require("opencode.sync")
local sessions, actions = require("opencode.session"), require("opencode.actions")
local chat, cs = require("opencode.ui.chat"), require("opencode.ui.chat.state")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
local workspace, input = require("opencode.ui.chat.workspace"), require("opencode.ui.input")
local questions, permissions, edits = require("opencode.question.state"), require("opencode.permission.state"), require("opencode.edit.state")

local function settle() vim.wait(40, function() return false end, 5) end
local function press(keys)
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
	settle()
end
local function seed(id, parent)
	local info = { id = id, title = id, parentID = parent, location = { directory = vim.fn.getcwd() },
		agent = "explore", model = { providerID = "test", modelID = "model" } }
	sessions.remember(info, { touch = not parent })
	local lines = {}
	for i = 1, 40 do lines[i] = id .. " paragraph " .. i end
	sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
	sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id,
		type = "text", text = table.concat(lines, "\n\n") })
	return info
end

describe("tab navigation regressions", function()
	local editor, first, original_layout, saved, draft_ids
	local function replace(module, field, value)
		saved[#saved + 1] = { module, field, module[field] }
		module[field] = value
	end
	local function nav(view) return cs.module(view or first, require("opencode.ui.chat.nav")) end
	local function task(child_id)
		first.tasks.task = { tool_part = { id = "navigation-task", type = "tool", tool = "task", sessionID = "navigation-a",
			state = { input = {}, metadata = { sessionID = child_id } } } }
	end
	before_each(function()
		editor = vim.api.nvim_get_current_tabpage()
		app.reset(); sync.clear_all()
		require("opencode.session.pending").clear_all()
		require("opencode.session.lock").clear_all()
		questions.clear_all(); permissions.clear_all(); edits.clear_all()
		api.setup({ server = { auto_start = false }, lualine = { enabled = false },
			chat = { layout = "tab" } })
		saved, draft_ids = {}, {}
		replace(lifecycle, "ensure_connected", function(callback) callback() end)
		replace(client, "get_messages", function(_, _, callback) callback(nil, {}) end)
		replace(client, "get_session_statuses", function(callback) callback(nil, {}) end)
		replace(client, "get_session", function(id, callback) callback(nil, app.get_session_record(id)) end)
		replace(client, "get_location", function(directory, callback) callback(nil, { directory = directory }) end)
		replace(vim, "notify", function() end)
		seed("navigation-a")
		sessions.set_active("navigation-a", "navigation-a")
		cs.state.session_bound = false
		chat.open(); settle()
		first, original_layout = chat.get_view(), workspace.current().id
	end)
	after_each(function()
		input.close()
		require("opencode.ui.native_diff").close(); settle(); input.close()
		questions.clear_all(); permissions.clear_all(); edits.clear_all()
		for _ = 1, 10 do
			if #workspace.list() == 0 then break end
			workspace.close_current(); settle()
		end
		for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
			if tab ~= editor then vim.api.nvim_set_current_tabpage(tab); vim.cmd("tabclose!") end
		end
		settle()
		for _, id in ipairs(draft_ids) do require("opencode.ui.input.history").clear_session(id) end
		for index = #saved, 1, -1 do local item = saved[index]; item[1][item[2]] = item[3] end
		if vim.api.nvim_tabpage_is_valid(editor) then vim.api.nvim_set_current_tabpage(editor) end
		sync.clear_all()
	end)

	it("keeps native motion counts separate from later gt", function()
		chat.create_layout(seed("navigation-b")); settle()
		local next_layout = workspace.current().id
		workspace.select(original_layout); settle()
		press("5G")
		assert.equals(5, vim.api.nvim_win_get_cursor(first.winid)[1])
		for row, line in ipairs(vim.api.nvim_buf_get_lines(first.bufnr, 0, -1, false)) do
			if #line > 5 then vim.api.nvim_win_set_cursor(first.winid, { row, 0 }); break end
		end
		press("2l")
		assert.equals(2, vim.api.nvim_win_get_cursor(first.winid)[2])
		local row = vim.api.nvim_win_get_cursor(first.winid)[1]
		press("2j")
		assert.equals(row + 2, vim.api.nvim_win_get_cursor(first.winid)[1])
		press("2k")
		assert.equals(row, vim.api.nvim_win_get_cursor(first.winid)[1])
		press("gt")
		assert.equals(next_layout, workspace.current().id)
	end)

	it("cancels native counts on Escape and keeps zero a first-column motion", function()
		chat.create_layout(seed("navigation-b")); settle()
		local next_layout = workspace.current().id
		workspace.select(original_layout); settle()
		press("3<Esc>gt")
		assert.equals(next_layout, workspace.current().id)
		workspace.select(original_layout); settle()
		press("5G4l0")
		assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(first.winid))
		press("gt")
		assert.equals(next_layout, workspace.current().id)
	end)

	it("does not cap native session counts at 99", function()
		local selected
		replace(cs.module(first, require("opencode.ui.chat.session_tabs")), "go_to_session_tab", function(index) selected = index end)
		press("120gt")
		assert.equals(120, selected)
	end)

	for _, kind in ipairs({ "question", "permission", "edit" }) do
		it("selects a " .. kind .. " option without expr-map textlock or a stale count", function()
			local id, map = "navigation-choice", kind == "question" and "questions" or kind == "permission" and "permissions" or "edits"
			if kind == "question" then
				questions.add_form({ id = id, sessionID = first.session_id, fields = { { key = "choice", type = "string", title = "Pick",
					options = { { label = "One", value = "one" }, { label = "Two", value = "two" } } } } })
			elseif kind == "permission" then permissions.add_permission(id, first.session_id, "bash")
			else edits.add_edit(id, first.session_id, {
				{ fileID = "one", filePath = "one.lua", before = "", after = "one" },
				{ fileID = "two", filePath = "two.lua", before = "", after = "two" },
			}, { transport = "review_rpc", native_review = { status = "pending" } }) end
			chat.for_view(first).do_render()
			vim.api.nvim_win_set_cursor(first.winid, { first[map][id].start_line + 1, 0 })
			press("2")
			if kind == "question" then assert.same({ choice = "two" }, questions.get_answers(id))
			elseif kind == "permission" then assert.equals(2, permissions.get_permission(id).selected_option)
			else assert.equals(2, edits.get_edit(id).selected_file) end
			local cycled, selected
			local tabs = cs.module(first, require("opencode.ui.chat.session_tabs"))
			replace(tabs, "cycle_session", function(direction) cycled = direction end)
			replace(tabs, "go_to_session_tab", function(index) selected = index end)
			press("gt")
			assert.equals(1, cycled)
			assert.is_nil(selected)
		end)
	end

	for _, route in ipairs({ "ID", "family" }) do
		it("returns with Backspace from a child opened by " .. route .. " with no stack", function()
			local info = seed("navigation-child", "navigation-a")
			if route == "ID" then actions.open_session(info.id, { view = first }); settle(); first = chat.get_view()
			else nav().open_family_session(info.id); settle() end
			assert.equals(info.id, cs.session(first).id)
			assert.same({}, first.session_stack)
			press("<BS>")
			assert.equals("navigation-a", cs.session(chat.get_view()).id)
			assert.same({}, first.session_stack)
		end)
	end

	for _, phase in ipairs({ "metadata", "history" }) do
		local function defer_family(target, historical_model)
			local response
			local messages = { { info = { id = "navigation-old-model", sessionID = target.id, role = "assistant",
				agent = target.agent, model = vim.deepcopy(historical_model or target.model) }, parts = {} } }
			replace(client, "get_messages", function(_, _, callback)
				if phase == "history" then response = function() callback(nil, messages) end
				else callback(nil, messages) end
			end)
			replace(client, "get_session", function(_, callback)
				if phase == "metadata" then response = function() callback(nil, target) end
				else callback(nil, target) end
			end)
			nav().open_family_session(target.id); settle()
			assert.is_function(response)
			return response
		end
		local function native(kind, data)
			require("opencode.events").emit("server_event", { id = "navigation-race-" .. kind,
				type = kind, created = 2000000000000, location = { directory = vim.fn.getcwd() }, data = data })
			settle()
		end

		for _, cached_parent in ipairs({ true, false }) do
			it("keeps a fork's ancestry and execution lock clear after late " .. phase .. " (cached parent=" .. tostring(cached_parent) .. ")", function()
				local target = seed("navigation-fork-race", cached_parent and "navigation-a" or nil)
				target.parentID = "navigation-a"
				local response = defer_family(target)
				native("session.forked", { sessionID = target.id, parentID = "navigation-a",
					boundary = { type = "after", messageID = "navigation-a-message" } })
				assert.is_nil(app.get_session_record(target.id).parentID)
				response(); settle()
				assert.equals(target.id, cs.session(first).id)
				assert.is_nil(app.get_session_record(target.id).parentID)
				assert.equals("navigation-a", app.get_session_record(target.id).fork.sessionID)
				assert.is_nil(require("opencode.session.lock").get(target.id))
				assert.is_true(app.is_runtime_session(target.id))
				assert.is_not.equals("child_lock", require("opencode.selectors").send_selection({ session_id = target.id }).sources.model)
			end)
		end

		for _, replay in ipairs({ false, true }) do
			it("keeps independent native ancestry during " .. phase .. " (fork replay=" .. tostring(replay) .. ")", function()
				local target = seed("navigation-independent-race", "navigation-a")
				target.parentID = "navigation-copy-source"
				sessions.set_message_cache(target.id, sync.get_messages(target.id))
				local fork_event = { sessionID = target.id, parentID = "navigation-copy-source" }
				if replay then native("session.forked", fork_event) end
				local before = app.get_session_record(target.id)
				local response = defer_family(target)
				native("session.forked", fork_event)
				if replay then assert.same(before, app.get_session_record(target.id)) end
				response(); settle()
				assert.equals("navigation-a", app.get_session_record(target.id).parentID)
				assert.equals("navigation-copy-source", app.get_session_record(target.id).fork.sessionID)
				assert.equals("navigation-copy-source", target.parentID, "navigation must not mutate the HTTP response")
				assert.is_not_nil(require("opencode.session.lock").get(target.id))
				assert.equals("child_lock", require("opencode.selectors").send_selection({ session_id = target.id }).sources.model)
			end)
		end

		it("uses the latest atomic model selection for same-session locks after late " .. phase, function()
			local target = seed("navigation-model-race", "navigation-a")
			target.model.variant = "stale-variant"
			sessions.remember(target, { touch = false })
			actions.set_view_session(first, target.id, target.title, { reason = "child_navigation", runtime = false }); settle()
			local response = defer_family(target)
			local selected = { providerID = "updated", id = "actual" }
			native("session.model.selected", { sessionID = target.id, model = selected })
			response(); settle()
			assert.equals(target.id, cs.session(first).id)
			assert.same(selected, app.get_session_record(target.id).model)
			local lock = require("opencode.session.lock").get(target.id)
			assert.same(selected, lock.child_session.model)
			assert.same({ providerID = selected.providerID, modelID = selected.id }, lock.model)
			assert.is_nil(lock.variant)
			local selection = require("opencode.selectors").send_selection({ session_id = target.id })
			assert.same(lock.model, selection.model)
			assert.is_nil(selection.variant)
			assert.is_nil(selection.blocked)
			assert.equals("child_lock", selection.sources.model)
		end)

		for _, event in ipairs({ "session.model.selected", "session.renamed" }) do
			it("keeps the native model through " .. event .. " and stale history during " .. phase, function()
				local target = seed("navigation-model-repeat", "navigation-a")
				local historical = { providerID = "historical", modelID = "older", variant = "stale" }
				native("session.model.selected", { sessionID = target.id, model = target.model })
				local revision = app.get_session_record(target.id)._model_selection_revision
				local response = defer_family(target, historical)
				if event == "session.model.selected" then native(event, { sessionID = target.id, model = target.model })
				else native(event, { sessionID = target.id, title = "New title only" }) end
				response(); settle()
				local lock = require("opencode.session.lock").get(target.id)
				local selection = require("opencode.selectors").send_selection({ session_id = target.id })
				local expected = target.model
				assert.same({ providerID = expected.providerID, modelID = expected.modelID }, lock.model)
				assert.same(lock.model, selection.model)
				assert.equals(expected.variant, lock.variant)
				assert.equals(expected.variant, selection.variant)
				assert.same(target.model, lock.child_session.model)
				assert.equals(revision + (event == "session.model.selected" and 1 or 0), app.get_session_record(target.id)._model_selection_revision)
			end)
		end
	end

	it("honors remapped option keys and configured actions on default digits", function()
		local closed = false
		first.config.keymaps = { select_2 = "<F3>", select_3 = false, close = "2" }
		cs.module(first, require("opencode.ui.chat.keymaps")).setup_buffer(first.bufnr, { close = function() closed = true end })
		questions.add_form({ id = "remapped-choice", sessionID = first.session_id, fields = { { key = "choice", type = "string", title = "Pick",
			options = { { label = "One", value = "one" }, { label = "Two", value = "two" } } } } })
		chat.for_view(first).do_render()
		vim.api.nvim_win_set_cursor(first.winid, { first.questions["remapped-choice"].start_line + 1, 0 })
		press("<F3>")
		assert.same({ choice = "two" }, questions.get_answers("remapped-choice"))
		press("2")
		assert.is_true(closed)
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(first.bufnr, "n")) do assert.is_not.equals("3", mapping.lhs) end
	end)

	it("keeps Backspace a no-op on a root without a parent or stack", function()
		local generation = first.generation
		vim.api.nvim_win_set_cursor(first.winid, { 1, 0 })
		press("<BS>")
		assert.equals("navigation-a", cs.session(first).id)
		assert.equals(generation, first.generation)
		assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(first.winid))
	end)

	for _, ancestry in ipairs({ "native", "legacy" }) do
		it("returns to the latest parent message with Backspace using " .. ancestry .. " ancestry", function()
			local child = seed("navigation-child", ancestry == "native" and "navigation-a" or nil)
			first.session_stack = { { id = "navigation-a", name = "navigation-a", runtime = true } }
			actions.set_view_session(first, child.id, child.title, { reason = "child_navigation", runtime = false }); settle()
			first.auto_scroll = false
			vim.api.nvim_win_set_cursor(first.winid, { 1, 0 })
			press("<BS>")
			assert.equals("navigation-a", cs.session(first).id)
			local last = vim.api.nvim_buf_line_count(first.bufnr)
			assert.is_true(last > vim.api.nvim_win_get_height(first.winid))
			assert.same({ last, 0 }, vim.api.nvim_win_get_cursor(first.winid))
			assert.equals(last, vim.api.nvim_win_call(first.winid, function() return vim.fn.line("w$") end))
			assert.is_false(first.auto_scroll)
		end)
	end

	it("does not apply a queued parent scroll after the pane is rebound", function()
		local child = seed("navigation-child")
		local other = seed("navigation-b")
		actions.set_view_session(first, child.id, child.title, { reason = "child_navigation", runtime = false }); settle()
		first.session_stack = { { id = "navigation-a", name = "navigation-a", runtime = true } }
		nav().leave_child_session()
		assert.equals("navigation-a", cs.session(first).id)
		actions.set_view_session(first, other.id, other.title)
		vim.api.nvim_win_set_cursor(first.winid, { 1, 0 })
		settle()
		assert.equals(other.id, cs.session(first).id)
		assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(first.winid))
	end)

	for _, route in ipairs({ "child", "family", "parent", "legacy parent" }) do
		it("preserves the source stack when " .. route .. " navigation focuses an existing owner", function()
			local target = seed("navigation-b", route == "child" and "navigation-a" or nil)
			local other = chat.create_layout(target); settle()
			vim.api.nvim_win_set_cursor(other.winid, { 1, 0 })
			workspace.select(original_layout); settle()
			if route ~= "child" then
				local child = seed("navigation-child", route == "legacy parent" and nil or "navigation-b")
				first.session_stack = { { id = "navigation-b", name = "navigation-b", runtime = true } }
				actions.set_view_session(first, child.id, child.title, { reason = "child_navigation", runtime = false }); settle()
			end
			local source, stack = cs.session(first).id, vim.deepcopy(first.session_stack)
			if route == "child" then task(target.id); nav().enter_child_session("task")
			elseif route == "family" then nav().open_family_session(target.id)
			else nav().leave_child_session() end
			settle()
			assert.equals(other, chat.get_view())
			assert.equals(source, cs.session(first).id)
			assert.same(stack, first.session_stack)
			if route == "parent" or route == "legacy parent" then
				assert.same({ vim.api.nvim_buf_line_count(other.bufnr), 0 }, vim.api.nvim_win_get_cursor(other.winid))
			end
		end)
	end

	for _, phase in ipairs({ "metadata", "location" }) do
		for _, destination in ipairs({ "layout", "editor", "composer" }) do
			it("preserves " .. destination .. " focus after a delayed catalog " .. phase .. " response", function()
				local response, completed
				local remote = seed("navigation-remote")
				if phase == "metadata" then replace(client, "get_session", function(_, callback) response = function() callback(nil, remote) end end)
				else replace(client, "get_location", function(directory, callback) response = function() callback(nil, { directory = directory }) end end) end
				actions.open_session(remote.id, { view = first }, function(err) assert.is_nil(err); completed = true end)
				local other = chat.create_layout(seed("navigation-b")); settle()
				local selected = workspace.current().id
				if destination == "editor" then vim.api.nvim_set_current_tabpage(editor)
				elseif destination == "composer" then
					chat.focus_input()
					input.set_pending_draft("Unsaved prompt", { { type = "file", uri = "file:///navigation-context.lua", name = "navigation-context.lua" } })
					draft_ids[#draft_ids + 1] = other.session_id
					vim.api.nvim_win_set_cursor(0, { 1, 4 })
				end
				local focused, parts = vim.api.nvim_get_current_win(), vim.deepcopy(input.get_pending_parts())
				response(); settle()
				assert.is_true(completed)
				assert.equals(selected, workspace.current().id)
				assert.is_not_nil(cs.for_session(remote.id), "a background result should still open")
				assert.equals("navigation-a", cs.session(first).id)
				if destination == "editor" then assert.equals(focused, vim.api.nvim_get_current_win())
				elseif destination == "composer" then
					assert.is_true(input.is_visible())
					assert.equals(other, input.owner_view())
					assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
					assert.equals("Unsaved prompt", input.get_pending_text())
					assert.same(parts, input.get_pending_parts())
					assert.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
				else assert.equals(other.winid, vim.api.nvim_get_current_win()) end
			end)
		end
	end

	for _, case in ipairs({
		{ route = "child", phase = "metadata" }, { route = "child", phase = "model history" },
		{ route = "family", phase = "model history" }, { route = "parent", phase = "metadata" },
	}) do
		it("keeps composer focus when a delayed " .. case.route .. " " .. case.phase .. " reply finds an existing owner", function()
			local child = seed("navigation-child", case.route ~= "parent" and "navigation-a" or nil)
			local owner = chat.create_layout(child); settle()
			workspace.select(original_layout); settle()
			if case.route == "parent" then
				local source = seed("navigation-source-child", child.id)
				actions.set_view_session(first, source.id, source.title, { reason = "child_navigation", runtime = false }); settle()
			end
			local source_id = cs.session(first).id
			first.session_stack = { { id = "navigation-ancestor", name = "Ancestor", runtime = false } }
			local stack, response = vim.deepcopy(first.session_stack)
			if case.phase == "metadata" then
				replace(client, "get_session", function(id, callback)
					assert.equals(child.id, id)
					response = function() callback(nil, child) end
				end)
			else
				replace(client, "get_messages", function(id, _, callback)
					assert.equals(child.id, id)
					response = function() callback(nil, { { info = { id = "late-model", sessionID = child.id,
						role = "assistant", agent = "explore", model = { providerID = "late", modelID = "resolved" } }, parts = {} } }) end
				end)
			end
			if case.route == "child" then task(child.id); nav().enter_child_session("task")
			elseif case.route == "family" then nav().open_family_session(child.id)
			else nav().leave_child_session() end
			settle()
			assert.is_function(response)
			local current = chat.create_layout(seed("navigation-current")); settle()
			local selected = workspace.current().id
			chat.focus_input()
			local parts = { { type = "file", uri = "file:///navigation-late.lua", name = "navigation-late.lua" } }
			local options = { delivery = "steer" }
			input.set_pending_draft("Keep this draft", parts, { options = options })
			draft_ids[#draft_ids + 1] = current.session_id
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 1, 4 })
			response(); settle()
			if case.route ~= "parent" then
				assert.is_not_nil(require("opencode.session.lock").get(child.id), "the late model should still resolve")
			end
			if case.phase == "model history" then
				assert.same(child.model, require("opencode.session.lock").get(child.id).model)
			end
			assert.equals(owner, cs.for_session(child.id))
			assert.equals(source_id, cs.session(first).id)
			assert.same(stack, first.session_stack)
			assert.equals(selected, workspace.current().id)
			assert.is_true(input.is_visible())
			assert.equals(current, input.owner_view())
			assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
			assert.equals("Keep this draft", input.get_pending_text())
			assert.same(parts, input.get_pending_parts())
			assert.same(options, input.get_pending_options())
			assert.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
		end)
	end

	it("restores a review note over a composer reopened synchronously during catalog focus restoration", function()
		local response, completed, submitted
		local remote = seed("navigation-reentrant-remote")
		replace(client, "get_session", function(_, callback) response = function() callback(nil, remote) end end)
		actions.open_session(remote.id, { view = first }, function(err) assert.is_nil(err); completed = true end)
		local other = chat.create_layout(seed("navigation-reentrant-other")); settle()
		local selected, history = workspace.current().id, require("opencode.ui.input.history")
		local draft, note = "Underlying normal draft", "Unsaved temporary review note\nSecond line"
		local draft_parts = { { type = "file", url = "file:///navigation-draft.lua", filename = "navigation-draft.lua" } }
		local note_parts = { { type = "file", url = "file:///navigation-note.lua", filename = "navigation-note.lua" } }
		local draft_options, note_options = { delivery = "steer" }, { tag = "review-note" }
		draft_ids[#draft_ids + 1] = other.session_id
		history.set_pending(draft, draft_parts, other.session_id)
		history.set_pending_options(draft_options, other.session_id)
		history.set_pending_cursor(4, other.session_id)
		input.show({ view = other, text = note, parts = note_parts, send_options = note_options,
			persist_pending = false, add_history = false, session_bound = true,
			on_send = function(text, parts, options) submitted = { text = text, parts = parts, options = options } end })
		vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 3 })
		local fired = false
		local listener = function(id)
			if id == other.session_id and not fired then
				fired = true
				input.show({ view = other })
			end
		end
		app.on("session.id", listener)
		local ok, err = xpcall(function() response(); settle() end, debug.traceback)
		app.off("session.id", listener)
		assert.is_true(ok, err)
		assert.is_true(completed)
		assert.is_true(fired)
		assert.equals(selected, workspace.current().id)
		assert.equals(other.session_id, app.get_session().id)
		assert.equals("navigation-a", cs.session(first).id)
		assert.is_not_nil(cs.for_session(remote.id))
		assert.is_true(input.is_visible(), "queued cleanup for the reentrant composer must not close the restored note")
		assert.equals(other, input.owner_view())
		assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
		assert.equals(note, input.get_pending_text())
		assert.same(note_parts, input.get_pending_parts())
		assert.same(note_options, input.get_pending_options())
		assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
		press("<C-g>")
		assert.same({ text = note, parts = note_parts,
			options = vim.tbl_extend("force", note_options, { delivery = "queue" }) }, submitted)
		assert.is_false(input.is_visible())
		assert.equals(draft, history.get_pending(other.session_id))
		assert.same(draft_parts, history.get_pending_parts(other.session_id))
		assert.same(draft_options, history.get_pending_options(other.session_id))
		assert.equals(4, history.get_pending_cursor(other.session_id))
		chat.focus_input(); settle()
		assert.equals(draft, input.get_pending_text())
		assert.same(draft_parts, input.get_pending_parts())
		assert.same(draft_options, input.get_pending_options())
		assert.same({ 1, 4 }, vim.api.nvim_win_get_cursor(0))
	end)

	for _, kind in ipairs({ "review", "native diff" }) do
		it("retains a real " .. kind .. " note through repeated show and reentrant catalog restoration", function()
			local config = vim.deepcopy(app.get_config())
			config.server.shared_filesystem = true; app.set_config(config)
			local remote, response, completed = seed("navigation-note-remote")
			replace(client, "get_location", function(directory, callback) response = function() callback(nil, { directory = directory }) end end)
			actions.open_session(remote.id, { view = first }, function(err) assert.is_nil(err); completed = true end)
			local other = chat.create_layout(seed("navigation-note-owner")); settle()
			local selected, history = workspace.current().id, require("opencode.ui.input.history")
			local draft = "Underlying normal draft\nKeep this line"
			local draft_parts = { { type = "file", url = "file:///navigation-note-draft.lua", filename = "navigation-note-draft.lua" } }
			local options = { delivery = "steer" }
			chat.focus_input()
			input.set_pending_draft(draft, draft_parts, { options = options })
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 4 }); input.close()
			draft_ids[#draft_ids + 1] = other.session_id
			local edit_id, path = "navigation-real-note", vim.fn.tempname() .. ".lua"
			edits.add_edit(edit_id, other.session_id, { { fileID = "file", filePath = path, type = "add", before = "", after = "proposal\n" } },
				{ transport = "review_rpc", native_review = { status = "pending" }, message = "Unsaved " .. kind .. " note\nSecond line" })
			chat.for_view(other).do_render()
			vim.api.nvim_win_set_cursor(other.winid, { other.edits[edit_id].start_line + 1, 0 })
			local diff, parent, note_tab = require("opencode.ui.native_diff")
			if kind == "native diff" then
				press("dt")
				assert.is_true(diff.is_active())
				parent, note_tab = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_tabpage()
			end
			press("m")
			assert.is_true(input.is_visible())
			replace(require("opencode.clipboard"), "read", function()
				return { mime = "image/png", data = "iVBORw0KGgo=", filename = "note.png" }
			end)
			assert.is_true(input.paste_clipboard())
			local note, parts, count = input.get_pending_text(), input.get_pending_parts(), #input.get_history()
			assert.equals(1, #parts)
			local buffer = vim.api.nvim_win_get_buf(input.get_winids()[1])
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 3 })
			input.show({ view = other, text = "Replacement", parts = {}, send_options = { tag = "replacement" },
				on_send = function() error("repeated show replaced the note submit callback") end,
				on_cancel = function() error("repeated show replaced the note cancel callback") end })
			assert.equals(buffer, vim.api.nvim_win_get_buf(input.get_winids()[1]))
			assert.equals(note, input.get_pending_text())
			assert.same(parts, input.get_pending_parts())
			assert.is_nil(input.get_pending_options())
			local fired = false
			local listener = function(id)
				if id == other.session_id and not fired then fired = true; input.show({ view = other }) end
			end
			app.on("session.id", listener)
			local ok, err = xpcall(function() response(); settle() end, debug.traceback)
			app.off("session.id", listener)
			assert.is_true(ok, err)
			assert.is_true(completed)
			assert.is_true(fired)
			assert.equals(selected, workspace.current().id)
			assert.is_not_nil(cs.for_session(remote.id))
			assert.is_true(input.is_visible(), "deferred BufLeave must not close the restored temporary note")
			assert.equals(other, input.owner_view())
			assert.equals(input.get_winids()[1], vim.api.nvim_get_current_win())
			assert.equals(note, input.get_pending_text())
			assert.same(parts, input.get_pending_parts())
			assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(0))
			if note_tab then assert.equals(note_tab, vim.api.nvim_get_current_tabpage()) end
			press(kind == "review" and "<C-g>" or "<C-c>")
			assert.equals(note, edits.get_edit(edit_id).message, "the real review callback must survive restoration")
			assert.is_false(input.is_visible())
			assert.equals(count, #input.get_history())
			assert.equals(draft, history.get_pending(other.session_id))
			assert.same(draft_parts, history.get_pending_parts(other.session_id))
			assert.same(options, history.get_pending_options(other.session_id))
			assert.equals(#"Underlying normal draft" + 1 + 4, history.get_pending_cursor(other.session_id))
			if parent then assert.equals(parent, vim.api.nvim_get_current_win()); diff.close(); settle() end
			chat.focus_input(); settle()
			assert.equals(draft, input.get_pending_text())
			assert.same(draft_parts, input.get_pending_parts())
			assert.same(options, input.get_pending_options())
			assert.same({ 2, 4 }, vim.api.nvim_win_get_cursor(input.get_winids()[1]))
		end)
	end

	for _, reopened in ipairs({ false, true }) do
		it("keeps a new source-owner composer after a catalog reply (reopened=" .. tostring(reopened) .. ")", function()
			local remote = { id = "navigation-unseen", title = "Unseen", location = { directory = vim.fn.getcwd() },
				model = { providerID = "remote", modelID = "model" } }
			local response, completed, previous
			replace(client, "get_session", function(_, callback) callback(nil, remote) end)
			replace(client, "get_location", function(directory, callback) response = function() callback(nil, { directory = directory }) end end)
			if reopened then chat.focus_input(); previous = input.get_winids()[1] end
			actions.open_session(remote.id, { view = first }, function(err) assert.is_nil(err); completed = true end)
			assert.is_function(response)
			if reopened then input.close() end
			chat.focus_input()
			local parts, options = { { type = "file", url = "file:///source-draft.lua", filename = "source-draft.lua" } }, { delivery = "steer" }
			input.set_pending_draft("Source draft\nSecond line", parts, { options = options })
			draft_ids[#draft_ids + 1] = first.session_id
			local window, generation = input.get_winids()[1], first.generation
			assert.is_not.equals(previous, window)
			vim.api.nvim_win_set_cursor(window, { 2, 3 })
			response(); settle()
			assert.is_true(completed)
			assert.is_true(input.is_visible())
			assert.equals(window, vim.api.nvim_get_current_win())
			assert.equals(first, input.owner_view())
			assert.equals("Source draft\nSecond line", input.get_pending_text())
			assert.same(parts, input.get_pending_parts())
			assert.same(options, input.get_pending_options())
			assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(window))
			assert.equals(generation, first.generation)
			assert.equals("navigation-a", cs.session(first).id)
			assert.is_nil(cs.for_session(remote.id))
			assert.same(remote.model, app.get_session_record(remote.id).model)
			assert.is_false(app.is_runtime_session(remote.id))
		end)
	end

	it("keeps a source-owner review note after a late rendered-task reply while loading the child model", function()
		local child, response = seed("navigation-note-child", "navigation-a")
		local part = { id = "navigation-real-task", type = "tool", tool = "task", sessionID = first.session_id,
			messageID = "navigation-a-message", state = { status = "completed", input = { subagent_type = "explore" }, metadata = { sessionID = child.id } } }
		sync.handle_part_updated(part)
		chat.for_view(first).do_render()
		local task_id
		for id, pos in pairs(first.tasks) do if pos.tool_part and pos.tool_part.id == part.id then task_id = id end end
		assert.is_not_nil(task_id)
		replace(client, "get_session", function(_, callback) response = function() callback(nil, child) end end)
		replace(client, "get_messages", function(id, _, callback)
			callback(nil, { { info = { id = "source-note-model", sessionID = id, role = "assistant", agent = "explore",
				model = { providerID = "loaded", modelID = "child" } }, parts = {} } })
		end)
		nav().enter_child_session(task_id)
		assert.is_function(response)
		chat.focus_input()
		local draft_parts = { { type = "file", url = "file:///review-draft.lua", filename = "review-draft.lua" } }
		input.set_pending_draft("Underlying draft", draft_parts, { options = { delivery = "steer" } })
		input.close(); draft_ids[#draft_ids + 1] = first.session_id
		local edit_id = "navigation-source-note"
		edits.add_edit(edit_id, first.session_id, { { fileID = "file", filePath = "source-note.lua", before = "", after = "proposal" } },
			{ transport = "review_rpc", native_review = { status = "pending" }, message = "saved note" })
		chat.for_view(first).do_render()
		vim.api.nvim_win_set_cursor(first.winid, { first.edits[edit_id].start_line + 1, 0 }); press("m")
		local window, generation, stack = input.get_winids()[1], first.generation, vim.deepcopy(first.session_stack)
		local note = "UNSENT source note\nSecond line"
		vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(window), 0, -1, false, vim.split(note, "\n", { plain = true }))
		vim.api.nvim_win_set_cursor(window, { 2, 3 })
		response(); settle()
		assert.is_true(input.is_visible())
		assert.equals(window, vim.api.nvim_get_current_win())
		assert.equals(note, input.get_pending_text())
		assert.same({ 2, 3 }, vim.api.nvim_win_get_cursor(window))
		assert.equals("saved note", edits.get_edit(edit_id).message)
		assert.equals(generation, first.generation)
		assert.equals("navigation-a", cs.session(first).id)
		assert.same(stack, first.session_stack)
		assert.is_not_nil(sync.get_message(child.id, "source-note-model"))
		assert.same(child.model, require("opencode.session.lock").get(child.id).model)
		press("<C-c>")
		assert.equals(note, edits.get_edit(edit_id).message)
		chat.focus_input(); settle()
		assert.equals("Underlying draft", input.get_pending_text())
		assert.same(draft_parts, input.get_pending_parts())
		assert.same({ delivery = "steer" }, input.get_pending_options())
	end)

	it("still honors foreground catalog navigation from the composer that started it", function()
		local remote = seed("navigation-foreground")
		chat.focus_input()
		input.set_pending_text("Retained foreground draft")
		draft_ids[#draft_ids + 1] = first.session_id
		actions.open_session(remote.id, { view = first }); settle()
		assert.equals(remote.id, cs.session(chat.get_view()).id)
		assert.equals(cs.for_session(remote.id).winid, vim.api.nvim_get_current_win())
		assert.is_false(input.is_visible())
		assert.equals("Retained foreground draft", require("opencode.ui.input.history").get_pending(first.session_id))
	end)

	for _, cause in ipairs({ "leaving", "WinClosed" }) do
		it("still cleans up a composer after legitimate " .. cause, function()
			chat.focus_input()
			input.set_pending_draft("Keep normal draft", {}, { options = { delivery = "steer" } })
			draft_ids[#draft_ids + 1] = first.session_id
			local window = input.get_winids()[1]
			if cause == "WinClosed" then vim.api.nvim_win_close(window, true)
			else vim.api.nvim_set_current_win(first.winid) end
			settle()
			assert.is_false(input.is_visible())
			local history = require("opencode.ui.input.history")
			assert.equals("Keep normal draft", history.get_pending(first.session_id))
			assert.same({ delivery = "steer" }, history.get_pending_options(first.session_id))
		end)
	end

	it("drops a catalog response after its owning view is rebound", function()
		local response, completed
		replace(client, "get_location", function(_, callback) response = callback end)
		local remote = seed("navigation-remote")
		actions.open_session(remote.id, { view = first }, function() completed = true end)
		local replacement = seed("navigation-replacement")
		actions.set_view_session(first, replacement.id, replacement.title)
		response(nil, { directory = remote.location.directory }); settle()
		assert.is_nil(completed)
		assert.is_nil(cs.for_session(remote.id))
		assert.equals(replacement.id, cs.session(first).id)
	end)

	for _, delayed in ipairs({ false, true }) do
		it("focuses an existing catalog owner only for a foreground choice (delayed=" .. tostring(delayed) .. ")", function()
			local target = chat.create_layout(seed("navigation-b")); settle()
			workspace.select(original_layout); settle()
			local response
			if delayed then replace(client, "get_session", function(id, callback) response = function() callback(nil, app.get_session_record(id)) end end) end
			actions.open_session(target.session_id, { view = first })
			local selected
			if delayed then
				selected = chat.create_layout(seed("navigation-c")); settle()
				response()
			else selected = target end
			settle()
			assert.equals(selected, chat.get_view())
			assert.equals("navigation-a", cs.session(first).id)
			assert.equals(delayed and 3 or 2, #workspace.list())
		end)
	end
end)

describe("native count timeout", function()
	local editor
	after_each(function() if editor then editor.close(); editor = nil end end)
	it("keeps a count while typing pauses beyond timeoutlen", function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			vim.o.timeoutlen = 20
			local view = require('opencode.ui.chat.state').state
			view.bufnr, view.winid, view.visible = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), true
			require('opencode.ui.chat.keymaps').setup_buffer(view.bufnr)
			require('opencode.ui.chat.session_tabs').go_to_session_tab = function(count) _G.selected = count end
		]])
		editor.request("nvim_input", { "12" })
		vim.wait(80, function() return false end, 5)
		editor.request("nvim_input", { "gt" })
		assert.is_true(vim.wait(500, function() return editor.lua("return _G.selected") == 12 end, 5))
	end)
end)

describe("real input composer reentry", function()
	local editor
	before_each(function()
		editor = require("tests.helpers.embedded_editor").new()
		editor.lua([[
			vim.o.lines, vim.o.columns = 48, 140
			_G.input, _G.chat = require("opencode.ui.input"), require("opencode.ui.chat")
			_G.edits, _G.diff = require("opencode.edit.state"), require("opencode.ui.native_diff")
			_G.history = require("opencode.ui.input.history")
			require("opencode").setup({ server = { auto_start = false, shared_filesystem = true }, lualine = { enabled = false },
				chat = { layout = "tab" } })
			require("opencode.lifecycle").ensure_connected = function(callback) callback() end
			require("opencode.client").get_messages = function(_, _, callback) callback(nil, {}) end
			require("opencode.client").get_session_statuses = function(callback) callback(nil, {}) end
			require("opencode.session").set_active("reentry-source", "Source")
			chat.open()
			_G.view = chat.get_view()
			chat.focus_input()
			input.set_pending_draft("Normal draft\nSecond line", { { type = "file", url = "file:///reentry.lua", filename = "reentry.lua" } },
				{ options = { delivery = "steer" } })
			vim.api.nvim_win_set_cursor(input.get_winids()[1], { 2, 4 }); input.close()
			edits.add_edit("reentry-note", view.session_id, { { fileID = "file", filePath = vim.fn.tempname() .. ".lua",
				type = "add", before = "", after = "proposal\n" } },
				{ transport = "review_rpc", native_review = { status = "pending" }, message = "saved note" })
			chat.for_view(view).do_render()
			vim.api.nvim_win_set_cursor(view.winid, { view.edits["reentry-note"].start_line + 1, 0 })
			_G.press = function(keys)
				vim.cmd("stopinsert")
				vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false)
				vim.wait(40, function() return false end, 5)
			end
		]])
	end)
	after_each(function() if editor then editor.close(); editor = nil end end)

	it("keeps an unsent review note after native window return and mapped i", function()
		editor.lua([[
			press("m")
			_G.note_window = input.get_winids()[1]
			vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(note_window), 0, -1, false, { "UNSENT review note", "Second line" })
			vim.api.nvim_win_set_cursor(note_window, { 2, 3 })
			vim.cmd("stopinsert")
		]])
		assert.equals("n", editor.lua("return vim.api.nvim_get_mode().mode"))
		editor.request("nvim_input", { "<C-w>pi" })
		vim.wait(120, function() return false end, 5)
		editor.lua([[
			assert(input.is_visible() and input.owner_view() == view)
			assert(vim.api.nvim_get_current_win() == note_window)
			assert(input.get_pending_text() == "UNSENT review note\nSecond line")
			assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(note_window)))
			press("<C-c>")
			assert(edits.get_edit("reentry-note").message == "UNSENT review note\nSecond line")
			assert(history.get_pending(view.session_id) == "Normal draft\nSecond line")
			assert(history.get_pending_parts(view.session_id)[1].url == "file:///reentry.lua")
			assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(view.session_id)))
		]])
	end)

	it("keeps the normal composer open after real native diff qi input", function()
		editor.lua('press("dt"); assert(diff.is_active()); press("m"); press("<C-c>")')
		editor.request("nvim_input", { "qi" })
		vim.wait(120, function() return false end, 5)
		editor.lua([[
			assert(not diff.is_active())
			assert(input.is_visible() and input.owner_view() == view)
			assert(vim.api.nvim_get_current_win() == input.get_winids()[1])
			assert(input.get_pending_text() == "Normal draft\nSecond line")
			assert(input.get_pending_parts()[1].url == "file:///reentry.lua")
			assert(vim.deep_equal({ delivery = "steer" }, input.get_pending_options()))
			assert(vim.deep_equal({ 2, 4 }, vim.api.nvim_win_get_cursor(input.get_winids()[1])))
		]])
	end)

	for _, route in ipairs({ "new", "split", "clear" }) do
		it("keeps a source review note when a delayed " .. route .. " creation arrives", function()
			editor.lua([[
				local route, api, cs = ..., require("opencode"), require("opencode.ui.chat.state")
				local app, sync = require("opencode.state"), require("opencode.sync")
				local created = { id = "creation-late", title = "Created", location = { directory = vim.fn.getcwd() },
					model = { providerID = "created", modelID = "model" } }
				local release
				require("opencode.client").create_session = function(_, callback) release = function() callback(nil, created) end end
				local source, generation, count = view.session_id, view.generation, #cs.all()
				local layouts = #require("opencode.ui.chat.workspace").list()
				sync.handle_message_updated({ id = "creation-source-message", sessionID = source, role = "assistant" })
				if route == "split" then assert(api.split("vertical", { view = view }))
				elseif route == "clear" then api.clear({ view = view, silent = true })
				else api.new_session({ view = view, silent = true }) end
				assert(release)
				press("m")
				local window = input.get_winids()[1]
				vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(window), 0, -1, false, { "UNSENT creation note", "Second line" })
				vim.api.nvim_win_set_cursor(window, { 2, 3 })
				release(); vim.wait(60, function() return false end, 5)
				assert(input.is_visible() and input.owner_view() == view and vim.api.nvim_get_current_win() == window)
				assert(input.get_pending_text() == "UNSENT creation note\nSecond line")
				assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(window)))
				assert(cs.session(view).id == source and view.generation == generation and app.is_runtime_session(source))
				assert(#cs.all() == count and #require("opencode.ui.chat.workspace").list() == layouts)
				assert(cs.for_session(created.id) == nil and vim.deep_equal(created.model, app.get_session_record(created.id).model))
				assert(sync.get_message(source, "creation-source-message"))
				press("<C-c>")
				assert(edits.get_edit("reentry-note").message == "UNSENT creation note\nSecond line")
				assert(history.get_pending(source) == "Normal draft\nSecond line")
				assert(history.get_pending_parts(source)[1].url == "file:///reentry.lua")
				assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(source)))
			]], { route })
		end)

		it("still activates immediate foreground " .. route .. " creation from its original composer", function()
			editor.lua([[
				local route, api, cs = ..., require("opencode"), require("opencode.ui.chat.state")
				local source = view.session_id
				chat.focus_input()
				require("opencode.client").create_session = function(_, callback)
					callback(nil, { id = "creation-immediate", title = "Created", location = { directory = vim.fn.getcwd() } })
				end
				if route == "split" then assert(api.split("vertical", { view = view }))
				elseif route == "clear" then api.clear({ view = view, silent = true })
				else api.new_session({ view = view, silent = true }) end
				vim.wait(60, function() return false end, 5)
				local target = cs.for_session("creation-immediate")
				assert(target and chat.get_view() == target and vim.api.nvim_get_current_win() == target.winid)
				assert(not input.is_visible())
				assert(history.get_pending(source) == (route == "clear" and "" or "Normal draft\nSecond line"))
				if route ~= "clear" then assert(cs.session(view).id == source) end
			]], { route })
		end)
	end
end)

describe("legacy new-session composer focus", function()
	local editor
	after_each(function() if editor then editor.close(); editor = nil end end)
	for _, delayed in ipairs({ false, true }) do
		it("handles the unbound direct activation branch (delayed=" .. tostring(delayed) .. ")", function()
			editor = require("tests.helpers.embedded_editor").new()
			editor.lua([[
				local delayed = ...
				vim.o.lines, vim.o.columns = 48, 160
				local api, chat, input = require("opencode"), require("opencode.ui.chat"), require("opencode.ui.input")
				local app, sessions, client = require("opencode.state"), require("opencode.session"), require("opencode.client")
				api.setup({ server = { auto_start = false }, lualine = { enabled = false }, chat = { layout = "vertical" } })
				require("opencode.lifecycle").ensure_connected = function(callback) callback() end
				client.get_messages = function(_, _, callback) callback(nil, {}) end
				client.get_session_statuses = function(callback) callback(nil, {}) end
				sessions.set_active("legacy-source", "Source"); chat.open()
				local view, history = chat.get_view(), require("opencode.ui.input.history")
				assert(not view.session_bound)
				chat.focus_input(); input.set_pending_draft("Legacy draft", {}, { options = { delivery = "steer" } })
				if delayed then input.close() end
				local release
				client.create_session = function(_, callback)
					release = function() callback(nil, { id = "legacy-created", title = "Created" }) end
					if not delayed then release() end
				end
				local generation = view.generation
				api.new_session({ silent = true })
				if delayed then chat.focus_input() end
				local window = input.get_winids()[1]
				if delayed then release() end
				vim.wait(60, function() return false end, 5)
				assert(app.get_session_record("legacy-created"))
				assert(history.get_pending("legacy-source") == "Legacy draft")
				assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options("legacy-source")))
				if delayed then
					assert(app.get_session().id == "legacy-source" and view.generation == generation)
					assert(input.is_visible() and vim.api.nvim_get_current_win() == window and input.get_pending_text() == "Legacy draft")
				else assert(app.get_session().id == "legacy-created" and input.is_visible() and input.get_pending_text() == "") end
			]], { delayed })
		end)
	end
end)

describe("async navigation callers and source review notes", function()
	local editor
	after_each(function() if editor then editor.close(); editor = nil end end)
	for _, route in ipairs({ "reopen", "legacy catalog", "timeline fork", "timeline revert", "timeline picker" }) do
		for _, delayed in ipairs({ false, true }) do
			it(route .. " preserves foreground behavior and a later note (delayed=" .. tostring(delayed) .. ")", function()
				editor = require("tests.helpers.embedded_editor").new()
				editor.lua([[
					local route, delayed = ...
					vim.o.lines, vim.o.columns = 55, 160
					local api, app, sessions = require("opencode"), require("opencode.state"), require("opencode.session")
					local chat, cs, input = require("opencode.ui.chat"), require("opencode.ui.chat.state"), require("opencode.ui.input")
					local client, edits, history = require("opencode.client"), require("opencode.edit.state"), require("opencode.ui.input.history")
					local sync, projection, timeline = require("opencode.sync"), require("opencode.protocol.messages"), require("opencode.ui.timeline")
					local errors = {}
					vim.notify = function(message, level) if level == vim.log.levels.ERROR then errors[#errors + 1] = tostring(message) end end
					api.setup({ server = { auto_start = false }, lualine = { enabled = false },
						chat = { layout = route == "legacy catalog" and "vertical" or "tab" },
						input = { history_file = vim.fn.tempname() .. "-history.json" } })
					require("opencode.lifecycle").ensure_connected = function(callback) callback() end
					client.get_messages = function(_, _, callback) callback(nil, {}) end
					client.get_session_statuses = function(callback) callback(nil, {}) end
					local source = { id = "caller-source", title = "Source", location = { directory = vim.fn.getcwd() } }
					local target = { id = "caller-target", title = "Fresh metadata", location = source.location,
						model = { providerID = "caller", modelID = "model" } }
					sessions.remember(source); sessions.set_active(source.id, source.title); chat.open()
					local view = chat.get_view()
					local messages = projection.page(source.id, { { id = "caller-turn", type = "user", text = "Historical prompt", time = { created = 1 },
						files = { { uri = "file:///historical.lua", name = "historical.lua", mime = "text/plain" } } } })
					sync.handle_session_messages(source.id, messages)
					client.get_messages = function(id, _, callback) callback(nil, id == source.id and messages or {}) end
					chat.focus_input()
					input.set_pending_draft("Normal draft\nSecond line", { { type = "file", url = "file:///normal.lua", filename = "normal.lua" } },
						{ options = { delivery = "steer" } }); input.close()
					edits.add_edit("caller-note", source.id, { { fileID = "f", filePath = vim.fn.tempname() .. ".lua", type = "add", before = "", after = "proposal\n" } },
						{ transport = "review_rpc", native_review = { status = "pending" }, message = "saved note" })
					chat.for_view(view).do_render()
					local function settle() vim.wait(60, function() return false end, 5); assert(#errors == 0, table.concat(errors, "\n")) end
					local function press(keys)
						vim.cmd("stopinsert"); vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "xt", false); settle()
					end
					local release
					local function hold(callback, value)
						release = function() callback(nil, value) end
						if not delayed then release() end
					end
					if route == "reopen" then
						sessions.remember({ id = target.id, title = "Old metadata", location = source.location })
						assert(sessions.close(target.id, { silent = true }))
						client.get_session = function(id, callback) assert(id == target.id); hold(callback, target) end
					elseif route == "legacy catalog" then
						assert(not view.session_bound)
						client.get_session = function(_, callback) callback(nil, target) end
						client.get_location = function(directory, callback) hold(callback, { directory = directory }) end
					elseif route == "timeline fork" then
						client.fork_session = function(id, opts, callback) assert(id == source.id and opts.before == "caller-turn"); hold(callback, target) end
					elseif route == "timeline revert" then
						client.abort_session = function(_, callback) callback(nil) end
						client.wait_session = function(_, callback) callback(nil) end
						client.revert_message = function(_, message, _, callback) hold(callback, { messageID = message }) end
					else client.get_messages = function(_, _, callback) hold(callback, messages) end end
					local generation, count, layouts = view.generation, #cs.all(), #require("opencode.ui.chat.workspace").list()
					if not delayed then chat.focus_input() end
					if route == "reopen" or route == "legacy catalog" then
						require("opencode.ui.palette").setup()
						assert(require("opencode.command_registry").run(route == "reopen" and "session.reopen" or "session.open",
							{ view = view, generation = generation, session_id = source.id, args = target.id }))
					elseif route == "timeline picker" then assert(timeline.show())
					else assert(timeline.run(route == "timeline fork" and "fork" or "revert", source.id, "caller-turn")) end
					if delayed then
						assert(release)
						vim.api.nvim_win_set_cursor(view.winid, { view.edits["caller-note"].start_line + 1, 0 }); press("m")
						local window = input.get_winids()[1]; assert(window and input.owner_view() == view)
						vim.api.nvim_buf_set_lines(vim.api.nvim_win_get_buf(window), 0, -1, false, { "UNSENT caller note", "Second line" })
						vim.api.nvim_win_set_cursor(window, { 2, 3 }); release(); settle()
						assert(input.is_visible() and input.get_winids()[1] == window and vim.api.nvim_get_current_win() == window)
						assert(input.get_pending_text() == "UNSENT caller note\nSecond line")
						assert(vim.deep_equal({ 2, 3 }, vim.api.nvim_win_get_cursor(window)))
						assert(cs.session(view).id == source.id and view.generation == generation)
						assert(#cs.all() == count and #require("opencode.ui.chat.workspace").list() == layouts)
						press("<C-c>"); assert(edits.get_edit("caller-note").message == "UNSENT caller note\nSecond line")
						assert(history.get_pending(source.id) == "Normal draft\nSecond line")
						assert(history.get_pending_parts(source.id)[1].url == "file:///normal.lua")
						assert(vim.deep_equal({ delivery = "steer" }, history.get_pending_options(source.id)))
						if route == "timeline fork" then
							assert(history.get_pending(target.id) == "Historical prompt" and history.get_pending_parts(target.id)[1].url == "file:///historical.lua")
						elseif route == "timeline revert" then
							local deferred = history.peek_deferred(source.id)
							assert(deferred.text == "Historical prompt" and deferred.parts[1].url == "file:///historical.lua")
						end
					else
						settle()
						if route == "timeline fork" or route == "timeline revert" then
							assert(input.is_visible() and input.get_pending_text() == "Historical prompt" and input.get_pending_parts()[1].url == "file:///historical.lua")
						elseif route == "timeline picker" then
							assert(vim.bo.filetype == "opencode_float"); press("<Esc>")
						end
						assert(app.get_session().id == ((route == "timeline revert" or route == "timeline picker") and source.id or target.id))
					end
					if route == "reopen" then
						assert(vim.deep_equal(delayed and { target.id } or {}, app.get_closed_session_order()))
						assert(app.is_runtime_session(target.id) == not delayed)
					end
					if route ~= "timeline revert" and route ~= "timeline picker" then
						assert(vim.deep_equal(target.model, app.get_session_record(target.id).model))
						assert(app.get_session_record(target.id).title == target.title)
					end
					assert(sync.get_message(source.id, "caller-turn"))
				]], { route, delayed })
			end)
		end
	end
end)
