-- Behavioral state ownership checks. Each case gets fresh application modules.
-- Run with: ./tests/run.sh tests/checks/state_ownership_spec.lua
-- Navigation preserve_cache coverage lives in tests/unit/session_store_spec.lua.

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
		local handler = package.loaded["opencode.events.handlers.server"]
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
		bus.emit("server_event", { id = id, type = kind,
			data = vim.tbl_extend("force", { sessionID = sid }, data or {}), created = 10 })
	end

	it("keeps store loading and mutations independent from the event facade", function()
		assert.equals(nil, package.loaded["opencode.events"], "stores should not load event facade")

		permission_state.add_permission("perm_store", "session_a", "bash", {})
		permission_state.select_option("perm_store", 2)
		add_form("question_store", "session_a", "Pick")
		question_state.select_option("question_store", 1)
		edit_state.add_edit("edit_store", "session_a", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		assert.equals(nil, package.loaded["opencode.events"], "store mutations should not load event facade")
		assert.equals(0, #bus.get_history(), "store mutations should not emit events")
	end)

	it("forwards config changes through the state bridge", function()
		require("opencode.events.state_bridge").setup(bus)
		local config_change_count = 0
		bus.on("config_change", function() config_change_count = config_change_count + 1 end)
		state.set_config({ bridge_test = true })
		assert.equals(1, config_change_count, "state config changes should cross the state/event bridge")
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
		assert.equals("p1", selected.model.providerID, "opts model provider should win")
		assert.equals("m1", selected.model.modelID, "opts model id should win")
		assert.equals("Code", selected.agent, "opts agent should win")
		assert.equals("fast", selected.variant, "opts variant should win")

		local fallback = selectors.send_selection({
			model = { providerID = "missing", modelID = "nope" },
		})
		assert.equals("p2", fallback.model.providerID, "invalid opts model should fall back to local provider")
		assert.equals("m2", fallback.model.modelID, "invalid opts model should fall back to local model")
		assert.equals("plan", fallback.agent, "local agent should be selected")
		assert.equals("p2", selectors.current_model().providerID, "selectors should expose local provider selection")
		assert.equals("m2", selectors.current_model().modelID, "selectors should expose local model selection")
		assert.equals("Plan", selectors.current_agent().name, "selectors should expose local agent selection")
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
		assert.equals("sync-provider", sync.get_providers()[1].id, "initial sync should store providers")
		assert.equals("sync-model", sync.get_provider_defaults()["sync-provider"], "initial sync should store provider defaults")
		assert.equals("Sync Agent", sync.get_agents()[1].name, "initial sync should store agents")
		assert.equals("sync-model", sync.get_config().model, "initial sync should store config")
		assert.is_truthy(sync.get_commands().sync_command ~= nil, "initial sync should store commands")
		assert.equals("sync-skill", sync.get_skills()[1].name, "initial sync should store skills")
		assert.equals("connected", sync.get_mcp().servers.sync.status, "initial sync should store MCP status")
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
		assert.is_truthy(local_notices[1].content:find("Failed to fetch providers: providers failed", 1, true) ~= nil, "initial sync local notice should include the failing fetch")
		assert.equals(0, loaded.providers, "failed providers fetch should not emit providers_loaded")
		assert.equals("Agent After Failure", sync.get_agents()[1].name, "agents should still load after provider failure")
		assert.is_truthy(sync.get_commands().failure_command ~= nil, "config commands should still load after provider failure")
		assert.equals("skill-after-failure", sync.get_skills()[1].name, "skills should still load after provider failure")
		for index = notification_baseline + 1, #notifications do
			assert.is_truthy(notifications[index].message:find("mcp failed quietly", 1, true) == nil, "MCP initial sync errors should remain quiet")
		end
	end)

	it("does not append logs when reading the same model fallback", function()
		seed_catalog()
		local logger = require("opencode.logger")
		sync.handle_provider_defaults({ p1 = "m1" })
		local_state.agent.set("Code")
		logger.clear()
		local fallback_current = local_state.model.current()
		assert.equals("p1", fallback_current.providerID, "fallback provider default should be selected")
		assert.equals("m1", fallback_current.modelID, "fallback provider default model should be selected")
		local first_log_count = logger.count()
		local_state.model.current()
		assert.equals(first_log_count, logger.count(), "unchanged model selection reads should not append logs")
	end)

	it("mirrors native execution status without inferring idle from history", function()
		session_actions.set_active("session_status", "Status Session", { preserve_cache = true })
		state.upsert_session({ id = "history_other", title = "Other busy session" }, { touch = false })
		session_actions.set_session_status("history_other", { type = "busy" }, { reason = "test_busy" })
		require("opencode.events.handlers.server").setup(bus)
		emit_native("session.execution.started", "session_status", "evt-status-start")
		wait_for(function() return state.get_status() == "streaming" end,
			"native execution start should set streaming")

		sync.handle_session_messages("session_status", {
			{ info = { id = "completed_step", sessionID = "session_status", role = "assistant",
				time = { created = 1, completed = 2 }, finish = "stop" }, parts = {} },
		}, { complete = true })
		assert.equals("busy", state.get_session_status("session_status").type, "completed assistant snapshot alone should not infer idle")
		assert.equals("busy", state.get_session_status("history_other").type, "completed HTTP history must not affect another session")
		emit_native("session.execution.succeeded", "session_status", "evt-status-stop")
		wait_for(function() return state.get_status() == "idle" end,
			"native execution success should set idle")
	end)

	it("idles only the session addressed by a terminal event", function()
		require("opencode.events.handlers.server").setup(bus)
		sync.clear_all()
		state.set_session("running_root", "Running Root")
		state.set_session("complete_root", "Complete Root")
		session_actions.set_session_status("running_root", { type = "busy" }, { reason = "test_busy" })
		session_actions.set_session_status("complete_root", { type = "busy" }, { reason = "test_busy" })
		emit_native("session.execution.succeeded", "complete_root", "evt-complete-root")
		wait_for(function() return state.get_session_status("complete_root").type == "idle" end,
			"native terminal event should idle only its owning session")
		assert.equals("busy", state.get_session_status("running_root").type, "unrelated running session should stay busy")
	end)

	it("exposes read-only session views with defensive copies", function()
		session_actions.set_active("view_root", "View Root", { preserve_cache = true })
		session_actions.set_session_status("view_root", { type = "retry", attempt = 2 }, { reason = "test_view" })
		state.set_session_pending_counts("view_root", { questions = 1, edits = 1 })
		state.set_session_message_cache("view_root", { count = 3, loaded = true })
		local view = selectors.get_current_session_view()
		assert.is_truthy(view ~= nil, "current session selector should return a view")
		assert.equals("SessionView", getmetatable(view), "selector session result should be a SessionView")
		assert.equals("view_root", view.id, "SessionView should expose scalar id")
		assert.equals("retry #2", view:status_label(), "SessionView should format retry status labels")
		assert.equals(2, view:pending_total(), "SessionView pending total should include questions and edits")
		assert.equals(3, view:message_count(), "SessionView message count should use fresh message cache")
		local pending_copy = view.pending
		pending_copy.questions = 99
		assert.equals(1, view.pending.questions, "SessionView pending table reads should be defensive copies")
		local cache_copy = view.cached_messages
		cache_copy.count = 99
		assert.equals(3, view.cached_messages.count, "SessionView cache reads should be defensive copies")
		local record_copy = view.record
		record_copy.name = "Mutated"
		assert.equals("View Root", view.name, "SessionView record reads should be defensive copies")
		local assign_ok = pcall(function()
			view.name = "Mutated"
		end)
		assert.is_truthy(not assign_ok, "SessionView direct assignment should fail")
		local active_views = selectors.get_active_session_views()
		assert.equals("SessionView", getmetatable(active_views[1]), "active session selector should return SessionViews")
		assert.equals(3, active_views[1]:message_count(), "active SessionView should expose fresh cache count")
		local snapshot = state.get_full_state()
		assert.equals(nil, getmetatable(snapshot.sessions.by_id.view_root), "state session records should stay plain tables")
	end)

	it("rolls pending interactions up to their owning runtime root", function()
		state.set_session("permission_waiting", "Permission Waiting")
		state.set_session("permission_idle", "Permission Idle")
		permission_state.add_permission("perm_waiting_root", "permission_waiting", "bash", {})
		session_actions.recount_pending()
		assert.equals(1, state.get_session_pending_counts("permission_waiting").permissions, "root permission should count only on owning session")
		assert.equals(0, state.get_session_pending_counts("permission_idle").permissions, "unrelated session should not inherit root permission count")

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
		assert.equals(2, state.get_session_pending_counts("permission_waiting").permissions, "child permission should roll up only to owning root session")
		assert.equals(1, state.get_session_pending_counts("permission_idle").permissions, "unrelated root permission should remain isolated")
		add_form("question_waiting_child", "permission_child", "Continue?")
		edit_state.add_edit("edit_waiting_root", "permission_waiting", {
			{ filePath = "README.md", before = "a", after = "b" },
		}, { review_mode = "readonly" })
		session_actions.recount_pending()
		assert.equals(1, state.get_session_pending_counts("permission_waiting").questions, "child questions should roll up to owning root session")
		assert.equals(1, state.get_session_pending_counts("permission_waiting").edits, "root edits should count on owning root session")
		assert.equals(0, state.get_session_pending_counts("permission_idle").questions, "unrelated root should not inherit child question count")
	end)

	it("decodes native permission identity and rejects incomplete payloads", function()
		local request = require("opencode.events.handlers.permission_flow.request")
		local decoded = assert(request.decode({
			id = "decoder_wire", action = "shell", sessionID = "visible_session",
			source = { type = "tool", messageID = "decoder_message", callID = "decoder_call" },
			resources = { "*.lua" }, time = { created = 1000 },
		}))
		assert.equals("decoder_wire", decoded.id, "decoder should accept native request id")
		assert.equals("shell", decoded.type, "decoder should accept native action")
		assert.equals("visible_session", decoded.session_id, "decoder should accept native session id")
		assert.equals("decoder_message", decoded.message_id, "decoder should accept native source message id")
		assert.equals("decoder_call", decoded.call_id, "decoder should accept native source callID")
		assert.equals("*.lua", decoded.patterns[1], "decoder should preserve native resource patterns")
		assert.equals(nil, request.decode({ action = "shell", sessionID = "visible_session" }), "decoder should reject missing request id")
		assert.equals(nil, request.decode({ id = "missing_session", action = "shell" }), "decoder should reject missing session id")
	end)

	it("retains native permissions and forms only for relevant runtime sessions", function()
		session_actions.set_active("other_session", "Other Session", { preserve_cache = true })
		session_actions.set_active("visible_session", "Visible Session", { preserve_cache = true })
		require("opencode.events.handlers.interactions").setup(bus)
		sync.handle_message_updated({ id = "permission_tool_message", sessionID = "visible_session",
			role = "assistant", time = { created = 1 } })
		sync.handle_part_updated({ id = "permission_tool_part", messageID = "permission_tool_message",
			sessionID = "visible_session", type = "tool", tool = "bash", callID = "tool_call",
			state = { input = { command = "from sync" } } })
		bus.emit("server_interaction", { id = "evt-permission-visible", type = "permission.asked",
			data = { id = "perm_visible_session", action = "shell", sessionID = "visible_session",
				source = { type = "tool", messageID = "permission_tool_message", callID = "tool_call" },
				metadata = { input = { command = "from metadata" } } }, created = 1000 })
		wait_for(function() return permission_state.has_permission("perm_visible_session") end,
			"native permission in visible session should be tracked")
		assert.equals("from sync", permission_state.get_permission("perm_visible_session").tool_input.command, "native permission should prefer synchronized tool input")

		bus.emit("server_interaction", { id = "evt-permission-other", type = "permission.asked",
			data = { id = "perm_other_session", action = "shell", sessionID = "other_session",
				metadata = { input = { command = "other" } } }, created = 1001 })
		wait_for(function() return permission_state.has_permission("perm_other_session") end,
			"permission in another runtime tab should remain independently tracked")
		bus.emit("server_interaction", { id = "evt-permission-foreign", type = "permission.asked",
			data = { id = "perm_foreign", action = "shell", sessionID = "foreign_session" }, created = 1002 })
		assert.is_truthy(not permission_state.has_permission("perm_foreign"), "permission outside runtime sessions should be ignored")

		local function emit_form(id, sid)
			bus.emit("server_interaction", { id = "evt-" .. id, type = "form.created", created = 1003,
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



	it("closes a child through its root without resolving pending permissions", function()
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
		assert.equals("session_close_a", sync.get_task_parent_session("session_close_child"), "task child index should record the parent before close")

		permission_state.add_permission("close_perm_a", "session_close_a", "bash", {})
		permission_state.add_permission("close_perm_child", "session_close_child", "bash", {})
		permission_state.add_permission("close_perm_other", "session_close_b", "bash", {})
		assert.is_truthy(session_actions.close("session_close_child", { silent = true }), "session.close should resolve a child session to its runtime root")
		assert.is_truthy(not state.is_runtime_session("session_close_a"), "closing a child should remove its root tab")
		assert.is_truthy(state.is_runtime_session("session_close_b"), "closing a child should preserve another tab")
		assert.equals(0, #close_replies, "closing a tab should not reply to native permissions")
		assert.equals("pending", permission_state.get_permission("close_perm_a").status, "root permission should stay pending")
		assert.equals("pending", permission_state.get_permission("close_perm_child").status, "child permission should stay pending")
		assert.equals("pending", permission_state.get_permission("close_perm_other").status, "other permission should stay pending")

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

		assert.is_truthy(not history_has("permission_rejected", "close_perm_a"), "closing should not emit a root permission rejection")
		assert.is_truthy(not history_has("permission_removed", "close_perm_a"), "closing should not remove a root permission")
		assert.is_truthy(not history_has("permission_rejected", "close_perm_child"), "closing should not emit a child permission rejection")
		assert.is_truthy(not history_has("permission_removed", "close_perm_child"), "closing should not remove a child permission")
	end)

	it("preserves pending interactions when closing and reopening a root tab", function()
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
		client.reject_question = function(session_id, request_id, callback)
			table.insert(rejected_questions, {
				session_id = session_id,
				request_id = request_id,
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

		assert.is_truthy(session_actions.close("close_root", { silent = true }) == true, "close should remove target runtime tab")
		assert.is_truthy(permission_state.has_permission("perm_close_root"), "close should preserve root permission")
		assert.is_truthy(permission_state.has_permission("perm_close_child"), "close should preserve child permission")
		assert.is_truthy(permission_state.has_permission("perm_keep_root"), "close should preserve unrelated permission")
		assert.is_truthy(question_state.has_question("question_close_root"), "close should preserve root question")
		assert.is_truthy(question_state.has_question("question_close_child"), "close should preserve child question")
		assert.is_truthy(question_state.has_question("question_keep_root"), "close should preserve unrelated question")
		assert.is_truthy(edit_state.get_edit("edit_close_root") ~= nil, "close should preserve root edit")
		assert.is_truthy(edit_state.get_edit("edit_close_child") ~= nil, "close should preserve child edit")
		assert.is_truthy(edit_state.get_edit("edit_keep_root") ~= nil, "close should preserve unrelated edit")
		assert.equals(0, #rejected_permissions, "close should not reject native permissions")
		assert.equals(0, #rejected_questions, "close should not reject native forms")

		local recovered = {}
		for _, kind in ipairs({ "interaction_reconcile", "review_reconcile" }) do
			bus.on(kind, function(data) recovered[kind] = data.session_id end)
		end
		client.get_messages = function(session_id, _, callback)
			assert.equals("close_root", session_id, "reopen should load the closed root")
			callback(nil, { {
				info = { id = "close_root_assistant", sessionID = "close_root", role = "assistant", time = { created = 1 } },
				parts = { { id = "close_root_task", messageID = "close_root_assistant", sessionID = "close_root",
					type = "tool", tool = "task", metadata = { sessionId = "close_child" } } },
			} })
		end
		client.get_session_statuses = function(callback) callback(nil, {}) end
		session_actions.switch_to({ id = "close_root", title = "Close Root", directory = close_root_directory })
		wait_for(function()
			return sync.get_task_parent_session("close_child") == "close_root"
				and state.get_session_pending_counts("close_root").permissions == 2
				and state.get_session_pending_counts("close_root").questions == 2
		end, "reopening should restore child links and pending counts after history loads")
		assert.equals("close_child", recovered.interaction_reconcile, "reopen should refresh child interactions")
		assert.equals("close_child", recovered.review_reconcile, "reopen should refresh child reviews")
		assert.is_truthy(state.is_runtime_session("close_root"), "switching to a closed session should reopen its tab")
		assert.equals("pending", permission_state.get_permission("perm_close_root").status, "reopened root permission remains pending")
		assert.equals("pending", permission_state.get_permission("perm_close_child").status, "reopened child permission remains pending")
		assert.equals("pending", question_state.get_question("question_close_root").status, "reopened root form remains pending")
		assert.equals("pending", question_state.get_question("question_close_child").status, "reopened child form remains pending")
		assert.is_truthy(edit_state.get_edit("edit_close_root") ~= nil, "reopened root edit remains available")
		assert.is_truthy(edit_state.get_edit("edit_close_child") ~= nil, "reopened child edit remains available")
		local chat = require("opencode.ui.chat")
		chat.create()
		assert.is_truthy(table.concat(chat.render(), "\n"):find("Close root%?") ~= nil, "reopening should render the still-pending root form")
		assert.equals(0, #rejected_permissions, "reopening should not reject native permissions")
		assert.equals(0, #rejected_questions, "reopening should not reject native forms")
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
		require("opencode.events.handlers.interactions").setup(bus)
		require("tests.helpers.schedule").with(function(flush)
			bus.emit("server_interaction", { id = "evt-danger-missing", type = "permission.asked", data = {
				id = "danger_missing_session",
				action = "shell",
			}, created = 1000 })
			flush()
			assert.equals(0, #replies, "danger mode should not auto-reply to permission without session identity")
			assert.is_truthy(not permission_state.has_permission("danger_missing_session"), "danger mode should drop permission without session identity")
		end)

		bus.emit("server_interaction", { id = "evt-danger-perm", type = "permission.asked", data = {
			id = "danger_perm",
			action = "shell",
			sessionID = "session_hidden",
		}, created = 1001 })
		wait_for(function()
			return #replies == 1
		end, "danger mode should auto-reply to permission requests")
		assert.equals("danger_perm", replies[1].permission_id, "danger mode reply should target permission")
		assert.equals("once", replies[1].reply, "danger mode should use one-shot approval")
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
		assert.equals(replies_before_cleanup + 1, #replies, "danger approval should queue before cleanup")
		require("opencode.cleanup").reset_all()
		assert.equals(0, #sync.get_messages("cleanup_session"), "cleanup should clear sync messages")
		assert.is_truthy(not permission_state.has_permission("cleanup_perm"), "cleanup should clear permissions")
		assert.is_truthy(not question_state.has_question("cleanup_question"), "cleanup should clear questions")
		assert.equals(nil, edit_state.get_edit("cleanup_edit"), "cleanup should clear edits")
		assert.equals(0, #cleanup_chat_state.local_notices, "cleanup should clear chat local notices")
		danger.approve("cleanup_danger")
		assert.equals(replies_before_cleanup + 2, #replies, "cleanup should clear danger reply dedupe")
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
		assert.is_truthy(rendered_file_result ~= nil, "file edit result should render")
		assert.is_truthy(#rendered_file_result.lines > 1, "file edit result should wrap long panel text")
		for _, line_text in ipairs(rendered_file_result.lines) do
			assert.equals("▏  ", line_text:sub(1, #"▏  "), "file edit result lines should use panel prefix")
		end
		local has_diff_add = false
		local has_diff_delete = false
		for _, hl in ipairs(rendered_file_result.highlights) do
			has_diff_add = has_diff_add or hl.hl_group == "DiffAdd"
			has_diff_delete = has_diff_delete or hl.hl_group == "DiffDelete"
		end
		assert.is_truthy(has_diff_add, "file edit result should highlight additions")
		assert.is_truthy(has_diff_delete, "file edit result should highlight deletions")
	end)
end)
