local state, sync = require("opencode.state"), require("opencode.sync")
local sessions, pending = require("opencode.session"), require("opencode.session.pending")
local bus, server = require("opencode.events.bus"), require("opencode.events.handlers.server")
local client, lifecycle = require("opencode.client"), require("opencode.lifecycle")
local permissions, forms = require("opencode.permission.state"), require("opencode.question.state")
local edits, actions = require("opencode.edit.state"), require("opencode.actions")
local projection = require("opencode.protocol.messages")

describe("native descendant lifecycle", function()
	local saved, requests, notices, closed
	local chain = { "root", "child", "grandchild" }
	local function seed(id, parent, runtime)
		state.upsert_session({ id = id, title = id, parentID = parent, directory = "/native-project" }, { touch = runtime == true })
	end
	local function seed_history(id)
		sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
		sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id, type = "text", text = id })
		state.set_session_message_cache(id, { count = 1, loaded = true })
		pending.begin({ session_id = id, message_id = id .. "-queued", status = "queued" })
		return pending.token(id)
	end
	local function form(id, sid)
		return { id = id, sessionID = sid, title = "Continue?", fields = { { key = "ok", type = "boolean" } } }
	end
	local function review(sid)
		return { protocolVersion = 2, reviewID = "review-" .. sid, revision = 1, sessionID = sid, status = "pending", created = 1000,
			location = { directory = "/native-project" }, files = { { fileID = "file", filePath = "/native-project/file", before = "", after = "new" } } }
	end
	local function launch(child)
		return { type = "assistant", time = { created = 1, completed = 3 }, content = {
			{ type = "tool", id = "launch", name = "subagent", time = { created = 1, ran = 2, completed = 3 },
				state = { status = "completed", input = { agent = "explore", prompt = "inspect" },
					metadata = { sessionID = child }, content = { { type = "text", text = "Done" } } } },
		} }
	end
	local function hydrate(sid, mid, native)
		local message = vim.deepcopy(native)
		message.id = mid
		local projected = projection.project(sid, message)
		sync.handle_session_messages(sid, { projected })
		return projected.parts[1].id
	end
	local function fork(sid, source, boundary)
		bus.emit("server_event", { id = "evt-" .. sid, type = "session.forked", created = 10,
			data = { sessionID = sid, parentID = source, boundary = { type = "after", messageID = boundary } } })
	end
	local function reduce_launch(sid, mid, child, call_id)
		call_id = call_id or "launch"
		local function event(kind, data, created)
			sync.handle_server_event({ id = "evt-" .. sid .. "-" .. created, type = "session." .. kind, created = created,
				data = vim.tbl_extend("force", { sessionID = sid, assistantMessageID = mid }, data) })
		end
		event("step.started", { started = 1, agent = "build", model = { providerID = "test", id = "model" } }, 1)
		event("tool.input.started", { id = call_id, name = "subagent" }, 2)
		event("tool.called", { id = call_id, input = { agent = "explore", prompt = "inspect" } }, 3)
		event("tool.success", { id = call_id, metadata = { sessionID = child }, content = { { type = "text", text = "Done" } } }, 4)
		event("step.ended", { finish = "tool-calls" }, 5)
		return projection.part_id(sid, mid, "tool", call_id)
	end
	before_each(function()
		bus.clear(); server.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all()
		saved = { client = {}, notify = vim.notify, defer = vim.defer_fn, ensure = lifecycle.ensure_connected,
			get_ids = state.get_session_ids, get_record = state.get_session_record }
		requests = { permissions = {}, forms = {}, reviews = {}, status = {} }
		notices, closed = {}, nil
		for _, method in ipairs({ "list_permissions", "list_questions", "review_rpc", "get_session_statuses", "get_messages", "delete_session" }) do saved.client[method] = client[method] end
		vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
		vim.defer_fn = function() return { stop = function() end, close = function() end } end
		lifecycle.ensure_connected = function(callback) callback() end
		client.list_permissions = function(opts, callback) requests.permissions[opts.session_id] = callback end
		client.list_questions = function(opts, callback) requests.forms[opts.session_id] = callback end
		client.review_rpc = function(method, params, _, callback)
			if method == "capabilities" then callback(nil, { protocolVersion = 2, review = true })
			elseif method == "policyList" then callback(nil, {})
			elseif method == "reviewList" then requests.reviews[params.sessionID] = callback end
		end
		client.get_session_statuses = function(callback) requests.status[#requests.status + 1] = callback end
		state.set_config({})
		seed("root", nil, true); seed("child", "root"); seed("grandchild", "child"); seed("unrelated")
		sessions.set_active("root", "Root", { preserve_cache = true })
		server.setup(bus)
		bus.on("session.closed", function(data) closed = data end)
		assert.same({ "root" }, state.get_runtime_session_order())
		assert.is_nil(sync.get_task_parent_session("child"))
		assert.is_nil(sync.get_task_parent_session("grandchild"))
	end)
	after_each(function()
		state.get_session_ids, state.get_session_record = saved.get_ids, saved.get_record
		for method, original in pairs(saved.client) do client[method] = original end
		vim.notify, vim.defer_fn, lifecycle.ensure_connected = saved.notify, saved.defer, saved.ensure
		bus.clear(); server.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all()
		require("opencode.ui.input.history").clear_session("grandchild")
	end)

	it("unions native and indexed task children once, deterministically and cycle-safely", function()
		seed("overridden", "root")
		sync.record_task_child_session("unrelated", "unrelated-task-message", "task", "overridden")
		sync.record_task_child_session("root", "root-task-message", "task", "task-only")
		sync.record_task_child_session("root", "root-task-message", "duplicate-task", "child")
		state.upsert_session({ id = "root", parentID = "grandchild" }, { touch = false })
		local scans = 0
		state.get_session_ids = function() scans = scans + 1; return saved.get_ids() end
		state.get_session_record = function() error("tree collection must not deepcopy session records") end
		assert.same({ "root", "child", "grandchild", "task-only" }, sync.collect_session_tree("root"))
		assert.equals(1, scans)
		assert.same({ "unrelated", "overridden" }, sync.collect_session_tree("unrelated"))
		assert.same({ "grandchild", "root", "child", "task-only" }, sync.collect_session_tree("grandchild"))
		assert.same({}, sync.collect_session_tree(nil))
	end)

	it("fetches native-only descendant permissions, forms and reviews on reconnect and refreshes their status", function()
		require("opencode.events.handlers.interactions").setup(bus)
		require("opencode.events.handlers.review").setup(bus)
		bus.emit("connected")
		for _, id in ipairs(chain) do
			assert.is_function(requests.permissions[id], "missing permission recovery for " .. id)
			assert.is_function(requests.forms[id], "missing form recovery for " .. id)
			assert.is_function(requests.reviews[id], "missing review recovery for " .. id)
		end
		assert.is_nil(requests.permissions.unrelated)
		assert.is_nil(requests.forms.unrelated)
		assert.is_nil(requests.reviews.unrelated)
		requests.permissions.grandchild(nil, { { id = "permission-grandchild", sessionID = "grandchild", action = "shell" } })
		requests.forms.grandchild(nil, { form("form-grandchild", "grandchild") })
		requests.reviews.grandchild(nil, { reviews = { review("grandchild") } })
		assert.is_not_nil(permissions.get_permission("permission-grandchild"))
		assert.is_not_nil(forms.get_question("form-grandchild"))
		assert.is_not_nil(edits.get_edit("review-grandchild"))
		sessions.recount_pending()
		assert.same({ permissions = 1, questions = 1, edits = 1 }, state.get_session_pending_counts("root"))
		assert.equals(1, #requests.status)
		requests.status[1](nil, { grandchild = { type = "busy" } })
		assert.equals("busy", state.get_session_status("grandchild").type)
		assert.equals("busy", sync.get_session_status("grandchild").type)
		assert.same({}, notices)
	end)

	it("closes through the native grandchild and invalidates the entire tree before late history returns", function()
		local tokens = {}
		for _, id in ipairs({ "root", "child", "grandchild", "unrelated" }) do tokens[id] = seed_history(id) end
		sessions.set_active("grandchild", "Grandchild", { runtime = false, preserve_cache = true })
		local history, published
		published = 0
		client.get_messages = function(_, _, callback) history = callback end
		require("tests.helpers.schedule").with(function(flush)
			actions.load_session_messages("grandchild", function() published = published + 1 end)
			assert.is_function(history)
			assert.is_true(sessions.close("grandchild", { silent = true }))
			assert.same(chain, closed.session_ids)
			assert.equals("root", closed.session_id)
			for _, id in ipairs(chain) do
				assert.same({}, sync.get_messages(id))
				assert.same({}, sync.get_parts(id .. "-message"))
				assert.is_false(pending.is_current(tokens[id]))
				assert.same({}, pending.list(id))
			end
			history(nil, { { info = { id = "late-grandchild", sessionID = "grandchild", role = "user" }, parts = {} } })
			flush()
			assert.equals(0, published)
			assert.same({}, sync.get_messages("grandchild"))
			assert.is_false(state.is_runtime_session("root"))
			assert.is_nil(state.get_session().id)
			assert.is_true(pending.is_current(tokens.unrelated))
			assert.equals("queued", pending.get("unrelated", "unrelated-queued").status)
			assert.equals(1, #sync.get_messages("unrelated"))
		end)
	end)

	it("deletes native-only descendant metadata, caches, drafts, interactions and pending tokens", function()
		local tokens = {}
		for _, id in ipairs({ "root", "child", "grandchild", "unrelated" }) do tokens[id] = seed_history(id) end
		permissions.add_permission("permission-grandchild", "grandchild", "shell", {})
		forms.add_form(form("form-grandchild", "grandchild"))
		edits.add_edit("review-grandchild", "grandchild", {}, { review_mode = "readonly" })
		local history = require("opencode.ui.input.history")
		history.set_pending("Grandchild draft", {}, "grandchild")
		bus.emit("server_event", { id = "evt-delete-root", type = "session.deleted", created = 2, data = { sessionID = "root" } })
		assert.same(chain, closed.session_ids)
		for _, id in ipairs(chain) do
			assert.is_nil(state.get_session_record(id))
			assert.same({ count = 0, loaded = false }, state.get_session_message_cache(id))
			assert.same({}, sync.get_messages(id))
			assert.same({}, sync.get_parts(id .. "-message"))
			assert.is_false(pending.is_current(tokens[id]))
			assert.same({}, pending.list(id))
		end
		assert.is_nil(permissions.get_permission("permission-grandchild"))
		assert.is_nil(forms.get_question("form-grandchild"))
		assert.is_nil(edits.get_edit("review-grandchild"))
		assert.equals("", history.get_pending("grandchild"))
		assert.is_true(pending.is_current(tokens.unrelated))
		assert.is_not_nil(state.get_session_record("unrelated"))
		assert.equals(1, #sync.get_messages("unrelated"))
	end)

	for _, stale in ipairs({ false, true }) do
		it("keeps a fork independent from its source during close and deletion (stale parent=" .. tostring(stale) .. ")", function()
			if stale then seed("fork", "root") end
			local boundary = { type = "after", messageID = "source-message" }
			bus.emit("server_event", { id = "evt-fork", type = "session.forked", created = 2,
				data = { sessionID = "fork", parentID = "root", boundary = boundary } })
			sessions.remember({ id = "fork", title = "Fork DTO without parentID" })
			local info = state.get_session_record("fork")
			assert.is_nil(info.parentID)
			assert.same({ sessionID = "root", boundary = boundary }, info.fork)
			seed("fork-child", "fork")
			local fork_token, child_token = seed_history("fork"), seed_history("fork-child")
			assert.same(chain, sync.collect_session_tree("root"))
			assert.same({ "fork", "fork-child" }, sync.collect_session_tree("fork"))
			assert.is_true(sessions.close("grandchild", { silent = true }))
			bus.emit("server_event", { id = "evt-delete-source", type = "session.deleted", created = 3, data = { sessionID = "root" } })
			for _, id in ipairs({ "fork", "fork-child" }) do
				assert.is_not_nil(state.get_session_record(id))
				assert.equals(1, #sync.get_messages(id))
				assert.equals("queued", pending.get(id, id .. "-queued").status)
			end
			assert.is_true(state.is_runtime_session("fork"))
			assert.same({ "fork" }, state.get_runtime_session_order())
			assert.is_true(pending.is_current(fork_token))
			assert.is_true(pending.is_current(child_token))
		end)
	end

	local orders = { { "source", "provenance", "copy" }, { "copy", "provenance", "source" } }
	for index, late_native in ipairs({ false, true }) do
		do
			local order = orders[index]
			it("retains source ownership and live work when deleting copied history: " .. table.concat(order, ",") .. ", late native=" .. tostring(late_native), function()
				if late_native then state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false }) end
				local child_token, grandchild_token = seed_history("child"), seed_history("grandchild")
				permissions.add_permission("source-permission", "child", "shell", {})
				local native, source_part, fork_part = launch("child")
				local operations = {
					source = function() source_part = hydrate("root", "source-launch", native) end,
					provenance = function() fork("fork", "root", "source-launch") end,
					-- Match projectFork: only the message/session identity changes, not tool data.
					copy = function() fork_part = hydrate("fork", "msg_fork_0", native) end,
				}
				for _, operation in ipairs(order) do operations[operation]() end
				assert.equals("root", sync.get_task_parent_session("child"))
				assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
				assert.equals("child", sync.get_task_child_session("source-launch", source_part))
				assert.equals("child", sync.get_task_child_session("msg_fork_0", fork_part))
				if late_native then state.upsert_session({ id = "child", parentID = "root" }, { touch = false }) end
				assert.same(chain, sync.collect_session_tree("root"))
				assert.same({ "fork" }, sync.collect_session_tree("fork"))
				assert.is_false(require("opencode.events.util").session_owns_task_child("fork", "child"))
				-- A fork can still launch a genuine new child of its own.
				seed("fork-child", "fork")
				local own_token = seed_history("fork-child")
				hydrate("fork", "new-launch", launch("fork-child"))
				assert.equals("fork", sync.get_task_parent_session("fork-child"))
				bus.emit("server_event", { id = "evt-delete-fork", type = "session.deleted", created = 20, data = { sessionID = "fork" } })
				assert.same({ "fork", "fork-child" }, closed.session_ids)
				for _, id in ipairs(chain) do assert.is_not_nil(state.get_session_record(id)) end
				assert.equals("child", sync.get_task_child_session("source-launch", source_part))
				assert.equals("root", sync.get_task_parent_session("child"))
				assert.equals(1, #sync.get_messages("child"))
				assert.equals(1, #sync.get_messages("grandchild"))
				assert.equals("queued", pending.get("child", "child-queued").status)
				assert.equals("queued", pending.get("grandchild", "grandchild-queued").status)
				assert.is_not_nil(permissions.get_permission("source-permission"))
				assert.is_true(pending.is_current(child_token))
				assert.is_true(pending.is_current(grandchild_token))
				assert.is_false(pending.is_current(own_token))
				assert.is_nil(state.get_session_record("fork-child"))
				assert.is_nil(sync.get_task_child_session("msg_fork_0", fork_part))
			end)
		end
	end

	it("repairs nested fork references when the intermediate fork provenance arrives last", function()
		local native = launch("child")
		local source_part = hydrate("root", "source-launch", native)
		hydrate("fork", "msg_fork_0", native)
		fork("nested-fork", "fork", "msg_fork_0")
		local nested_part = hydrate("nested-fork", "msg_nested_0", native)
		fork("fork", "root", "source-launch")
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
		assert.equals("child", sync.get_task_child_session("msg_nested_0", nested_part))
		for _, id in ipairs({ "fork", "nested-fork" }) do
			assert.same({ id }, sync.collect_session_tree(id))
			assert.is_true(sessions.handle_deleted(id))
		end
		assert.same(chain, sync.collect_session_tree("root"))
		assert.is_not_nil(state.get_session_record("child"))
	end)

	it("deletes a fork safely immediately after late DTO provenance without a prior ownership read", function()
		reduce_launch("root", "source-launch", "child")
		local token = seed_history("child")
		permissions.add_permission("source-permission", "child", "shell", {})
		hydrate("fork", "msg_fork_0", sync.get_message("root", "source-launch")._native)
		sessions.remember({ id = "fork", fork = { sessionID = "root", boundary = { type = "after", messageID = "source-launch" } } }, { touch = false })
		bus.emit("server_event", { id = "evt-delete-fork", type = "session.deleted", created = 20, data = { sessionID = "fork" } })
		assert.same({ "fork" }, closed.session_ids)
		assert.is_not_nil(state.get_session_record("child"))
		assert.equals(1, #sync.get_messages("child"))
		assert.is_not_nil(permissions.get_permission("source-permission"))
		assert.equals("queued", pending.get("child", "child-queued").status)
		assert.is_true(pending.is_current(token))
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same({ "child" }, sync.get_task_child_sessions("root"))
	end)

	it("keeps a child session's copied grandchild launch navigable without transferring ownership", function()
		local native = launch("grandchild")
		local source_part = hydrate("child", "child-launch", native)
		local copied_part = hydrate("child-fork", "msg_child_fork_0", native)
		fork("child-fork", "child", "child-launch")
		local token = seed_history("grandchild")
		assert.equals("child", sync.get_task_parent_session("grandchild"))
		assert.equals("grandchild", sync.get_task_child_session("child-launch", source_part))
		assert.equals("grandchild", sync.get_task_child_session("msg_child_fork_0", copied_part))
		assert.same({ "child-fork" }, sync.collect_session_tree("child-fork"))
		sync.clear_session_tree("child-fork")
		assert.is_true(sessions.handle_deleted("child-fork"))
		assert.is_true(pending.is_current(token))
		assert.equals(1, #sync.get_messages("grandchild"))
		assert.same(chain, sync.collect_session_tree("root"))
	end)

	it("preserves task-first genuine conflicts, revisions and explicit owner removal", function()
		local native = launch("child")
		local source_part = hydrate("root", "source-launch", native)
		local other_part = reduce_launch("unrelated", "other-launch", "child", "resume-child")
		assert.equals("unrelated", sync.get_task_parent_session("child"))
		assert.same({ "root" }, sync.collect_session_tree("root"))
		assert.same({ "unrelated", "child", "grandchild" }, sync.collect_session_tree("unrelated"))
		sync.handle_part_removed("other-launch", other_part)
		assert.is_nil(sync.get_task_parent_session("child"))
		hydrate("root", "source-launch", native)
		fork("fork", "root", "source-launch")
		local revision = sync.get_part_revision("source-launch", source_part)
		local copied_part = hydrate("fork", "msg_fork_0", native)
		local copied_revision = sync.get_part_revision("msg_fork_0", copied_part)
		assert.is_false(sync.record_task_child_session("fork", "msg_fork_0", copied_part, "child"))
		assert.equals(revision, sync.get_part_revision("source-launch", source_part))
		assert.equals(copied_revision, sync.get_part_revision("msg_fork_0", copied_part))
		sync.get_message_render_parts("msg_fork_0")
		sync.handle_part_removed("msg_fork_0", copied_part)
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.is_nil(sync.get_task_child_session("msg_fork_0", copied_part))
		assert.same({}, sync.get_message_render_parts("msg_fork_0").tool_parts)
		sync.handle_part_removed("source-launch", source_part)
		assert.is_nil(sync.get_task_parent_session("child"))
		assert.same(chain, sync.collect_session_tree("root"))
	end)

	for _, native_known in ipairs({ false, true }) do
		it("does not transfer a known task owner to copied history before fork metadata (native=" .. tostring(native_known) .. ")", function()
			if not native_known then state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false }) end
			local native = launch("child")
			-- Copy identities and timestamps are deliberately uninformative.
			local source_part = hydrate("root", "msg_fork_0", native)
			native.time.created = 0
			local copied_part = hydrate("unknown-copy", "ordinary-message", native)
			assert.equals("root", sync.get_task_parent_session("child"))
			assert.same({ "msg_fork_0", source_part }, { sync.get_task_child_owner("child") })
			assert.equals("child", sync.get_task_child_session("ordinary-message", copied_part))
			assert.same({ "unknown-copy" }, sync.collect_session_tree("unknown-copy"))
			fork("unknown-copy", "root", "msg_fork_0")
			assert.equals("root", sync.get_task_parent_session("child"))
		end)
	end

	it("defers an ambiguous fork claim and repairs late native metadata without reloading history", function()
		state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
		fork("fork", "root", "source-launch")
		local copied_part = hydrate("fork", "copied-launch", launch("child"))
		assert.equals("child", sync.get_task_child_session("copied-launch", copied_part))
		assert.is_nil(sync.get_task_parent_session("child"))
		local util = require("opencode.events.util")
		assert.is_false(util.session_owns_task_child("fork", "child"))
		assert.is_nil(util.render_target_session_id("fork", "child"))
		assert.is_false(util.permission_session_is_relevant("fork", "child"))
		state.upsert_session({ id = "child", parentID = "root" }, { touch = false })
		assert.is_nil(sync.get_task_parent_session("child"))
		assert.same(chain, sync.collect_session_tree("root"))
		assert.same({ "fork" }, sync.collect_session_tree("fork"))
		-- A different child really launched by this fork becomes owned once confirmed.
		hydrate("fork", "own-launch", launch("own-child"))
		assert.is_nil(sync.get_task_parent_session("own-child"))
		state.upsert_session({ id = "own-child", parentID = "fork" }, { touch = false })
		assert.equals("fork", sync.get_task_parent_session("own-child"))
		assert.same({ "fork", "own-child" }, sync.collect_session_tree("fork"))
	end)

	it("does not recover ownership from a copied pre-index task or a synthetic notification", function()
		local util = require("opencode.events.util")
		state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
		fork("fork", "root", "source-launch")
		local projected = projection.project("fork", vim.tbl_extend("force", launch("child"), { id = "copy" }))
		local part = projected.parts[1]
		part.sessionID = nil
		sync.handle_part_updated(part)
		sync.handle_message_updated(projected.info)
		assert.is_nil(sync.get_task_child_session("copy", part.id))
		assert.is_false(util.session_owns_task_child("fork", "child"))
		sync.handle_server_event({ id = "evt-notice", created = 20, type = "session.synthetic", data = {
			sessionID = "unrelated", text = "Done", metadata = { source = "subagent", state = "completed", childID = "notice-child" },
		} })
		assert.is_false(util.session_owns_task_child("unrelated", "notice-child"))
	end)

	it("reclassifies a deferred genuine task conflict after native metadata arrives without a history reload", function()
		state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
		reduce_launch("root", "first-launch", "child")
		local resumed = launch("child")
		resumed.content[1].id = "resume-child"
		local resumed_part = hydrate("unrelated", "resume-launch", resumed)
		assert.equals("root", sync.get_task_parent_session("child"), "incomplete metadata cannot reparent a known child")
		state.upsert_session({ id = "child", parentID = "unrelated" }, { touch = false })
		assert.equals("unrelated", sync.get_task_parent_session("child"), "native metadata confirms the deferred launch")
		assert.same({ "resume-launch", resumed_part }, { sync.get_task_child_owner("child") })
		assert.same({ "root" }, sync.collect_session_tree("root"))
		assert.same({ "unrelated", "child", "grandchild" }, sync.collect_session_tree("unrelated"))
	end)

	for _, late_native in ipairs({ false, true }) do
		it("preserves a native owner before source history or fork provenance is known (late native=" .. tostring(late_native) .. ")", function()
			if late_native then state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false }) end
			local token = seed_history("child")
			permissions.add_permission("source-permission", "child", "shell", {})
			local copied_part = hydrate("unknown-copy", "copy-launch", launch("child"))
			if late_native then state.upsert_session({ id = "child", parentID = "root" }, { touch = false }) end
			assert.is_nil(sync.get_task_parent_session("child"))
			assert.equals("child", sync.get_task_child_session("copy-launch", copied_part))
			assert.same(chain, sync.collect_session_tree("root"))
			assert.same({ "unknown-copy" }, sync.collect_session_tree("unknown-copy"))
			sessions.set_active("unknown-copy", "Fork awaiting metadata", { preserve_cache = true })
			assert.is_true(sessions.close("unknown-copy", { silent = true }))
			assert.same({ "unknown-copy" }, closed.session_ids)
			assert.equals(1, #sync.get_messages("child"))
			assert.is_true(pending.is_current(token))
			assert.is_not_nil(permissions.get_permission("source-permission"))
			fork("unknown-copy", "root", "source-launch")
			reduce_launch("root", "source-launch", "child")
			assert.equals("root", sync.get_task_parent_session("child"))
		end)
	end

	it("keeps task-first ownership for a genuine fork launch even when it reuses the copied tool ID", function()
		local source_part = reduce_launch("root", "source-launch", "child")
		fork("fork", "root", "source-launch")
		local copied_part = hydrate("fork", "copy-launch", sync.get_message("root", "source-launch")._native)
		local resumed_part = reduce_launch("fork", "resume-launch", "child")
		assert.equals("fork", sync.get_task_parent_session("child"))
		assert.same({ "resume-launch", resumed_part }, { sync.get_task_child_owner("child") })
		hydrate("fork", "copy-launch", sync.get_message("root", "source-launch")._native)
		assert.same({ "resume-launch", resumed_part }, { sync.get_task_child_owner("child") })
		sync.handle_server_event({ id = "evt-source-text", created = 20, type = "session.text.delta",
			data = { sessionID = "root", assistantMessageID = "source-launch", ordinal = 0, delta = "Source output" } })
		hydrate("root", "source-launch", sync.get_message("root", "source-launch")._native)
		assert.same({ "resume-launch", resumed_part }, { sync.get_task_child_owner("child") }, "source replay must not undo a real task launch")
		assert.equals("child", sync.get_task_child_session("source-launch", source_part))
		assert.equals("child", sync.get_task_child_session("copy-launch", copied_part))
		sync.handle_part_removed("resume-launch", resumed_part)
		assert.is_nil(sync.get_task_parent_session("child"), "removing the genuine owner must not revive a copied launch")
	end)

	it("does not mistake copied repeated launches of one child for a new conflicting task", function()
		local native = launch("child")
		local second = vim.deepcopy(native.content[1])
		second.id = "second-source-launch"
		native.content[#native.content + 1] = second
		hydrate("root", "source-launches", native)
		local source_owner = { sync.get_task_child_owner("child") }
		hydrate("fork", "copied-launches", native)
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same(source_owner, { sync.get_task_child_owner("child") })
		fork("fork", "root", "source-launches")
		sync.handle_server_event({ id = "evt-copied-text", created = 20, type = "session.text.delta",
			data = { sessionID = "fork", assistantMessageID = "copied-launches", ordinal = 0, delta = "More" } })
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same(source_owner, { sync.get_task_child_owner("child") })
		for _, part in ipairs(sync.get_message_tools("source-launches")) do
			assert.equals("child", sync.get_task_child_session("source-launches", part.id))
		end
		assert.same({ "fork" }, sync.collect_session_tree("fork"))
	end)

	for _, order in ipairs(orders) do
		it("closes only the fork tree and keeps a source child callback current: " .. table.concat(order, ","), function()
			state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
			local token = seed_history("child")
			permissions.add_permission("source-permission", "child", "shell", {})
			local source_part, copied_part
			local operations = {
				source = function() source_part = reduce_launch("root", "source-launch", "child") end,
				copy = function()
					local source = sync.get_message("root", "source-launch")
					copied_part = hydrate("fork", "copy-launch", source and source._native or launch("child"))
				end,
				provenance = function() fork("fork", "root", "source-launch") end,
			}
			for _, operation in ipairs(order) do operations[operation]() end
			state.upsert_session({ id = "child", parentID = "root" }, { touch = false })
			seed("fork-child", "fork")
			local own_token = seed_history("fork-child")
			hydrate("fork", "own-launch", launch("fork-child"))
			sessions.set_active("fork", "Fork", { preserve_cache = true })
			client.delete_session = function() error("closing a local tab must not delete a server session") end
			local history, published = nil, 0
			client.get_messages = function(id, _, callback)
				assert.equals("child", id)
				history = callback
			end
			require("tests.helpers.schedule").with(function(flush)
				actions.load_session_messages("child", function() published = published + 1 end)
				assert.is_function(history)
				assert.is_true(sessions.close("fork", { silent = true }))
				assert.same({ "fork", "fork-child" }, closed.session_ids)
				assert.is_not_nil(state.get_session_record("child"))
				assert.is_not_nil(state.get_session_record("fork-child"), "local close retains server metadata")
				assert.equals(1, #sync.get_messages("child"))
				assert.same({}, sync.get_messages("fork"))
				assert.same({}, sync.get_messages("fork-child"))
				assert.same({}, pending.list("fork-child"))
				assert.is_false(pending.is_current(own_token))
				assert.is_true(pending.is_current(token))
				assert.equals("queued", pending.get("child", "child-queued").status)
				assert.is_not_nil(permissions.get_permission("source-permission"))
				assert.equals("child", sync.get_task_child_session("source-launch", source_part))
				assert.is_nil(sync.get_task_child_session("copy-launch", copied_part))
				assert.same(chain, sync.collect_session_tree("root"))
				history(nil, projection.page("child", { { id = "late-source-child", type = "user", text = "Still current", time = { created = 2 } } }))
				flush()
				assert.equals(1, published)
				assert.equals(2, #sync.get_messages("child"))
				assert.equals("root", sync.get_task_parent_session("child"))
			end)
		end)
	end

	for _, mode in ipairs({ "close", "delete" }) do
		do
			local competing_source = mode == "delete"
			it("keeps unconfirmed copied descendants and their actual history callback through early " .. mode .. ", competing source=" .. tostring(competing_source), function()
				state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
				seed("fork", nil, true)
				local tokens = { child = seed_history("child"), grandchild = seed_history("grandchild"), fork = seed_history("fork") }
				permissions.add_permission("source-permission", "child", "shell", {})
				permissions.set_message("source-permission", "retain source note")
				forms.add_form(form("source-form", "child"))
				forms.select_option("source-form", 1)
				edits.add_edit("source-review", "child", {}, { review_mode = "readonly" })
				edits.set_message("source-review", "retain review note")
				local function interactions()
					return { permissions.get_permission("source-permission"), forms.get_question("source-form"), edits.get_edit("source-review") }
				end
				local kept = vim.deepcopy(interactions())
				local native = vim.tbl_extend("force", launch("child"), { id = "copy-launch" })
				sync.handle_session_messages("fork", projection.page("fork", { native }))
				local copied_part = projection.part_id("fork", "copy-launch", "tool", "launch")
				assert.equals("child", sync.get_task_child_session("copy-launch", copied_part))
				local source_part
				if competing_source then source_part = hydrate("root", "source-launch", native) end
				local history, published = nil, 0
				client.get_messages = function(id, _, callback) assert.equals("child", id); history = callback end
				client.delete_session = function() error("closing a local tab must not delete a server session") end
				require("tests.helpers.schedule").with(function(flush)
					actions.load_session_messages("child", function() published = published + 1 end)
					assert.is_function(history)
					if mode == "close" then assert.is_true(sessions.close("fork", { silent = true }))
					else bus.emit("server_event", { id = "evt-delete-fork", type = "session.deleted", created = 10, data = { sessionID = "fork" } }) end
					assert.same({ "fork" }, closed.session_ids, "settled history alone cannot authorize descendant cleanup")
					assert.same({}, sync.get_messages("fork"))
					assert.is_false(pending.is_current(tokens.fork))
					assert.same({}, pending.list("fork"))
					for _, id in ipairs({ "child", "grandchild" }) do
						assert.is_not_nil(state.get_session_record(id))
						assert.is_not_nil(sync.get_message(id, id .. "-message"))
						assert.is_true(pending.is_current(tokens[id]))
						assert.equals("queued", pending.get(id, id .. "-queued").status)
					end
					assert.same(kept, interactions())
					assert.is_nil(sync.get_task_child_session("copy-launch", copied_part))
					if source_part then assert.equals("child", sync.get_task_child_session("source-launch", source_part)) end
					-- Classification arriving after cleanup must not be needed to save data.
					sessions.remember({ id = "fork", fork = { sessionID = "root" } }, { touch = false })
					sessions.remember({ id = "child", parentID = "root" }, { touch = false })
					source_part = hydrate("root", "source-launch", native)
					assert.equals("root", sync.get_task_parent_session("child"))
					assert.equals("child", sync.get_task_child_session("source-launch", source_part))
					assert.same(chain, sync.collect_session_tree("root"))
					bus.emit("server_event", { id = "evt-child-after-delete", type = "session.text.delta", created = 15,
						data = { sessionID = "child", assistantMessageID = "still-alive", ordinal = 0, delta = "not tombstoned" } })
					assert.is_not_nil(sync.get_message("child", "still-alive"))
					history(nil, projection.page("child", { { id = "late-source-child", type = "user", text = "Still current", time = { created = 20 } } }))
					flush()
					assert.equals(1, published)
					assert.is_not_nil(sync.get_message("child", "late-source-child"))
					assert.is_true(pending.is_current(tokens.child))
					assert.equals("queued", pending.get("child", "child-queued").status)
					assert.same(kept, interactions())
				end)
			end)
		end

		it("cleans descendants of an observed task launch before any native or fork metadata on " .. mode, function()
			state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
			seed("fork", nil, true)
			hydrate("fork", "copied-launch", launch("child"))
			reduce_launch("fork", "real-launch", "child")
			local tokens = { child = seed_history("child"), grandchild = seed_history("grandchild") }
			assert.same({ "fork", "child", "grandchild" }, sync.collect_session_tree("fork"))
			if mode == "close" then assert.is_true(sessions.close("fork", { silent = true }))
			else bus.emit("server_event", { id = "evt-delete-fork", type = "session.deleted", created = 10, data = { sessionID = "fork" } }) end
			assert.same({ "fork", "child", "grandchild" }, closed.session_ids)
			for _, id in ipairs({ "child", "grandchild" }) do
				assert.same({}, sync.get_messages(id))
				assert.same({}, pending.list(id))
				assert.is_false(pending.is_current(tokens[id]))
			end
		end)
	end

	for _, mode in ipairs({ "sync", "action" }) do
		it("does not clear unconfirmed competing history descendants through the " .. mode .. " clear-tree boundary", function()
			state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
			local token = seed_history("child")
			seed_history("grandchild")
			local copied_part = hydrate("fork", "copy-launch", launch("child"))
			local source_part = hydrate("root", "source-launch", launch("child"))
			assert.equals("child", sync.get_task_child_session("copy-launch", copied_part))
			if mode == "sync" then sync.clear_session_tree("fork") else actions.clear_session_data("fork") end
			assert.same({}, sync.get_messages("fork"))
			assert.is_not_nil(sync.get_message("child", "child-message"))
			assert.is_not_nil(sync.get_message("grandchild", "grandchild-message"))
			assert.is_true(pending.is_current(token))
			assert.equals("child", sync.get_task_child_session("source-launch", source_part))
			sessions.remember({ id = "child", parentID = "root" }, { touch = false })
			assert.same(chain, sync.collect_session_tree("root"))
		end)
	end

	it("repairs a fork of a fork when both source history and intermediate provenance arrive after copied history", function()
		state.upsert_session({ id = "child", parentID = vim.NIL }, { touch = false })
		local nested_part = hydrate("nested", "nested-copy", launch("child"))
		fork("nested", "fork", "first-copy")
		hydrate("fork", "first-copy", launch("child"))
		local source_part = reduce_launch("root", "source-launch", "child")
		fork("fork", "root", "source-launch")
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
		assert.equals("child", sync.get_task_child_session("nested-copy", nested_part))
		assert.is_true(sessions.handle_deleted("fork"))
		assert.is_true(sessions.handle_deleted("nested"))
		assert.equals("root", sync.get_task_parent_session("child"))
		assert.same(chain, sync.collect_session_tree("root"))
	end)

	local function competing_claims()
		local source, other = launch("child"), launch("child")
		other.content[1].id = "other-call"
		local source_part = hydrate("root", "source-launch", source)
		local other_part = hydrate("unrelated", "other-launch", other)
		assert.equals("unrelated", sync.get_task_parent_session("child"))
		return source, source_part, other_part
	end
	local function child_work()
		return { metadata = state.get_session_record("child"), messages = sync.get_messages("child"),
			parts = sync.get_parts("child-message"), outbox = pending.list("child"),
			permission = permissions.get_permission("source-permission") }
	end
	local function seed_child_work()
		local token = seed_history("child")
		permissions.add_permission("source-permission", "child", "shell", {})
		permissions.set_message("source-permission", "keep this note")
		return token, vim.deepcopy(child_work())
	end

	it("keeps the latest genuine replay through inherited history and deletion of the former owner", function()
		local source, source_part = competing_claims()
		local token, before = seed_child_work()
		state.get_session_ids = function() error("ownership repair must remain child-local") end
		hydrate("root", "source-launch", source)
		assert.equals("root", sync.get_task_parent_session("child"))
		fork("fork", "root", "source-launch")
		local copied = hydrate("fork", "copied-launch", source)
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
		assert.equals("child", sync.get_task_child_session("copied-launch", copied))
		state.get_session_ids = saved.get_ids
		assert.same({ "unrelated" }, sync.collect_session_tree("unrelated"))
		assert.is_true(sessions.handle_deleted("unrelated"))
		assert.same(before, child_work())
		assert.is_true(pending.is_current(token))
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
	end)

	local withdrawals = {
		{ "remove-part", function(_, mid, part) sync.handle_part_removed(mid, part) end },
		{ "replace-child", function(_, mid, part)
			local replacement = vim.deepcopy(sync.get_part(mid, part))
			replacement.state.metadata.sessionID = "new-child"
			sync.handle_part_updated(replacement)
		end },
	}
	for _, withdrawal in ipairs(withdrawals) do
		for _, winning in ipairs({ true, false }) do
			it("retires only a winning claim on " .. withdrawal[1] .. " (winner=" .. tostring(winning) .. ")", function()
				local source, source_part, other_part = competing_claims()
				local token, before = seed_child_work()
				withdrawal[2](winning and "unrelated" or "root", winning and "other-launch" or "source-launch",
					winning and other_part or source_part)
				if winning then
					assert.is_nil(sync.get_task_parent_session("child"))
					assert.equals("child", sync.get_task_child_session("source-launch", source_part))
				else assert.same({ "other-launch", other_part }, { sync.get_task_child_owner("child") }) end
				fork("fork", "root", "source-launch")
				local copied = hydrate("fork", "copied-launch", source)
				assert.equals("child", sync.get_task_child_session("copied-launch", copied))
				if winning then assert.is_nil(sync.get_task_parent_session("child"))
				else assert.same({ "other-launch", other_part }, { sync.get_task_child_owner("child") }) end
				assert.same({ "fork" }, sync.collect_session_tree("fork"))
				assert.is_true(sessions.handle_deleted("fork"))
				assert.same(before, child_work())
				assert.is_true(pending.is_current(token))
				if winning then
					hydrate("root", "source-launch", source)
					assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") }, "genuine replay reactivates ownership")
					assert.same(chain, sync.collect_session_tree("root"))
				end
			end)
		end
	end

	it("repairs late fork provenance without retiring the genuine source claim", function()
		local _, source_part, other_part = competing_claims()
		fork("unrelated", "root", "source-launch")
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
		assert.equals("child", sync.get_task_child_session("other-launch", other_part))
		sync.handle_part_removed("other-launch", other_part)
		assert.same({ "source-launch", source_part }, { sync.get_task_child_owner("child") })
		assert.same(chain, sync.collect_session_tree("root"))
	end)
end)
