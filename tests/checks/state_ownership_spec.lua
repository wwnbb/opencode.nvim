-- Behavioral state ownership checks. Each case gets fresh application modules.
-- Run with: ./tests/run.sh tests/checks/state_ownership_spec.lua
-- Navigation preserve_cache coverage lives in tests/unit/session_store_v2_spec.lua.

local function assert_eq(actual, expected, message)
	assert.equals(expected, actual, message)
end

local function assert_true(value, message)
	assert.is_truthy(value, message)
end

local function wait_for(predicate, message)
	assert.is_true(vim.wait(500, predicate, 10), message)
end

local function is_opencode(name)
	return name == "opencode" or name:match("^opencode%.") ~= nil
end

describe("opencode state ownership", function()
	local bus, state, sync, local_state, selectors, session_actions, client
	local permission_state, question_state, edit_state, notifications
	local saved_modules, original_notify, original_defer, timers, buffers, autocmds

	before_each(function()
		saved_modules, timers, buffers, autocmds = {}, {}, {}, {}
		for name, module in pairs(package.loaded) do
			if is_opencode(name) then saved_modules[name] = module; package.loaded[name] = nil end
		end
		for _, id in ipairs(vim.api.nvim_list_bufs()) do buffers[id] = true end
		for _, entry in ipairs(vim.api.nvim_get_autocmds({})) do
			if entry.id then autocmds[entry.id] = true end
		end
		original_notify, original_defer = vim.notify, vim.defer_fn
		notifications = {}
		vim.notify = function(message, level)
			notifications[#notifications + 1] = { message = tostring(message), level = level }
		end
		vim.defer_fn = function(callback, delay)
			local timer = original_defer(callback, delay)
			timers[#timers + 1] = timer
			return timer
		end
		bus = require("opencode.events.bus")
		state = require("opencode.state")
		sync = require("opencode.sync")
		local_state = require("opencode.local")
		selectors = require("opencode.selectors")
		session_actions = require("opencode.session")
		client = require("opencode.client")
		permission_state = require("opencode.permission.state")
		question_state = require("opencode.question.state")
		edit_state = require("opencode.edit.state")
	end)

	after_each(function()
		bus.clear()
		state.clear_listeners()
		require("opencode.session.pending").clear_all()
		local handler = package.loaded["opencode.events.handlers.v2"]
		if handler then handler.clear() end
		local chat = package.loaded["opencode.ui.chat"]
		if chat then chat.close() end
		for _, entry in ipairs(vim.api.nvim_get_autocmds({})) do
			if entry.id and not autocmds[entry.id] then pcall(vim.api.nvim_del_autocmd, entry.id) end
		end
		for _, id in ipairs(vim.api.nvim_list_bufs()) do
			if not buffers[id] then pcall(vim.api.nvim_buf_delete, id, { force = true }) end
		end
		for _, timer in ipairs(timers) do
			if not timer:is_closing() then timer:stop(); timer:close() end
		end
		-- Flush scheduled callbacks before replacing the module graph they use.
		local drained = false
		vim.schedule(function() drained = true end)
		vim.wait(500, function() return drained end, 10)
		vim.notify, vim.defer_fn = original_notify, original_defer
		for name in pairs(package.loaded) do
			if is_opencode(name) then package.loaded[name] = nil end
		end
		for name, module in pairs(saved_modules) do package.loaded[name] = module end
		for _, item in ipairs(notifications) do
			assert.is_nil(item.message:match("listener error"), item.message)
		end
	end)

	local function add_form(id, session_id, title)
		return question_state.add_form({
			id = id, sessionID = session_id,
			fields = { { key = "choice", type = "string", title = title,
				options = { { label = "Yes", value = "yes" } } } },
			state = { status = "pending" },
		})
	end

	local function seed_catalog()
		sync.handle_providers({
			{ id = "p1", name = "Provider 1", models = { m1 = { name = "Model 1" } } },
			{ id = "p2", name = "Provider 2", models = { m2 = { name = "Model 2" } } },
		})
		sync.handle_agents({ { id = "code", name = "Code" }, { id = "plan", name = "Plan" } })
	end

	local function setup_initial_sync_capture()
		local loaded, changed = { providers = 0, agents = 0, config = 0, skills = 0 }, {}
		require("opencode.events.handlers.sync_data").setup(bus)
		for domain in pairs(loaded) do
			bus.on(domain .. "_loaded", function() loaded[domain] = loaded[domain] + 1 end)
		end
		bus.on("sync_changed", function(data)
			if data.action == "loaded" then changed[data.kind] = (changed[data.kind] or 0) + 1 end
		end)
		return loaded, changed
	end

	local function emit_native(kind, sid, id, data)
		bus.emit("v2_event", { id = id, type = kind,
			data = vim.tbl_extend("force", { sessionID = sid }, data or {}), created = 10 })
	end

	it("keeps store loading and mutations independent from the event facade", function()
		assert_eq(package.loaded["opencode.events"], nil, "stores should not load event facade")

		permission_state.add_permission("perm_store", "session_a", "bash", {})
		permission_state.select_option("perm_store", 2)
		add_form("question_store", "session_a", "Pick")
		question_state.select_option("question_store", 1)
		edit_state.add_edit("edit_store", "session_a", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		assert_eq(package.loaded["opencode.events"], nil, "store mutations should not load event facade")
		assert_eq(#bus.get_history(), 0, "store mutations should not emit events")
	end)

	it("forwards config changes through the state bridge", function()
		require("opencode.events.state_bridge").setup(bus)
		local config_change_count = 0
		bus.on("config_change", function() config_change_count = config_change_count + 1 end)
		state.set_config({ bridge_test = true })
		assert_eq(config_change_count, 1, "state config changes should cross the state/event bridge")
	end)

	it("surfaces SSE errors through notifications", function()
		require("opencode.events.handlers.notifications").setup(bus)
		bus.emit("error", { message = "sse boom" })
		wait_for(function()
			for _, item in ipairs(notifications) do
				if item.message:find("OpenCode event stream error: sse boom", 1, true) then
					return true
				end
			end
			return false
		end, "SSE errors should surface through vim.notify")
	end)

	it("resolves explicit selection before validated local defaults", function()
		seed_catalog()
		state.set_config({
			session = {
				default_model = { providerID = "p1", modelID = "m1" },
				default_agent = "Code",
			},
		})
		local_state.agent.set("Plan")
		local_state.model.set({ providerID = "p2", modelID = "m2" })

		local selected = selectors.send_selection({
			model = { providerID = "p1", modelID = "m1" },
			agent = "Code",
			variant = "fast",
		})
		assert_eq(selected.model.providerID, "p1", "opts model provider should win")
		assert_eq(selected.model.modelID, "m1", "opts model id should win")
		assert_eq(selected.agent, "Code", "opts agent should win")
		assert_eq(selected.variant, "fast", "opts variant should win")

		local fallback = selectors.send_selection({
			model = { providerID = "missing", modelID = "nope" },
		})
		assert_eq(fallback.model.providerID, "p2", "invalid opts model should fall back to local provider")
		assert_eq(fallback.model.modelID, "m2", "invalid opts model should fall back to local model")
		assert_eq(fallback.agent, "plan", "local agent should be selected")
		assert_eq(selectors.current_model().providerID, "p2", "selectors should expose local provider selection")
		assert_eq(selectors.current_model().modelID, "m2", "selectors should expose local model selection")
		assert_eq(selectors.current_agent().name, "Plan", "selectors should expose local agent selection")
	end)

	it("loads each catalog and emits its completion events", function()
		client.get_config_providers = function(callback)
			callback(nil, {
				providers = {
					{ id = "sync-provider", name = "Sync Provider", models = { ["sync-model"] = { name = "Sync Model" } } },
				},
				default = { ["sync-provider"] = "sync-model" },
			})
		end
		client.list_agents = function(callback)
			callback(nil, { { id = "sync-agent", name = "Sync Agent" } })
		end
		client.get_config = function(callback)
			callback(nil, {
				model = "sync-model",
				default_agent = "Sync Agent",
				command = { sync_command = { template = "echo sync" } },
			})
		end
		client.list_commands = function(callback) callback(nil, { sync_command = { template = "echo sync" } }) end
		client.list_skills = function(callback)
			callback(nil, { { name = "sync-skill" } })
		end
		client.get_mcp_status = function(callback)
			callback(nil, { servers = { sync = { status = "connected" } } })
		end
		local loaded, sync_changed = setup_initial_sync_capture()
		bus.emit("connected")
		wait_for(function()
			return loaded.providers == 1
				and loaded.agents == 1
				and loaded.config == 1
				and loaded.skills == 1
				and sync_changed.providers == 1
				and sync_changed.agents == 1
				and sync_changed.config == 1
				and sync_changed.skills == 1
				and sync_changed.mcp == 1
		end, "initial sync success should emit all loaded and sync_changed events")
		assert_eq(sync.get_providers()[1].id, "sync-provider", "initial sync should store providers")
		assert_eq(sync.get_provider_defaults()["sync-provider"], "sync-model", "initial sync should store provider defaults")
		assert_eq(sync.get_agents()[1].name, "Sync Agent", "initial sync should store agents")
		assert_eq(sync.get_config().model, "sync-model", "initial sync should store config")
		assert_true(sync.get_commands().sync_command ~= nil, "initial sync should store commands")
		assert_eq(sync.get_skills()[1].name, "sync-skill", "initial sync should store skills")
		assert_eq(sync.get_mcp().servers.sync.status, "connected", "initial sync should store MCP status")
	end)

	it("keeps successful catalogs when provider and MCP fetches fail", function()
		local local_notices = {}
		local notification_baseline = #notifications
		client.get_config_providers = function(callback)
			callback({ message = "providers failed" })
		end
		client.list_agents = function(callback)
			callback(nil, { { id = "agent-after-failure", name = "Agent After Failure" } })
		end
		client.get_config = function(callback)
			callback(nil, { command = { failure_command = { template = "echo still runs" } } })
		end
		client.list_commands = function(callback) callback(nil, { failure_command = { template = "echo still runs" } }) end
		client.list_skills = function(callback)
			callback(nil, { { name = "skill-after-failure" } })
		end
		client.get_mcp_status = function(callback)
			callback({ message = "mcp failed quietly" })
		end
		local loaded, sync_changed = setup_initial_sync_capture()
		bus.on("local_notice", function(data)
			table.insert(local_notices, data)
		end)
		bus.emit("connected")
		wait_for(function()
			return #local_notices > 0
				and #notifications == notification_baseline + 1
				and loaded.agents == 1
				and loaded.config == 1
				and loaded.skills == 1
				and sync_changed.agents == 1
				and sync_changed.config == 1
				and sync_changed.skills == 1
		end, "one initial sync failure should not prevent other fetches")
		assert_true(
			local_notices[1].content:find("Failed to fetch providers: providers failed", 1, true) ~= nil,
			"initial sync local notice should include the failing fetch"
		)
		assert_eq(loaded.providers, 0, "failed providers fetch should not emit providers_loaded")
		assert_eq(sync.get_agents()[1].name, "Agent After Failure", "agents should still load after provider failure")
		assert_true(sync.get_commands().failure_command ~= nil, "config commands should still load after provider failure")
		assert_eq(sync.get_skills()[1].name, "skill-after-failure", "skills should still load after provider failure")
		for index = notification_baseline + 1, #notifications do
			assert_true(
				notifications[index].message:find("mcp failed quietly", 1, true) == nil,
				"MCP initial sync errors should remain quiet"
			)
		end
	end)

	it("does not append logs when reading the same model fallback", function()
		seed_catalog()
		local logger = require("opencode.logger")
		sync.handle_provider_defaults({ p1 = "m1" })
		local_state.agent.set("Code")
		logger.clear()
		local fallback_current = local_state.model.current()
		assert_eq(fallback_current.providerID, "p1", "fallback provider default should be selected")
		assert_eq(fallback_current.modelID, "m1", "fallback provider default model should be selected")
		local first_log_count = logger.count()
		local_state.model.current()
		assert_eq(logger.count(), first_log_count, "unchanged model selection reads should not append logs")
	end)

	it("mirrors native execution status without inferring idle from history", function()
		session_actions.set_active("session_status", "Status Session", { preserve_cache = true })
		require("opencode.events.handlers.v2").setup(bus)
		emit_native("session.execution.started", "session_status", "evt-status-start")
		wait_for(function() return state.get_status() == "streaming" end,
			"native execution start should set streaming")

		sync.handle_session_messages("session_status", {
			{ info = { id = "completed_step", sessionID = "session_status", role = "assistant",
				time = { created = 1, completed = 2 }, finish = "stop" }, parts = {} },
		}, { complete = true })
		assert_eq(state.get_session_status("session_status").type, "busy",
			"completed assistant snapshot alone should not infer idle")
		emit_native("session.execution.succeeded", "session_status", "evt-status-stop")
		wait_for(function() return state.get_status() == "idle" end,
			"native execution success should set idle")
	end)

	it("idles only the session addressed by a terminal event", function()
		require("opencode.events.handlers.v2").setup(bus)
		sync.clear_all()
		state.set_session("running_root", "Running Root")
		state.set_session("complete_root", "Complete Root")
		session_actions.set_session_status("running_root", { type = "busy" }, { reason = "test_busy" })
		session_actions.set_session_status("complete_root", { type = "busy" }, { reason = "test_busy" })
		emit_native("session.execution.succeeded", "complete_root", "evt-complete-root")
		wait_for(function() return state.get_session_status("complete_root").type == "idle" end,
			"native terminal event should idle only its owning session")
		assert_eq(state.get_session_status("running_root").type, "busy", "unrelated running session should stay busy")
	end)

	it("exposes read-only session views with defensive copies", function()
		session_actions.set_active("view_root", "View Root", { preserve_cache = true })
		session_actions.set_session_status("view_root", { type = "retry", attempt = 2 }, { reason = "test_view" })
		state.set_session_pending_counts("view_root", { questions = 1, edits = 1 })
		state.set_session_message_cache("view_root", { count = 3, loaded = true })
		local view = selectors.get_current_session_view()
		assert_true(view ~= nil, "current session selector should return a view")
		assert_eq(getmetatable(view), "SessionView", "selector session result should be a SessionView")
		assert_eq(view.id, "view_root", "SessionView should expose scalar id")
		assert_eq(view:status_label(), "retry #2", "SessionView should format retry status labels")
		assert_eq(view:pending_total(), 2, "SessionView pending total should include questions and edits")
		assert_eq(view:message_count(), 3, "SessionView message count should use fresh message cache")
		local pending_copy = view.pending
		pending_copy.questions = 99
		assert_eq(view.pending.questions, 1, "SessionView pending table reads should be defensive copies")
		local cache_copy = view.cached_messages
		cache_copy.count = 99
		assert_eq(view.cached_messages.count, 3, "SessionView cache reads should be defensive copies")
		local record_copy = view.record
		record_copy.name = "Mutated"
		assert_eq(view.name, "View Root", "SessionView record reads should be defensive copies")
		local assign_ok = pcall(function()
			view.name = "Mutated"
		end)
		assert_true(not assign_ok, "SessionView direct assignment should fail")
		local active_views = selectors.get_active_session_views()
		assert_eq(getmetatable(active_views[1]), "SessionView", "active session selector should return SessionViews")
		assert_eq(active_views[1]:message_count(), 3, "active SessionView should expose fresh cache count")
		local snapshot = state.get_full_state()
		assert_eq(getmetatable(snapshot.sessions.by_id.view_root), nil, "state session records should stay plain tables")
	end)

	it("rolls pending interactions up to their owning runtime root", function()
		state.set_session("permission_waiting", "Permission Waiting")
		state.set_session("permission_idle", "Permission Idle")
		permission_state.add_permission("perm_waiting_root", "permission_waiting", "bash", {})
		session_actions.recount_pending()
		assert_eq(
			state.get_session_pending_counts("permission_waiting").permissions,
			1,
			"root permission should count only on owning session"
		)
		assert_eq(
			state.get_session_pending_counts("permission_idle").permissions,
			0,
			"unrelated session should not inherit root permission count"
		)

		sync.handle_message_updated({
			id = "permission_waiting_assistant",
			sessionID = "permission_waiting",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "permission_waiting_task",
			messageID = "permission_waiting_assistant",
			sessionID = "permission_waiting",
			type = "tool",
			tool = "task",
			metadata = { sessionId = "permission_child" },
		})
		permission_state.add_permission("perm_waiting_child", "permission_child", "bash", {})
		permission_state.add_permission("perm_idle_root", "permission_idle", "bash", {})
		session_actions.recount_pending()
		assert_eq(
			state.get_session_pending_counts("permission_waiting").permissions,
			2,
			"child permission should roll up only to owning root session"
		)
		assert_eq(
			state.get_session_pending_counts("permission_idle").permissions,
			1,
			"unrelated root permission should remain isolated"
		)
		add_form("question_waiting_child", "permission_child", "Continue?")
		edit_state.add_edit("edit_waiting_root", "permission_waiting", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		session_actions.recount_pending()
		assert_eq(
			state.get_session_pending_counts("permission_waiting").questions,
			1,
			"child questions should roll up to owning root session"
		)
		assert_eq(
			state.get_session_pending_counts("permission_waiting").edits,
			1,
			"root edits should count on owning root session"
		)
		assert_eq(
			state.get_session_pending_counts("permission_idle").questions,
			0,
			"unrelated root should not inherit child question count"
		)
	end)

	it("decodes native permission identity and rejects incomplete payloads", function()
		local request = require("opencode.events.handlers.permission_flow.request")
		local decoded = assert(request.decode({
			id = "decoder_wire", action = "shell", sessionID = "visible_session",
			source = { type = "tool", messageID = "decoder_message", callID = "decoder_call" },
			resources = { "*.lua" }, time = { created = 1000 },
		}))
		assert_eq(decoded.id, "decoder_wire", "decoder should accept native request id")
		assert_eq(decoded.type, "shell", "decoder should accept native action")
		assert_eq(decoded.session_id, "visible_session", "decoder should accept native session id")
		assert_eq(decoded.message_id, "decoder_message", "decoder should accept native source message id")
		assert_eq(decoded.call_id, "decoder_call", "decoder should accept native source callID")
		assert_eq(decoded.patterns[1], "*.lua", "decoder should preserve native resource patterns")
		assert_eq(request.decode({ action = "shell", sessionID = "visible_session" }), nil,
			"decoder should reject missing request id")
		assert_eq(request.decode({ id = "missing_session", action = "shell" }), nil,
			"decoder should reject missing session id")
	end)

	it("retains native permissions and forms only for relevant runtime sessions", function()
		session_actions.set_active("other_session", "Other Session", { preserve_cache = true })
		session_actions.set_active("visible_session", "Visible Session", { preserve_cache = true })
		require("opencode.events.handlers.interactions_v2").setup(bus)
		sync.handle_message_updated({ id = "permission_tool_message", sessionID = "visible_session",
			role = "assistant", time = { created = 1 } })
		sync.handle_part_updated({ id = "permission_tool_part", messageID = "permission_tool_message",
			sessionID = "visible_session", type = "tool", tool = "bash", callID = "tool_call",
			state = { input = { command = "from sync" } } })
		bus.emit("v2_interaction", { id = "evt-permission-visible", type = "permission.asked",
			data = { id = "perm_visible_session", action = "shell", sessionID = "visible_session",
				source = { type = "tool", messageID = "permission_tool_message", callID = "tool_call" },
				metadata = { input = { command = "from metadata" } } }, created = 1000 })
		wait_for(function() return permission_state.has_permission("perm_visible_session") end,
			"native permission in visible session should be tracked")
		assert_eq(permission_state.get_permission("perm_visible_session").tool_input.command, "from sync",
			"native permission should prefer synchronized tool input")

		bus.emit("v2_interaction", { id = "evt-permission-other", type = "permission.asked",
			data = { id = "perm_other_session", action = "shell", sessionID = "other_session",
				metadata = { input = { command = "other" } } }, created = 1001 })
		wait_for(function() return permission_state.has_permission("perm_other_session") end,
			"permission in another runtime tab should remain independently tracked")
		bus.emit("v2_interaction", { id = "evt-permission-foreign", type = "permission.asked",
			data = { id = "perm_foreign", action = "shell", sessionID = "foreign_session" }, created = 1002 })
		assert_true(not permission_state.has_permission("perm_foreign"),
			"permission outside runtime sessions should be ignored")

		local function emit_form(id, sid)
			bus.emit("v2_interaction", { id = "evt-" .. id, type = "form.created", created = 1003,
				data = { form = { id = id, sessionID = sid, state = { status = "pending" },
					fields = { { key = "choice", type = "string", title = "Pick",
						options = { { label = "A", value = "a" } } } } } } })
		end
		emit_form("form_other_session", "other_session")
		emit_form("form_visible_session", "visible_session")
		wait_for(function() return question_state.has_question("form_other_session")
			and question_state.has_question("form_visible_session") end,
			"native forms should be retained for each runtime tab")
	end)

	it("coalesces same-tick render requests", function()
		local render_coordinator = require("opencode.ui.chat.render_coordinator")
		render_coordinator.setup(bus)
		local render_count = 0
		bus.on("chat_render", function()
			render_count = render_count + 1
		end)
		render_coordinator.request({ session_id = "session_status" })
		render_coordinator.request({ reason = "second_request" })
		wait_for(function()
			return render_count == 1
		end, "render coordinator should coalesce same-tick requests")
	end)

	it("renders questions directly from the question store", function()
		session_actions.set_active("session_hidden", "Hidden Widget", { preserve_cache = true })
		question_state.clear_all()
		add_form("hidden_question", "session_hidden", "Hidden?")
		local chat = require("opencode.ui.chat")
		chat.create()
		local lines = chat.render()
		local rendered = table.concat(lines, "\n")
		assert_true(rendered:find("Hidden%?") ~= nil, "hidden question should render from question store")
	end)

	it("closes a child through its root and emits permission removal events", function()
		local close_replies = {}
		client.respond_permission = function(permission_id, reply, opts)
			table.insert(close_replies, {
				permission_id = permission_id,
				reply = reply,
				opts = opts,
			})
		end
		require("opencode.events.handlers.session_store").setup(bus)
		session_actions.set_active("session_close_a", "Session Close A", { preserve_cache = true })
		session_actions.set_active("session_close_b", "Session Close B", { preserve_cache = true })
		session_actions.set_active("session_close_a", "Session Close A", { preserve_cache = true })

		sync.handle_message_updated({
			id = "task_parent_message",
			sessionID = "session_close_a",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "task_parent_task_part",
			messageID = "task_parent_message",
			sessionID = "session_close_a",
			type = "tool",
			tool = "task",
			metadata = { sessionId = "session_close_child" },
		})
		assert_eq(sync.get_task_parent_session("session_close_child"), "session_close_a", "task child index should record the parent before close")

		permission_state.add_permission("close_perm_a", "session_close_a", "bash", {})
		permission_state.add_permission("close_perm_child", "session_close_child", "bash", {})
		permission_state.add_permission("close_perm_other", "session_close_b", "bash", {})
		assert_true(session_actions.close("session_close_child", { silent = true }), "session.close should resolve a child session to its runtime root")
		wait_for(function()
			return #close_replies == 2
				and not permission_state.has_permission("close_perm_a")
				and not permission_state.has_permission("close_perm_child")
				and permission_state.has_permission("close_perm_other")
		end, "session.close should clear the closed session permissions and preserve others")

		local function history_has(event_type, permission_id)
			for _, entry in ipairs(bus.get_history()) do
				if entry.type == event_type and type(entry.data) == "table" then
					if entry.data.permission_id == permission_id or entry.data.id == permission_id then
						return true
					end
				end
			end
			return false
		end

		local close_replies_by_id = {}
		for _, reply in ipairs(close_replies) do
			assert_eq(reply.reply, "reject", "session.close should reject native permissions")
			assert_eq(reply.opts.message, "Session closed", "session.close should use the close message")
			close_replies_by_id[reply.permission_id] = reply
		end
		assert_eq(close_replies_by_id.close_perm_a.opts.session_id, "session_close_a", "session.close should pass the native permission owner")
		assert_eq(close_replies_by_id.close_perm_child.opts.session_id, "session_close_child", "session.close should pass the child permission owner")
		assert_true(history_has("permission_rejected", "close_perm_a"), "session.close should emit permission_rejected for the root permission")
		assert_true(history_has("permission_removed", "close_perm_a"), "session.close should emit permission_removed for the root permission")
		assert_true(history_has("interaction_changed", "close_perm_a"), "session.close should emit interaction_changed for the root permission")
		assert_true(history_has("permission_rejected", "close_perm_child"), "session.close should emit permission_rejected for the task child permission")
		assert_true(history_has("permission_removed", "close_perm_child"), "session.close should emit permission_removed for the task child permission")
		assert_true(history_has("interaction_changed", "close_perm_child"), "session.close should emit interaction_changed for the task child permission")
	end)

	it("rejects and removes only interactions owned by the closed root", function()
		local rejected_permissions = {}
		local rejected_questions = {}
		client.respond_permission = function(permission_id, reply, opts, callback)
			table.insert(rejected_permissions, {
				permission_id = permission_id,
				reply = reply,
				opts = opts,
			})
			if callback then
				callback(nil, true)
			end
		end
		client.reject_question = function(session_id, request_id, opts, callback)
			table.insert(rejected_questions, {
				session_id = session_id,
				request_id = request_id,
				opts = opts,
			})
			if callback then
				callback(nil, true)
			end
		end

		local close_root_directory = "/tmp/__opencode_close_root__"
		local close_child_directory = "/tmp/__opencode_close_child__"
		state.upsert_session({ id = "close_root", directory = close_root_directory }, { touch = false })
		state.upsert_session({ id = "close_child", directory = close_child_directory }, { touch = false })
		state.set_session("close_root", "Close Root")
		state.set_session("keep_root", "Keep Root")
		state.set_session("close_root", "Close Root")
		sync.handle_message_updated({
			id = "close_root_assistant",
			sessionID = "close_root",
			role = "assistant",
			time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "close_root_task",
			messageID = "close_root_assistant",
			sessionID = "close_root",
			type = "tool",
			tool = "task",
			metadata = { sessionId = "close_child" },
		})
		permission_state.add_permission("perm_close_root", "close_root", "bash", {})
		permission_state.add_permission("perm_close_child", "close_child", "bash", {})
		permission_state.add_permission("perm_keep_root", "keep_root", "bash", {})
		add_form("question_close_root", "close_root", "Close root?")
		add_form("question_close_child", "close_child", "Close child?")
		add_form("question_keep_root", "keep_root", "Keep root?")
		edit_state.add_edit("edit_close_root", "close_root", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		edit_state.add_edit("edit_close_child", "close_child", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		edit_state.add_edit("edit_keep_root", "keep_root", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })

		assert_true(session_actions.close("close_root", { silent = true }) == true, "close should remove target runtime tab")
		assert_true(not permission_state.has_permission("perm_close_root"), "close should clear root permission")
		assert_true(not permission_state.has_permission("perm_close_child"), "close should clear child permission")
		assert_true(permission_state.has_permission("perm_keep_root"), "close should preserve unrelated permission")
		assert_true(not question_state.has_question("question_close_root"), "close should clear root question")
		assert_true(not question_state.has_question("question_close_child"), "close should clear child question")
		assert_true(question_state.has_question("question_keep_root"), "close should preserve unrelated question")
		assert_true(edit_state.get_edit("edit_close_root") == nil, "close should clear root edit")
		assert_true(edit_state.get_edit("edit_close_child") == nil, "close should clear child edit")
		assert_true(edit_state.get_edit("edit_keep_root") ~= nil, "close should preserve unrelated edit")
		assert_eq(#rejected_permissions, 2, "close should reject root and child native permissions")
		local rejected_permissions_by_id = {}
		for _, rejection in ipairs(rejected_permissions) do rejected_permissions_by_id[rejection.permission_id] = rejection end
		assert_eq(rejected_permissions_by_id.perm_close_root.opts.session_id, "close_root", "root permission owner")
		assert_eq(rejected_permissions_by_id.perm_close_child.opts.session_id, "close_child", "child permission owner")
		assert_eq(#rejected_questions, 2, "close should reject root and child questions")
		local rejected_questions_by_id = {}
		for _, rejection in ipairs(rejected_questions) do
			rejected_questions_by_id[rejection.request_id] = rejection
		end
		assert_eq(
			rejected_questions_by_id.question_close_root.opts.directory,
			state.normalize_directory(close_root_directory),
			"close should reject the root question in its owning directory"
		)
		assert_eq(
			rejected_questions_by_id.question_close_child.opts.directory,
			state.normalize_directory(close_child_directory),
			"close should reject the child question in its owning directory"
		)
	end)

	it("auto-approves valid permissions while dropping missing session identity", function()
		state.set_danger_mode(true)
		local replies = {}
		client.respond_permission = function(permission_id, reply, opts, callback)
			table.insert(replies, {
				permission_id = permission_id,
				reply = reply,
				opts = opts,
			})
			if callback then
				callback(nil, true)
			end
		end

		session_actions.set_active("session_hidden", "Hidden Widget", { preserve_cache = true })
		require("opencode.events.handlers.interactions_v2").setup(bus)
		bus.emit("v2_interaction", { id = "evt-danger-missing", type = "permission.asked", data = {
			id = "danger_missing_session",
			action = "shell",
		}, created = 1000 })
		vim.wait(50)
		assert_eq(#replies, 0, "danger mode should not auto-reply to permission without session identity")
		assert_true(
			not permission_state.has_permission("danger_missing_session"),
			"danger mode should drop permission without session identity"
		)

		bus.emit("v2_interaction", { id = "evt-danger-perm", type = "permission.asked", data = {
			id = "danger_perm",
			action = "shell",
			sessionID = "session_hidden",
		}, created = 1001 })
		wait_for(function()
			return #replies == 1
		end, "danger mode should auto-reply to permission requests")
		assert_eq(replies[1].permission_id, "danger_perm", "danger mode reply should target permission")
		assert_eq(replies[1].reply, "once", "danger mode should use one-shot approval")
		wait_for(function()
			return permission_state.get_permission("danger_perm").status == "approved"
		end, "danger mode should resolve pending permission widget after confirmation")
	end)

	it("resets transient stores and danger approval dedupe", function()
		local replies = {}
		local cleanup_chat = require("opencode.ui.chat")
		local cleanup_chat_state = require("opencode.ui.chat.state").state
		local danger = require("opencode.permission.danger")
		client.respond_permission = function(permission_id, reply, opts, callback)
			table.insert(replies, {
				permission_id = permission_id,
				reply = reply,
				opts = opts,
			})
			if callback then
				callback(nil, true)
			end
		end
		sync.handle_message_updated({
			id = "cleanup_message",
			sessionID = "cleanup_session",
			role = "assistant",
			time = { created = 1 },
		})
		permission_state.add_permission("cleanup_perm", "cleanup_session", "bash", {})
		add_form("cleanup_question", "cleanup_session", "Cleanup?")
		edit_state.add_edit("cleanup_edit", "cleanup_session", {
			{ filePath = "cleanup.lua", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		cleanup_chat.add_message("system", "cleanup notice", { render = false })
		local replies_before_cleanup = #replies
		danger.approve("cleanup_danger")
		assert_eq(#replies, replies_before_cleanup + 1, "danger approval should queue before cleanup")
		require("opencode.cleanup").reset_all()
		assert_eq(#sync.get_messages("cleanup_session"), 0, "cleanup should clear sync messages")
		assert_true(not permission_state.has_permission("cleanup_perm"), "cleanup should clear permissions")
		assert_true(not question_state.has_question("cleanup_question"), "cleanup should clear questions")
		assert_eq(edit_state.get_edit("cleanup_edit"), nil, "cleanup should clear edits")
		assert_eq(#cleanup_chat_state.local_notices, 0, "cleanup should clear chat local notices")
		danger.approve("cleanup_danger")
		assert_eq(#replies, replies_before_cleanup + 2, "cleanup should clear danger reply dedupe")
	end)

	it("wraps historical file results using panel prefixes and diff highlights", function()
		local file_edit_results = require("opencode.ui.chat.file_edit_results")
		local long_title = "Patch applied " .. string.rep("with wrapped summary ", 8)
		local rendered_file_result = file_edit_results.render_tool({
			tool = "apply_patch",
			state = {
				status = "completed",
				metadata = {
					title = long_title,
					files = {
						{
							filePath = "lua/opencode/some/really/long/path/for/render_check.lua",
							type = "update",
							status = "applied",
							additions = 3,
							deletions = 2,
						},
					},
				},
			},
		}, false)
		assert_true(rendered_file_result ~= nil, "file edit result should render")
		assert_true(#rendered_file_result.lines > 1, "file edit result should wrap long panel text")
		for _, line_text in ipairs(rendered_file_result.lines) do
			assert_eq(line_text:sub(1, #"▏  "), "▏  ", "file edit result lines should use panel prefix")
		end
		local has_diff_add = false
		local has_diff_delete = false
		for _, hl in ipairs(rendered_file_result.highlights) do
			has_diff_add = has_diff_add or hl.hl_group == "DiffAdd"
			has_diff_delete = has_diff_delete or hl.hl_group == "DiffDelete"
		end
		assert_true(has_diff_add, "file edit result should highlight additions")
		assert_true(has_diff_delete, "file edit result should highlight deletions")
	end)

	it("does not infer session status from a completed history page", function()
		state.set_session("reconcile_root", "Reconcile Root")
		state.set_session("reconcile_other", "Reconcile Other")
		session_actions.set_session_status("reconcile_root", { type = "busy" }, { reason = "test_busy" })
		session_actions.set_session_status("reconcile_other", { type = "busy" }, { reason = "test_busy" })
		sync.handle_session_messages("reconcile_root", {
			{ info = { id = "reconcile_assistant", sessionID = "reconcile_root", role = "assistant",
				time = { created = 1, completed = 2 }, finish = "stop" }, parts = {} },
		}, { complete = true })
		assert_eq(state.get_session_status("reconcile_root").type, "busy",
			"completed HTTP history must not infer idle for its session")
		assert_eq(state.get_session_status("reconcile_other").type, "busy",
			"completed HTTP history must not affect another session")
	end)
end)
