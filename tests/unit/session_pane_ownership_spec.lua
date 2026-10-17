describe("session pane ownership", function()
	local state, sync = require("opencode.state"), require("opencode.sync")
	local sessions, client = require("opencode.session"), require("opencode.client")
	local pending = require("opencode.session.pending")
	local saved, views, focused, requests, renders, scheduled, events
	local names = { "opencode.ui.chat.state", "opencode.ui.chat", "opencode.ui.chat.render_coordinator", "opencode.events", "opencode.cleanup" }
	local function seed(id)
		state.upsert_session({ id = id, title = id, directory = "/project" })
	end
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all()
		saved, requests, renders, scheduled, events = {}, {}, {}, {}, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		saved.messages, saved.schedule, saved.refresh = client.get_messages, vim.schedule, sessions.refresh_status
		views = {
			{ id = 1, session_id = "a", generation = 0, config = { layout = "tab" } },
			{ id = 2, session_id = "b", generation = 0, config = { layout = "tab" } },
		}
		focused = views[1]
		local registry = {
			current = function() return focused end,
			all = function() return views end,
			valid = function(view, generation) return not view.closed and (generation == nil or generation == view.generation) end,
			session = function(view) return state.get_session_record(view.session_id) or {} end,
			for_session = function(id)
				for _, view in ipairs(views) do if not view.closed and view.session_id == id then return view end end
			end,
		}
		package.loaded["opencode.ui.chat.state"] = registry
		package.loaded["opencode.ui.chat"] = {
			bind_session = function(view, session)
				view.session_id, view.generation = session.id, view.generation + 1
				if focused == view then sessions.set_active(session.id, session.title, { view_id = view.id, reason = "pane_focus" }) end
			end,
			focus_view = function(view)
				focused = view
				sessions.set_active(view.session_id, view.session_id, { view_id = view.id, reason = "pane_focus" })
			end,
			close_view = function(view) view.closed = true; view.generation = view.generation + 1 end,
		}
		package.loaded["opencode.ui.chat.render_coordinator"] = { request = function(data) renders[#renders + 1] = data end }
		package.loaded["opencode.events"] = { emit = function(kind, data) events[#events + 1] = { kind = kind, data = data } end }
		package.loaded["opencode.cleanup"] = { clear_session_memos = function() end, clear_session = function(id) pending.clear_session(id) end }
		client.get_messages = function(id, _, callback) requests[id] = callback end
		vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
		sessions.refresh_status = function() end
		seed("a"); seed("b"); seed("c")
		state.set_session("a", "a")
	end)
	after_each(function()
		for _, id in ipairs(saved.draft_ids or {}) do require("opencode.ui.input.history").clear_session(id) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		client.get_messages, vim.schedule, sessions.refresh_status = saved.messages, saved.schedule, saved.refresh
		for method, original in pairs(saved.catalog_methods or {}) do client[method] = original end
		state.reset(); sync.clear_all(); pending.clear_all()
	end)
	local function flush()
		while #scheduled > 0 do table.remove(scheduled, 1)() end
	end
	it("focuses the existing owner instead of assigning its session twice", function()
		sessions.switch_to({ id = "b", title = "b" }, { view = views[1] })
		assert.equals(views[2], focused)
		assert.equals("a", views[1].session_id)
		assert.equals("b", state.get_session().id)
		assert.is_nil(requests.b)
	end)
	it("renders loaded history for its captured owner after focus moves", function()
		sessions.switch_to({ id = "c", title = "c" }, { view = views[1] })
		focused = views[2]; state.set_session("b", "b")
		renders = {}
		requests.c(nil, { { id = "m", sessionID = "c", role = "assistant", time = { created = 1 } } })
		flush()
		assert.equals("b", state.get_session().id)
		assert.equals("c", views[1].session_id)
		assert.equals(1, #sync.get_messages("c"))
		assert.equals(1, #renders)
		assert.equals(1, renders[1].view_id)
	end)
	it("does not render into a pane rebound before history arrives", function()
		sessions.switch_to({ id = "c", title = "c" }, { view = views[1] })
		views[1].generation = views[1].generation + 1
		views[1].session_id = "a"
		renders = {}
		requests.c(nil, {}); flush()
		assert.same({}, renders)
	end)
	it("tracks a historical root opened in an unfocused pane without changing global focus", function()
		focused = views[2]; state.set_session("b", "b")
		sessions.switch_to({ id = "historical", title = "Historical", directory = "/project" }, { view = views[1] })
		assert.equals("historical", views[1].session_id)
		assert.is_true(state.is_runtime_session("historical"))
		assert.equals("b", state.get_session().id)
		assert.equals(views[2], focused)
	end)
	it("replaces a closed session with an unowned session while retaining its sibling", function()
		assert.is_true(sessions.close("a", { silent = true }))
		assert.equals("c", views[1].session_id)
		assert.equals("b", views[2].session_id)
		assert.is_true(state.is_runtime_session("b"))
	end)
	it("preserves a separately displayed child tree, its drafts and pending work when its parent closes", function()
		local history = require("opencode.ui.input.history")
		saved.draft_ids = { "b", "grandchild" }
		state.upsert_session({ id = "grandchild", parentID = "b" }, { touch = false })
		for _, id in ipairs({ "a", "b", "grandchild" }) do
			sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
			pending.begin({ session_id = id, message_id = id .. "-pending", status = "queued" })
		end
		sync.record_task_child_session("a", "a-message", "a-task", "b")
		sync.record_task_child_session("b", "b-message", "b-task", "grandchild")
		views[2].session_id, views[2].session_stack = "grandchild", { { id = "b" } }
		history.set_pending("child draft", {}, "b")
		history.defer_pending({ text = "grandchild draft", parts = {} }, "grandchild")
		local child_token, grandchild_token = pending.token("b"), pending.token("grandchild")
		local cleared = {}
		package.loaded["opencode.cleanup"].clear_session_memos = function(id) cleared[#cleared + 1] = id end
		assert.is_true(sessions.close("a", { silent = true }))
		assert.same({}, sync.get_messages("a"))
		assert.equals(1, #sync.get_messages("b"))
		assert.equals(1, #sync.get_messages("grandchild"))
		assert.equals("c", views[1].session_id)
		assert.equals("grandchild", views[2].session_id)
		assert.same({ "a" }, cleared)
		for _, event in ipairs(events) do
			if event.kind == "session.closed" then
				assert.same({ "a" }, event.data.session_ids)
				for _, id in ipairs(event.data.session_ids) do pending.clear_session(id) end
			end
		end
		assert.is_true(pending.is_current(child_token))
		assert.is_true(pending.is_current(grandchild_token))
		assert.equals("queued", pending.get("b", "b-pending").status)
		assert.equals("child draft", history.get_pending("b"))
		assert.equals("grandchild draft", history.take_deferred("grandchild").text)
	end)
	it("closes an unfocused pane when every remaining session is already displayed", function()
		state.close_runtime_session("c")
		assert.is_true(sessions.close("b", { silent = true }))
		assert.is_true(views[2].closed)
		assert.equals("a", views[1].session_id)
		assert.equals("a", state.get_session().id)
	end)
	it("handles deletion in an unfocused pane without replacing the focused one", function()
		assert.is_true(sessions.handle_deleted("b"))
		assert.equals("c", views[2].session_id)
		assert.equals("a", views[1].session_id)
		assert.equals("a", state.get_session().id)
		assert.is_nil(state.get_session_record("b"))
	end)
	for _, suspended in ipairs({ false, true }) do
		it("removes every displayed descendant of a deleted parent (suspended=" .. tostring(suspended) .. ")", function()
			state.upsert_session({ id = "child", parentID = "a" }, { touch = false })
			sync.handle_message_updated({ id = "a-message", sessionID = "a", role = "assistant" })
			sync.record_task_child_session("a", "a-message", "a-task", "child")
			local child = { id = 3, session_id = "child", generation = 0, visible = not suspended,
				suspended = suspended, config = { layout = "tab" } }
			views[#views + 1] = child
			focused = views[2]; state.set_session("b", "b")
			assert.is_true(sessions.handle_deleted("a"))
			for _, view in ipairs(views) do
				if not view.closed then
					assert.is_not.equals("a", view.session_id)
					assert.is_not.equals("child", view.session_id)
					assert.is_not_nil(state.get_session_record(view.session_id))
				end
			end
			assert.equals("b", state.get_session().id)
			assert.equals("b", views[2].session_id)
			assert.is_nil(state.get_session_record("child"))
		end)
	end

	it("derives tab selection from the addressed pane", function()
		local selectors = require("opencode.selectors")
		assert.equals("b", selectors.get_current_runtime_root_id({ session_id = "b" }))
		assert.is_true(selectors.get_session_view("b", { session_id = "b" }):is_current_session())
		assert.is_false(selectors.get_session_view("a", { session_id = "b" }):is_current_session())
	end)
	it("keeps catalogs when focus moves within a directory and loads a different directory", function()
		local handlers, directories = {}, {}
		saved.catalog_methods = {}
		for _, method in ipairs({ "get_config_providers", "list_agents", "list_commands", "list_skills", "get_mcp_status", "get_config" }) do
			saved.catalog_methods[method] = client[method]
			client[method] = function(_, opts) directories[#directories + 1] = opts.directory end
		end
		require("opencode.events.handlers.sync_data").setup({ on = function(event, callback) handlers[event] = callback end })
		state.set_connection("connected")
		sync.select_catalog_location("/project")
		handlers.session_change({ reason = "pane_focus" })
		assert.same({}, directories)
		state.upsert_session({ id = "b", directory = "/other" }, { touch = false })
		state.set_session("b", "b")
		handlers.session_change({ reason = "pane_focus" })
		assert.equals(6, #directories)
		for _, directory in ipairs(directories) do assert.equals("/other", directory) end
	end)
end)
