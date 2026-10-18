local state, sync = require("opencode.state"), require("opencode.sync")
local sessions, pending = require("opencode.session"), require("opencode.session.pending")
local permissions, forms = require("opencode.permission.state"), require("opencode.question.state")
local edits, history = require("opencode.edit.state"), require("opencode.ui.input.history")
local views, bus = require("opencode.ui.chat.state"), require("opencode.events.bus")
local server, client = require("opencode.events.handlers.server"), require("opencode.client")

describe("local tab close descendant interactions", function()
	local saved, writes, errors, closed, retained
	local ids = { "source", "source-child", "fork", "own-child", "own-grandchild" }
	local own_tree = { "fork", "own-child", "own-grandchild" }
	local methods = { "delete_session", "respond_permission", "reply_to_question", "reject_question", "review_rpc" }
	local function seed(id, parent, runtime)
		state.upsert_session({ id = id, title = id, parentID = parent }, { touch = runtime == true })
		sync.handle_message_updated({ id = id .. "-message", sessionID = id, role = "assistant", time = { created = 1 } })
		sync.handle_part_updated({ id = id .. "-text", messageID = id .. "-message", sessionID = id, type = "text", text = id })
		permissions.add_permission(id .. "-permission", id, "shell", {})
		permissions.set_message(id .. "-permission", id .. " permission note")
		assert.is_true(permissions.select_option(id .. "-permission", 2))
		forms.add_form({ id = id .. "-form", sessionID = id,
			fields = { { key = "continue", type = "boolean" }, { key = "note", type = "string" } } })
		assert.is_true(forms.select_option(id .. "-form", 2))
		assert.is_true(forms.set_custom_input(id .. "-form", 2, id .. " form note"))
		edits.add_edit(id .. "-review", id, {
			{ fileID = "one", filePath = "/local-close/" .. id .. "-one", before = "before", after = "after" },
			{ fileID = "two", filePath = "/local-close/" .. id .. "-two", before = "before", after = "after" },
		}, { transport = "review_rpc", review_id = id .. "-review", revision = 1 })
		edits.set_message(id .. "-review", id .. " review note")
		assert.is_true(edits.set_selection(id .. "-review", 2))
		history.set_pending(id .. " draft", { { type = "file", name = id .. ".txt" } }, id)
		history.set_pending_options({ mode = "normal" }, id)
		history.set_pending_cursor(3, id)
		history.defer_pending({ text = id .. " deferred note", parts = {} }, id)
		pending.begin({ session_id = id, message_id = id .. "-queued", status = "queued" })
	end
	local function interactions(id)
		return { permission = vim.deepcopy(permissions.get_permission(id .. "-permission")),
			form = vim.deepcopy(forms.get_question(id .. "-form")), review = vim.deepcopy(edits.get_edit(id .. "-review")) }
	end
	local function assert_draft(id)
		assert.equals(id .. " draft", history.get_pending(id))
		assert.same({ { type = "file", name = id .. ".txt" } }, history.get_pending_parts(id))
		assert.same({ mode = "normal" }, history.get_pending_options(id))
		assert.equals(3, history.get_pending_cursor(id))
		assert.same({ text = id .. " deferred note", parts = {} }, history.peek_deferred(id))
	end
	local function capture()
		local result = {}
		for _, id in ipairs(ids) do
			result[id] = { interactions = interactions(id), metadata = state.get_session_record(id),
				messages = vim.deepcopy(sync.get_messages(id)), parts = vim.deepcopy(sync.get_parts(id .. "-message")),
				pending = pending.list(id), token = pending.token(id) }
		end
		return result
	end
	local function assert_live(id, before)
		assert.same(before.interactions, interactions(id))
		assert.same(before.metadata, state.get_session_record(id))
		assert.same(before.messages, sync.get_messages(id))
		assert.same(before.parts, sync.get_parts(id .. "-message"))
		assert.same(before.pending, pending.list(id))
		assert.is_true(pending.is_current(before.token))
		assert_draft(id)
	end
	before_each(function()
		bus.clear(); server.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all()
		state.set_config({ server = { shared_filesystem = false } })
		saved, writes, errors, closed, retained = { notify = vim.notify, client = {} }, {}, {}, nil, nil
		vim.notify = function(message, level)
			if level == vim.log.levels.ERROR then errors[#errors + 1] = message end
		end
		for _, method in ipairs(methods) do
			saved.client[method] = client[method]
			client[method] = function() writes[#writes + 1] = method end
		end
		server.setup(bus)
		bus.on("session.closed", function(data) closed = data.session_ids end)
		seed("source", nil, true); seed("source-child", "source")
		seed("fork", nil, true); seed("own-child", "fork"); seed("own-grandchild", "own-child")
		state.upsert_session({ id = "fork", fork = { sessionID = "source" } }, { touch = false })
		state.set_session("source", "Source")
	end)
	after_each(function()
		for method, original in pairs(saved.client) do client[method] = original end
		vim.notify = saved.notify
		if retained then
			for _, mod in pairs(retained.modules or {}) do if mod.dispose then mod.dispose() end end
			views.remove(retained)
		end
		for _, id in ipairs(ids) do history.clear_session(id) end
		bus.clear(); server.clear(); state.reset(); sync.clear_all(); pending.clear_all()
		permissions.clear_all(); forms.clear_all(); edits.clear_all()
	end)

	it("preserves root and descendant interaction notes and selections across local close and reopen", function()
		assert.is_true(forms.set_confirming("own-grandchild-form"))
		local before = capture()
		assert.same(own_tree, sync.collect_session_tree("fork"))
		assert.is_true(sessions.close("fork", { silent = true }))
		assert.same(own_tree, closed)
		assert.is_false(state.is_runtime_session("fork"))
		for _, id in ipairs(own_tree) do
			assert.same(before[id].interactions, interactions(id))
			assert.same({}, sync.get_messages(id))
			assert.same({}, sync.get_parts(id .. "-message"))
			assert.same({}, pending.list(id))
			assert.is_false(pending.is_current(before[id].token))
			assert.is_not_nil(state.get_session_record(id))
			assert_draft(id)
		end
		for _, id in ipairs({ "source", "source-child" }) do assert_live(id, before[id]) end

		sessions.set_active("fork", "Fork", { preserve_cache = true })
		sessions.recount_pending()
		assert.is_true(state.is_runtime_session("fork"))
		assert.same({ permissions = 3, questions = 3, edits = 3 }, state.get_session_pending_counts("fork"))
		for _, id in ipairs(own_tree) do
			assert.same(before[id].interactions, interactions(id))
			assert.same({ continue = false, note = id .. " form note" }, forms.get_answers(id .. "-form"))
			assert_draft(id)
		end
		assert.same({}, writes)
		assert.same({}, errors)
	end)

	for _, locally_closed in ipairs({ false, true }) do
		it("clears only the server-deleted tree's interactions and notes (locally closed=" .. tostring(locally_closed) .. ")", function()
			assert.is_true(forms.set_confirming("own-grandchild-form"))
			local before = capture()
			if locally_closed then
				assert.is_true(sessions.close("fork", { silent = true }))
				for _, id in ipairs(own_tree) do assert.same(before[id].interactions, interactions(id)) end
			end
			local tokens = {}
			for _, id in ipairs(own_tree) do tokens[id] = pending.token(id) end
			bus.emit("server_event", { id = "delete-fork", type = "session.deleted", created = 2, data = { sessionID = "fork" } })
			assert.same(own_tree, closed)
			for _, id in ipairs(own_tree) do
				assert.is_nil(permissions.get_permission(id .. "-permission"))
				assert.is_nil(forms.get_question(id .. "-form"))
				assert.is_nil(edits.get_edit(id .. "-review"))
				assert.is_nil(state.get_session_record(id))
				assert.same({}, sync.get_messages(id))
				assert.same({}, sync.get_parts(id .. "-message"))
				assert.same({}, pending.list(id))
				assert.is_false(pending.is_current(tokens[id]))
				assert.equals("", history.get_pending(id))
				assert.same({}, history.get_pending_parts(id))
				assert.is_nil(history.get_pending_options(id))
				assert.is_nil(history.get_pending_cursor(id))
				assert.is_nil(history.peek_deferred(id))
			end
			for _, id in ipairs({ "source", "source-child" }) do assert_live(id, before[id]) end
			assert.same({}, writes)
			assert.same({}, errors)
		end)
	end

	for _, suspended in ipairs({ false, true }) do
		it("keeps a separately owned descendant's live work and notes on local close (suspended=" .. tostring(suspended) .. ")", function()
			state.upsert_session({ id = "own-child" }, { touch = true })
			retained = views.new()
			retained.session_id, retained.config = "own-child", { layout = "tab" }
			retained.visible, retained.suspended = not suspended, suspended
			assert.is_true(forms.set_confirming("own-grandchild-form"))
			local before = capture()
			assert.is_true(sessions.close("fork", { silent = true }))
			assert.same({ "fork" }, closed)
			assert.same(before.fork.interactions, interactions("fork"))
			assert_draft("fork")
			for _, id in ipairs({ "source", "source-child", "own-child", "own-grandchild" }) do
				assert_live(id, before[id])
			end
			assert.same({}, writes)
			assert.same({}, errors)
		end)
	end
end)
