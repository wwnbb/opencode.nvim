-- Admission, correlation, selection and session ownership checks.
local state = require("opencode.state")
local sync = require("opencode.sync")
local pending = require("opencode.session.pending")
local history = require("opencode.ui.input.history")
local selectors = require("opencode.selectors")

describe("opencode send flow", function()
	local saved, old_schedule, old_notify, calls, callbacks, send
	local names = { "opencode.send", "opencode.client", "opencode.selectors", "opencode.events" }
	local function model() return { providerID = "p", id = "catalog-id" } end
	local function accepted(index)
		local call = calls[index or #calls]
		callbacks.prompt(nil, { id = call.body.id, sessionID = call.sid, type = "user",
			payload = { text = call.body.text }, delivery = call.body.delivery, time = { created = 20 } })
	end
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); history.clear()
		state.set_config({ session = { default_agent = "build" } })
		sync.handle_providers({ { id = "p", models = { ["catalog-id"] = { variants = { fast = {} } } } } })
		sync.handle_agents({ { id = "build", name = "Builder" } })
		state.set_session("ses_a", "A")
		calls, callbacks, saved = {}, {}, {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		old_schedule, old_notify = vim.schedule, vim.notify
		vim.schedule = function(fn) fn() end
		vim.notify = function() end
		package.loaded["opencode.events"] = { emit = function() end }
		package.loaded["opencode.selectors"] = { send_selection = function(opts)
			return { agent = opts.agent or "build", model = opts.model or model(), variant = opts.variant }
		end, pending_input = selectors.pending_input }
		package.loaded["opencode.client"] = {
			run_session_shell = function(sid, command, cb)
				calls[#calls + 1] = { method = "shell", sid = sid, command = command }; callbacks.shell = cb
			end,
			commit_revert = function(sid, cb)
				calls[#calls + 1] = { method = "commit", sid = sid,
					pending = pending.list(sid), messages = sync.get_messages(sid) }
				callbacks.commit = cb
			end,
			set_input_delivery = function(sid, id, delivery, cb)
				calls[#calls + 1] = { method = "delivery", sid = sid, id = id, delivery = delivery }; callbacks.delivery = cb
			end,
			cancel_input = function(sid, id, cb)
				calls[#calls + 1] = { method = "cancel", sid = sid, id = id }; callbacks.cancel = cb
			end,
			get_inbox = function(_, cb) cb(nil, {}) end,
			get_all_messages = function(_, cb) cb(nil, {}, { complete = true }) end,
			get_session = function(sid, cb)
				calls[#calls + 1] = { method = "get", sid = sid }; callbacks.get = cb
			end,
			switch_agent = function(sid, agent, cb)
				calls[#calls + 1] = { method = "agent", sid = sid, agent = agent }; callbacks.agent = cb
			end,
			switch_model = function(sid, value, cb)
				calls[#calls + 1] = { method = "model", sid = sid, body = value }; callbacks.model = cb
			end,
			send_message = function(sid, body, cb)
				calls[#calls + 1] = { method = "prompt", sid = sid, body = body }; callbacks.prompt = cb
			end,
			execute_command = function(sid, name, text, opts, cb)
				calls[#calls + 1] = { method = "command", sid = sid, name = name, text = text, options = opts }; callbacks.command = cb
			end,
			create_session = function(body, cb)
				calls[#calls + 1] = { method = "create", body = body }; callbacks.create = cb
			end,
		}
		send = require("opencode.send")
	end)
	after_each(function()
		vim.schedule, vim.notify = old_schedule, old_notify
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		pending.clear_all(); sync.clear_all(); state.reset(); history.clear()
	end)

	it("runs a shell command without model/catalog selection or prompt admission", function()
		sync.clear_all()
		assert.is_true(send.send("echo 'Привет'", { mode = "shell" }))
		assert.equals(1, #calls)
		assert.equals("shell", calls[1].method)
		assert.equals("ses_a", calls[1].sid)
		assert.equals("echo 'Привет'", calls[1].command)
		assert.same({}, pending.list("ses_a"))
		callbacks.shell(nil)
	end)
	it("rejects shell attachments and steering and restores the draft's shell mode", function()
		assert.is_false(send.send("echo image", { mode = "shell", parts = { { type = "file", filename = "a.png" } } }))
		assert.equals("shell", history.get_pending_mode("ses_a"))
		assert.equals("echo image", history.get_pending("ses_a"))
		assert.is_false(send.send("pwd", { mode = "shell", delivery = "steer" }))
		assert.equals(0, #calls)
	end)
	it("does not retry uncertain shell execution or act on a stale response", function()
		assert.is_true(send.send("sleep 2", { mode = "shell" }))
		callbacks.shell({ message = "Socket lost" })
		assert.equals(1, #calls)
		assert.equals("", history.get_pending("ses_a"))
		assert.is_true(send.send("pwd", { mode = "shell" }))
		pending.invalidate()
		callbacks.shell({ status = 404, message = "Missing" })
		assert.equals("", history.get_pending("ses_a"))
	end)
	it("restores a definitively rejected shell command in its original session", function()
		assert.is_true(send.send("pwd", { mode = "shell" }))
		state.set_session("ses_b", "B")
		callbacks.shell({ status = 400, message = "Rejected" })
		assert.equals("pwd", history.get_pending("ses_a"))
		assert.equals("shell", history.get_pending_mode("ses_a"))
		assert.equals("", history.get_pending("ses_b"))
	end)

	for _, case in ipairs({
		{ name = "malformed model", model = 42 },
		{ name = "unavailable variant", model = { providerID = "p", modelID = "catalog-id", variant = "missing" } },
	}) do
		it("rejects an explicit " .. case.name .. " and preserves its draft", function()
			assert.is_false(send.send("Keep this draft", { model = case.model }))
			assert.equals(0, #calls)
			assert.same({}, pending.list("ses_a"))
			assert.equals("Keep this draft", history.get_pending("ses_a"))
		end)
	end

	it("serializes agent -> model -> prompt and never marks admission idle", function()
		assert.is_true(send.send("Hello", { variant = "fast" }))
		state.set_session("ses_b", "B")
		callbacks.get(nil, { id = "ses_a", agent = "other", model = model() })
		assert.equals("agent", calls[2].method)
		callbacks.agent(nil)
		assert.equals("model", calls[3].method)
		assert.same({ providerID = "p", id = "catalog-id", variant = "fast" }, calls[3].body)
		callbacks.model(nil)
		assert.equals("prompt", calls[4].method)
		assert.equals("ses_a", calls[4].sid)
		local payload = calls[4].body
		assert.equals("build", require("opencode.local").message_agent.get("ses_a", payload.id))
		assert.is_nil(payload.parts); assert.is_nil(payload.model); assert.is_nil(payload.agent)
		assert.is_nil(payload.messageID); assert.equals("Hello", payload.text)
		accepted()
		assert.equals("queued", pending.get("ses_a", payload.id).status)
		assert.equals("busy", state.get_session_status("ses_a").type)
		assert.equals(1, #sync.get_messages("ses_a"))
		assert.equals("idle", state.get_session_status("ses_b").type)
		assert.same({}, sync.get_messages("ses_b"))
	end)

	it("queues by default even when the session is idle until delivery is confirmed", function()
		state.set_session_status("ses_a", { type = "idle" })
		assert.is_true(send.send("стой", {}))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local payload = calls[2].body
		assert.equals("queue", payload.delivery)
		-- An idle session delivers it at once: the prompt keeps its unlabeled transcript row.
		assert.is_nil((selectors.prompt_status("ses_a", payload.id)))
		assert.is_false(selectors.prompt_docked("ses_a", payload.id))
		accepted()
		assert.equals("queued", pending.get("ses_a", payload.id).status)
		assert.is_false(selectors.prompt_docked("ses_a", payload.id))
		assert.same({}, selectors.queued_prompts("ses_a"))
		assert.is_true(sync.get_message("ses_a", payload.id).provisional)
		local effect = sync.handle_server_event({ id = "evt_delivery", created = 30, type = "session.inbox.delivered",
			data = { sessionID = "ses_a", inboxID = payload.id } })
		pending.update("ses_a", effect.delivered, { status = "delivered" })
		assert.is_nil(selectors.prompt_status("ses_a", payload.id))
		assert.is_nil(sync.get_message("ses_a", payload.id).provisional)
		assert.equals(1, #sync.get_messages("ses_a"))
	end)

	it("docks a prompt queued behind running work once the server admits it", function()
		state.set_session_status("ses_a", { type = "busy" })
		assert.is_true(send.send("Later", {}))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local payload = calls[2].body
		assert.is_true(selectors.prompt_docked("ses_a", payload.id))
		assert.same({}, selectors.queued_prompts("ses_a"))
		accepted()
		assert.same({ { id = payload.id, text = "Later" } }, selectors.queued_prompts("ses_a"))
		assert.is_nil((selectors.prompt_status("ses_a", payload.id)))
	end)

	it("sends an explicitly steered prompt with steer delivery", function()
		state.set_session_status("ses_a", { type = "busy" })
		assert.is_true(send.send("Between agent steps", { delivery = "steer" }))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.equals("steer", calls[2].body.delivery)
		assert.is_nil((selectors.prompt_status("ses_a", calls[2].body.id)))
		assert.is_false(selectors.prompt_docked("ses_a", calls[2].body.id))
		accepted()
		assert.equals("accepted", pending.get("ses_a", calls[2].body.id).status)
		assert.is_false(selectors.prompt_docked("ses_a", calls[2].body.id))
	end)

	it("does not undo a newer queue change when the earlier steer PATCH completes late", function()
		local bus = require("opencode.events.bus")
		local handler = require("opencode.events.handlers.server")
		bus.clear(); handler.clear(); handler.setup(bus)
		local ok, err = pcall(function()
			assert.is_true(send.send("Race", {}))
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
			local id = calls[2].body.id
			assert.is_true(send.steer_input("ses_a", id))
			local old_steer_callback = callbacks.delivery
			bus.emit("server_event", { id = "evt_steer", created = 21, type = "session.inbox.delivery.changed",
				data = { sessionID = "ses_a", inboxID = id, delivery = "steer" } })
			assert.equals("accepted", pending.get("ses_a", id).status)
			assert.is_true(send.queue_input("ses_a", id))
			local queue_callback = callbacks.delivery
			assert.is_not.equals(old_steer_callback, queue_callback)
			bus.emit("server_event", { id = "evt_queue", created = 22, type = "session.inbox.delivery.changed",
				data = { sessionID = "ses_a", inboxID = id, delivery = "queue" } })
			queue_callback(nil)
			assert.equals("queued", pending.get("ses_a", id).status)
			old_steer_callback(nil)
			assert.equals("queue", pending.get("ses_a", id).inbox.delivery)
			assert.equals("queued", pending.get("ses_a", id).status)
			-- Queued in an idle session, then moved by hand: it now waits in the queue dock.
			assert.is_true(selectors.prompt_docked("ses_a", id))
			assert.equals(4, #calls)
		end)
		bus.clear(); handler.clear()
		assert.is_true(ok, err)
	end)

	it("keeps a confirmed steering change when the original admission arrives late", function()
		send.send("Queued", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local payload = calls[2].body
		pending.admit({ sessionID = "ses_a", id = payload.id, type = "user", delivery = "queue", payload = { text = payload.text } })
		send.steer_input("ses_a", payload.id)
		callbacks.delivery(nil)
		accepted(2)
		assert.equals("steer", pending.get("ses_a", payload.id).inbox.delivery)
		assert.equals("accepted", selectors.pending_input("ses_a", payload.id).status)
		assert.is_false(selectors.prompt_docked("ses_a", payload.id))
	end)

	it("stops after a failed selection change and preserves the draft", function()
		send.send("Keep this", {})
		callbacks.get(nil, { id = "ses_a", agent = "other" })
		callbacks.agent({ status = 400, message = "Invalid agent" })
		assert.equals(2, #calls)
		assert.equals("Keep this", history.get_pending())
		assert.equals("idle", state.get_session_status("ses_a").type)
	end)

	it("confirms cancellation with ordered inbox and complete history reads before returning one draft", function()
		local client, inbox, history_read = require("opencode.client")
		client.get_inbox = function(_, cb) inbox = cb end
		client.get_all_messages = function(_, cb) history_read = cb end
		send.send("Edit once", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, draft, duplicate_error, count = calls[#calls].body.id, nil, nil, 0
		send.edit_input("ses_a", id, function(err, result) assert.is_nil(err); draft = result; count = count + 1 end)
		send.edit_input("ses_a", id, function(err) duplicate_error = err end)
		assert.matches("already in progress", duplicate_error.message)
		assert.equals("cancel", calls[#calls].method)
		assert.equals(3, #calls)
		callbacks.cancel(nil)
		assert.is_nil(draft); assert.is_nil(history_read)
		inbox(nil, {})
		assert.is_nil(draft)
		history_read(nil, {}, { complete = true })
		assert.equals("Edit once", draft.text); assert.equals(1, count)
		callbacks.cancel(nil)
		assert.equals(1, count)
		assert.equals("cancelled", pending.get("ses_a", id).status)
	end)

	it("waits for admission even when cancellation is requested directly", function()
		send.send("Still submitting", {})
		local id, completed = sync.get_messages("ses_a")[1].id, false
		send.cancel_input("ses_a", id, function(err) assert.is_nil(err); completed = true end)
		assert.equals(1, #calls); assert.is_false(completed)
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		assert.equals("cancel", calls[#calls].method)
		callbacks.cancel(nil)
		assert.is_true(completed)
	end)

	it("does not infer cancellation or delivery for unconfirmed admission or HTTP 404", function()
		local failure
		assert.is_false(send.cancel_input("ses_a", "unknown", function(err) failure = err end))
		assert.is_not_nil(failure); assert.equals(0, #calls)
		pending.begin({ session_id = "ses_a", message_id = "uncertain", status = "uncertain" })
		assert.is_false(send.cancel_input("ses_a", "uncertain", function(err) failure = err end))
		assert.equals(0, #calls)
		pending.admit({ sessionID = "ses_a", id = "missing", delivery = "queue" })
		send.cancel_submitting_input("ses_a", "missing", function(err) failure = err end)
		callbacks.cancel({ status = 404, message = "Session not found" })
		assert.equals(404, failure.status); assert.is_nil(failure.code)
		assert.equals("queued", pending.get("ses_a", "missing").status)
	end)

	for _, outcome in ipairs({ "cancelled", "delivered" }) do
		it("honors a terminal " .. outcome .. " event while confirmation is in flight", function()
			local client, confirm = require("opencode.client")
			client.get_all_messages = function(_, cb) confirm = cb end
			send.send("Racing event", {})
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
			local id, failure, draft = calls[#calls].body.id
			send.edit_input("ses_a", id, function(err, value) failure, draft = err, value end)
			callbacks.cancel(nil)
			pending.update("ses_a", id, { status = outcome })
			confirm(nil, {}, { complete = true })
			assert.equals(outcome, pending.get("ses_a", id).status)
			if outcome == "cancelled" then
				assert.is_nil(failure); assert.equals("Racing event", draft.text)
			else
				assert.equals("already_delivered", failure.code); assert.is_nil(draft)
				assert.is_not_nil(sync.get_message("ses_a", id))
			end
		end)
	end

	it("detects delivery in complete history when its SSE event has not arrived", function()
		local client = require("opencode.client")
		send.send("Delivered on server", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, failure, draft = calls[#calls].body.id
		local delivered = require("opencode.protocol.messages").project("ses_a", {
			id = id, type = "user", text = "Delivered on server", time = { created = 40 },
		})
		client.get_all_messages = function(_, cb) cb(nil, { delivered }, { complete = true }) end
		send.edit_input("ses_a", id, function(err, value) failure, draft = err, value end)
		callbacks.cancel(nil)
		assert.equals("already_delivered", failure.code); assert.is_nil(draft)
		assert.equals("delivered", pending.get("ses_a", id).status)
		assert.is_nil(sync.get_message("ses_a", id).provisional)
	end)

	it("requires a terminal event to confirm cancellation of compaction inputs", function()
		local client, confirm = require("opencode.client")
		client.get_all_messages = function(_, cb) confirm = cb end
		pending.admit({ sessionID = "ses_a", id = "control", type = "compaction", delivery = "queue" })
		local failure
		send.cancel_input("ses_a", "control", function(err) failure = err end)
		callbacks.cancel(nil); confirm(nil, {}, { complete = true })
		assert.matches("could not be confirmed", failure.message)
		assert.equals("queued", pending.get("ses_a", "control").status)
		send.cancel_input("ses_a", "control", function(err) failure = err end)
		callbacks.cancel(nil)
		pending.update("ses_a", "control", { status = "cancelled" })
		confirm(nil, {}, { complete = true })
		assert.is_nil(failure)
		assert.equals("cancelled", pending.get("ses_a", "control").status)
	end)

	for _, outcome in ipairs({ "pending", "partial" }) do
		it("preserves the input when cancellation confirmation is " .. outcome, function()
			local client = require("opencode.client")
			send.send("Keep queued", {})
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
			local id, failure, draft = calls[#calls].body.id
			client.get_inbox = function(_, cb)
				cb(nil, outcome == "pending" and { { id = id } } or {})
			end
			client.get_all_messages = function(_, cb)
				cb(nil, {}, { complete = outcome ~= "partial" })
			end
			send.edit_input("ses_a", id, function(err, value) failure, draft = err, value end)
			callbacks.cancel(nil)
			assert.is_not_nil(failure); assert.is_nil(draft)
			assert.equals("queued", pending.get("ses_a", id).status)
			assert.is_not_nil(sync.get_message("ses_a", id))
			client.get_inbox = function(_, cb) cb(nil, {}) end
			client.get_all_messages = function(_, cb) cb(nil, {}, { complete = true }) end
			send.edit_input("ses_a", id, function(err, value) assert.is_nil(err); draft = value end)
			callbacks.cancel(nil)
			assert.equals("Keep queued", draft.text)
		end)
	end

	it("records an uncertain timeout without another POST or a false idle", function()
		send.send("Uncertain", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local id = calls[2].body.id
		callbacks.prompt({ message = "Connection reset" })
		assert.equals("uncertain", pending.get("ses_a", id).status)
		assert.equals(2, #calls)
		assert.equals("busy", state.get_session_status("ses_a").type)
	end)

	it("does not regress delivery when HTTP completes after events", function()
		send.send("Delivered", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local id = calls[2].body.id
		pending.update("ses_a", id, { status = "delivered" })
		accepted()
		assert.equals("delivered", pending.get("ses_a", id).status)
		assert.equals(1, #sync.get_messages("ses_a"))
	end)

	it("commits a staged undo before seeding a new prompt and preserves later inbox evidence", function()
		local bus = require("opencode.events.bus")
		local handler = require("opencode.events.handlers.server")
		local projection = require("opencode.protocol.messages")
		local old_id = "msg_00000000000000000000"
		sync.handle_session_messages("ses_a", projection.page("ses_a", {
			{ id = old_id, type = "user", text = "Undone", time = { created = 1 } },
		}))
		state.upsert_session({ id = "ses_a", revert = { messageID = old_id } })
		bus.clear(); handler.clear(); handler.setup(bus)
		local function answer_get()
			if callbacks.get then
				local cb = callbacks.get; callbacks.get = nil
				cb(nil, { id = "ses_a", agent = "build", model = model(),
					revert = (state.get_session_record("ses_a") or {}).revert })
			end
		end
		local ok, err = pcall(function()
			assert.is_true(send.send("Replacement", {}))
			answer_get()
			assert.is_function(callbacks.commit)
			local commit = vim.tbl_filter(function(call) return call.method == "commit" end, calls)[1]
			assert.same({}, commit.pending)
			assert.equals(1, #commit.messages)
			callbacks.commit(nil)
			answer_get()
			local prompt = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1]
			assert.is_not_nil(prompt)
			assert.equals("Replacement", prompt.body.text)
			local id = prompt.body.id
			assert.is_not.equals(old_id, id)
			assert.equals("submitting", pending.get("ses_a", id).status)
			local first_callback = callbacks.prompt
			assert.is_true(send.send("Another replacement", {}))
			local second_id
			for candidate, record in pairs(pending.list("ses_a")) do
				if candidate ~= id and record.status == "submitting" then second_id = candidate end
			end
			assert.is_not_nil(second_id)
			assert.equals("submitting", pending.get("ses_a", second_id).status)
			assert.is_not_nil(sync.get_message("ses_a", second_id))
			assert.equals(1, #vim.tbl_filter(function(call) return call.method == "prompt" end, calls))

			-- The SSE commit may reach Neovim after HTTP commit and two fresh seeds.
			bus.emit("server_event", { id = "evt_commit", created = 10, type = "session.revert.committed",
				data = { sessionID = "ses_a", to = old_id } })
			assert.equals("submitting", pending.get("ses_a", id).status)
			assert.equals("submitting", pending.get("ses_a", second_id).status)
			assert.is_not_nil(sync.get_message("ses_a", id))
			assert.is_not_nil(sync.get_message("ses_a", second_id))
			local item = { sessionID = "ses_a", id = id, type = "user", delivery = "queue",
				payload = { text = "Replacement" }, time = { created = 20 } }
			bus.emit("server_event", { id = "evt_queue", created = 20, type = "session.inbox.enqueued",
				data = { sessionID = "ses_a", inboxID = id, item = item } })
			assert.equals("queued", pending.get("ses_a", id).status)
			first_callback(nil, item)
			assert.equals("queued", pending.get("ses_a", id).status)
			answer_get()
			local prompts = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)
			assert.equals(2, #prompts)
			assert.equals(second_id, prompts[2].body.id)
			callbacks.prompt(nil, { sessionID = "ses_a", id = second_id, type = "user",
				delivery = "queue", payload = { text = "Another replacement" }, time = { created = 21 } })
			assert.equals("queued", pending.get("ses_a", second_id).status)
			bus.emit("server_event", { id = "evt_delivery", created = 30, type = "session.inbox.delivered",
				data = { sessionID = "ses_a", inboxID = id } })
			bus.emit("server_event", { id = "evt_delivery_second", created = 31, type = "session.inbox.delivered",
				data = { sessionID = "ses_a", inboxID = second_id } })
			assert.equals("delivered", pending.get("ses_a", id).status)
			assert.equals("delivered", pending.get("ses_a", second_id).status)
		end)
		bus.clear(); handler.clear()
		assert.is_true(ok, err)
	end)

	it("accepts a new prompt when the committed SSE arrives before the HTTP commit response", function()
		local bus = require("opencode.events.bus")
		local handler = require("opencode.events.handlers.server")
		local projection = require("opencode.protocol.messages")
		local old_id = "msg_00000000000000000000"
		sync.handle_session_messages("ses_a", projection.page("ses_a", {
			{ id = old_id, type = "user", text = "Undone", time = { created = 1 } },
		}))
		state.upsert_session({ id = "ses_a", revert = { messageID = old_id } })
		bus.clear(); handler.clear(); handler.setup(bus)
		local ok, err = pcall(function()
			assert.is_true(send.send("After early SSE", {}))
			if callbacks.get then
				local cb = callbacks.get; callbacks.get = nil
				cb(nil, { id = "ses_a", agent = "build", model = model(), revert = { messageID = old_id } })
			end
			assert.is_function(callbacks.commit)
			assert.same({}, pending.list("ses_a"))
			bus.emit("server_event", { id = "evt_commit_early", created = 10, type = "session.revert.committed",
				data = { sessionID = "ses_a", to = old_id } })
			assert.is_nil(sync.get_message("ses_a", old_id))
			for _, record in pairs(pending.list("ses_a")) do
				assert.is_not.equals("submitting", record.status)
			end
			callbacks.commit(nil)
			if callbacks.get then
				local cb = callbacks.get; callbacks.get = nil
				cb(nil, { id = "ses_a", agent = "build", model = model() })
			end
			local prompt = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1]
			assert.is_not_nil(prompt)
			assert.equals("After early SSE", prompt.body.text)
			assert.equals("submitting", pending.get("ses_a", prompt.body.id).status)
			assert.is_not_nil(sync.get_message("ses_a", prompt.body.id))
			accepted()
			assert.equals("queued", pending.get("ses_a", prompt.body.id).status)
		end)
		bus.clear(); handler.clear()
		assert.is_true(ok, err)
	end)

	it("commits a newer staged undo before seeding a prompt", function()
		local projection = require("opencode.protocol.messages")
		local first_id, second_id = "msg_00000000000000000001", "msg_00000000000000000002"
		sync.handle_session_messages("ses_a", projection.page("ses_a", {
			{ id = first_id, type = "user", text = "First", time = { created = 1 } },
			{ id = second_id, type = "user", text = "Second", time = { created = 2 } },
		}))
		state.upsert_session({ id = "ses_a", revert = { messageID = second_id } })
		assert.is_true(send.send("Replacement", {}))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model(),
			revert = { messageID = second_id } })
		local first_commit = callbacks.commit
		assert.is_function(first_commit)
		state.upsert_session({ id = "ses_a", revert = { messageID = first_id } })
		first_commit(nil)
		assert.equals(first_id, state.get_session_record("ses_a").revert.messageID)
		assert.equals(2, #vim.tbl_filter(function(call) return call.method == "commit" end, calls))
		assert.is_nil(vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1])
		assert.same({}, pending.list("ses_a"))
		callbacks.commit(nil)
		assert.is_nil(state.get_session_record("ses_a").revert)
		assert.is_nil(sync.get_message("ses_a", first_id))
		local prompt = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1]
		assert.is_not_nil(prompt)
		assert.equals("Replacement", prompt.body.text)
		assert.equals("submitting", pending.get("ses_a", prompt.body.id).status)
	end)

	it("preserves prompts seeded before a concurrent undo is staged", function()
		local projection = require("opencode.protocol.messages")
		local old_id = "msg_00000000000000000000"
		sync.handle_session_messages("ses_a", projection.page("ses_a", {
			{ id = old_id, type = "user", text = "Earlier turn", time = { created = 1 } },
		}))
		assert.is_true(send.send("First pending", {}))
		assert.is_true(send.send("Second pending", {}))
		local second_id
		for id, record in pairs(pending.list("ses_a")) do
			if record.text == "Second pending" then second_id = id end
		end
		assert.is_not_nil(second_id)
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local first_prompt = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1]
		assert.is_not_nil(first_prompt)
		state.upsert_session({ id = "ses_a", revert = { messageID = old_id } })
		callbacks.prompt(nil, { id = first_prompt.body.id, sessionID = "ses_a", type = "user",
			payload = { text = "First pending" }, delivery = "queue", time = { created = 2 } })
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model(), revert = { messageID = old_id } })
		assert.is_function(callbacks.commit)
		callbacks.commit(nil)
		assert.is_nil(sync.get_message("ses_a", old_id))
		assert.is_not_nil(sync.get_message("ses_a", first_prompt.body.id))
		assert.is_not_nil(sync.get_message("ses_a", second_id))
		assert.equals("queued", pending.get("ses_a", first_prompt.body.id).status)
		assert.equals("submitting", pending.get("ses_a", second_id).status)
		local prompts = vim.tbl_filter(function(call) return call.method == "prompt" end, calls)
		assert.equals(2, #prompts)
		assert.equals(second_id, prompts[2].body.id)
	end)

	it("keeps the draft and avoids optimistic state when committing a staged undo fails", function()
		state.upsert_session({ id = "ses_a", revert = { messageID = "msg_old" } })
		local file = { type = "file", url = "file:///tmp/retry.txt", filename = "retry.txt" }
		assert.is_true(send.send("Retry with file", { parts = { file } }))
		if callbacks.get then
			local cb = callbacks.get; callbacks.get = nil
			cb(nil, { id = "ses_a", agent = "build", model = model(), revert = { messageID = "msg_old" } })
		end
		assert.is_function(callbacks.commit)
		callbacks.commit({ status = 500, message = "Commit unavailable" })
		assert.equals("Retry with file", history.get_pending())
		assert.same({ file }, history.get_pending_parts())
		assert.same({}, pending.list("ses_a"))
		assert.same({}, sync.get_messages("ses_a"))
		assert.is_nil(vim.tbl_filter(function(call) return call.method == "prompt" end, calls)[1])
		assert.is_not_nil(state.get_session_record("ses_a").revert)
	end)

	it("restores a failed prompt only in its original session after a tab change", function()
		local file = { type = "file", url = "file:///tmp/original.png", filename = "original.png" }
		assert.is_true(send.send("Retry A", { parts = { file } }))
		state.set_session("ses_b", "B")
		history.set_pending("Draft B", nil, "ses_b")
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		callbacks.prompt({ status = 400, message = "Rejected" })
		assert.equals("Retry A", history.get_pending("ses_a"))
		assert.same({ file }, history.get_pending_parts("ses_a"))
		assert.equals("Draft B", history.get_pending("ses_b"))
		assert.same({}, history.get_pending_parts("ses_b"))
	end)
	it("preserves the unsaved editor snapshot for a rejected prompt's retry without old admission tokens", function()
		local snapshot = { type = "text", text = "unsaved editor snapshot", _editor_context = { identity = "snapshot", path = "/source.lua" } }
		assert.is_true(send.send("Retry context", { context = { snapshot }, _token = pending.token("ses_a"),
			_catalog_ready = true, _catalog_deadline = 1, delivery = "steer", resume = false }))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		callbacks.prompt({ status = 400, message = "Rejected" })
		local options = history.get_pending_options("ses_a")
		assert.same({ snapshot }, options.context); assert.equals("steer", options.delivery); assert.equals(false, options.resume)
		assert.is_nil(options._token); assert.is_nil(options._catalog_ready); assert.is_nil(options._catalog_deadline)
		options.context[1].text = "modified copy"
		assert.equals(snapshot.text, history.get_pending_options("ses_a").context[1].text)
		assert.is_true(send.send(history.get_pending("ses_a"), history.get_pending_options("ses_a")))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local payload = calls[#calls].body
		assert.equals("Retry context\n\nunsaved editor snapshot", payload.text)
		assert.is_nil(vim.json.encode(payload):find("_editor_context", 1, true))
	end)

	local function with_context_source(run)
		local context = require("opencode.context")
		local previous = vim.api.nvim_get_current_buf()
		local source = vim.api.nvim_create_buf(true, false)
		vim.api.nvim_set_current_buf(source)
		vim.api.nvim_buf_set_lines(source, 0, -1, false, { "local frozen = 1", "return frozen" })
		context.clear()
		local ok, err = pcall(run, source, context)
		vim.api.nvim_set_current_buf(previous)
		if vim.api.nvim_buf_is_valid(source) then vim.api.nvim_buf_delete(source, { force = true }) end
		context.clear()
		assert.is_true(ok, err)
	end

	it("expands a frozen context only in the payload and restores the original rejected draft", function()
		with_context_source(function(source, context)
			local snapshot = assert(context.capture())
			vim.api.nvim_buf_set_lines(source, 0, -1, false, { "changed after opening" })
			assert.is_true(send.send("Explain @buffer", { _context_snapshot = snapshot }))
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
			local payload = calls[#calls].body
			assert.is_truthy(payload.text:find("local frozen = 1", 1, true))
			assert.is_nil(payload.text:find("changed after opening", 1, true))
			assert.equals("Explain @buffer", pending.get("ses_a", payload.id).text)
			assert.is_nil(payload._context_snapshot)
			callbacks.prompt({ status = 400, message = "Rejected" })
			assert.equals("Explain @buffer", history.get_pending("ses_a"))
			assert.is_nil(history.get_pending_options("ses_a")._context_snapshot)
		end)
	end)

	it("waits for a new location's initially empty catalogs without changing the send target", function()
		local old_defer, retry = vim.defer_fn, nil
		vim.defer_fn = function(fn) retry = fn end
		local client = require("opencode.client")
		local rounds = 0
		client.get_config_providers = function(cb, opts)
			assert.equals("/new-project", opts.directory)
			rounds = rounds + 1
			cb(nil, { providers = rounds == 1 and {} or { { id = "p", models = { ["catalog-id"] = {} } } } })
		end
		client.list_agents = function(cb) cb(nil, { { id = "build", name = "Builder" } }) end
		sync.select_catalog_location("/old-project")
		local ok, err = pcall(function()
			assert.is_true(send.send("Keep original owner", { directory = "/new-project", session_id = "ses_a" }))
			assert.equals(0, #calls); assert.equals(1, rounds); assert.is_function(retry)
			state.set_session("ses_b", "B"); retry()
			assert.equals(2, rounds); assert.equals("ses_a", calls[1].sid)
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
			assert.equals("prompt", calls[2].method); assert.equals("ses_a", calls[2].sid)
		end)
		vim.defer_fn = old_defer
		assert.is_true(ok, err)
	end)

	it("invalidates callbacks on close/reset without resurrecting a prompt", function()
		send.send("A", {})
		pending.clear_session("ses_a")
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.equals(1, #calls)
		assert.same({}, pending.list("ses_a"))
	end)

	it("serializes two rapid submissions with distinct stable IDs", function()
		send.send("One", {}); send.send("Two", {})
		assert.equals(1, #calls)
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local first = calls[2].body.id
		accepted(2)
		assert.equals("get", calls[3].method)
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.is_not.equals(first, calls[4].body.id)
		assert.equals(2, #sync.get_messages("ses_a"))
	end)

	it("reports a location provider without models as an unavailable model", function()
		sync.select_catalog_location("/active")
		sync.handle_location_catalog("/scoped", "providers", { providers = { { id = "p" } } })
		sync.handle_location_catalog("/scoped", "agents", { { id = "build", name = "Builder" } })
		local failure
		local ok, sent = pcall(send.command, "ses_a", "review", "", { directory = "/scoped" }, function(err) failure = err end)
		assert.is_true(ok, sent)
		assert.is_false(sent)
		assert.same({ code = "invalid_selection", message = "The selected model is unavailable in this location" }, failure)
		assert.equals(0, #calls)
	end)

	it("creates with captured location and selection, then sends to the created session", function()
		state.set_session(nil)
		send.send("New", { directory = "/tmp/project А" })
		assert.same({ location = { directory = "/tmp/project А" }, agent = "build", model = model() }, calls[1].body)
		state.set_session("ses_b", "B")
		callbacks.create(nil, { id = "ses_new", agent = "build", model = model(), location = { directory = "/tmp/project А" } })
		assert.equals("ses_new", calls[2].sid)
		assert.equals("ses_b", state.get_session().id)
	end)

	for _, visibility in ipairs({ "visible", "closed" }) do
		it("keeps a first prompt attached to its original pane (" .. visibility .. ")", function()
			local views = require("opencode.ui.chat.state")
			local view = views.new()
			view.visible = true
			local previous_chat, bound = package.loaded["opencode.ui.chat"], nil
			package.loaded["opencode.ui.chat"] = { bind_session = function(owner, session) bound = { owner, session.id } end }
			local ok, err = pcall(function()
				send.send("First prompt", { session_id = false, directory = "/tmp/owner",
					_view_id = view.id, _view_generation = view.generation })
				state.set_session("ses_b", "B")
				if visibility == "closed" then views.remove(view) end
				callbacks.create(nil, { id = "ses_new", agent = "build", model = model() })
				assert.equals("ses_new", calls[2].sid)
				assert.equals("ses_b", state.get_session().id)
				if visibility == "closed" then assert.is_nil(bound) else
					assert.equals(view, bound[1]); assert.equals("ses_new", bound[2])
				end
			end)
			package.loaded["opencode.ui.chat"] = previous_chat
			if views.valid(view) then views.remove(view) end
			assert.is_true(ok, err)
		end)
	end

	it("converts attachments and explicitly rejects unsupported v1 options", function()
		local parts = { { type = "file", url = "data:image/png;base64,AAAA", filename = "shot.png" },
			{ type = "agent", name = "explore" }, { type = "skill", skillID = "review" } }
		send.send("Привет 😀", { parts = parts, resume = false })
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.same({ { uri = "data:image/png;base64,AAAA", name = "shot.png" } }, calls[2].body.files)
		assert.same({ { name = "explore" } }, calls[2].body.agents)
		assert.same({ { id = "review" } }, calls[2].body.skills)
		assert.equals(false, calls[2].body.resume)
		assert.is_false(send.send("Unsupported", { system = "secret override" }))
		assert.equals(2, #calls)
	end)
	it("serializes commands with prompts and does not fabricate a message from HTTP 204", function()
		send.send("One", {})
		local command_done = 0
		assert.is_true(send.command("ses_a", "review", "--staged", { variant = "fast" }, function(err)
			assert.is_nil(err); command_done = command_done + 1
		end))
		assert.equals(1, #calls)
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		accepted()
		assert.equals("get", calls[3].method)
		state.set_session("ses_b", "B")
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.equals("model", calls[4].method)
		callbacks.model(nil)
		assert.equals("command", calls[5].method)
		assert.equals("ses_a", calls[5].sid)
		callbacks.command(nil, true)
		assert.equals(1, command_done)
		assert.equals(1, #sync.get_messages("ses_a"))
		assert.equals("busy", state.get_session_status("ses_a").type)
	end)

end)
