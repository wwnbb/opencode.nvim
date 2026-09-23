-- Admission, correlation, selection and session ownership checks for v2.
local state = require("opencode.state")
local sync = require("opencode.sync")
local pending = require("opencode.session.pending")
local history = require("opencode.ui.input.history")
local selectors = require("opencode.selectors")

describe("opencode v2 send flow", function()
	local saved, old_schedule, old_notify, calls, callbacks, send
	local names = { "opencode.send", "opencode.client", "opencode.selectors", "opencode.events" }
	local function model() return { providerID = "p", id = "catalog-id" } end
	local function accepted(index)
		local call = calls[index or #calls]
		callbacks.prompt(nil, { id = call.body.id, sessionID = call.sid, type = "user",
			payload = { text = call.body.text }, delivery = call.body.delivery, time = { created = 20 } })
	end
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); history.clear_pending()
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
			set_input_delivery = function(sid, id, delivery, cb)
				calls[#calls + 1] = { method = "delivery", sid = sid, id = id, delivery = delivery }; callbacks.delivery = cb
			end,
			cancel_input = function(sid, id, cb)
				calls[#calls + 1] = { method = "cancel", sid = sid, id = id }; callbacks.cancel = cb
			end,
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
		pending.clear_all(); sync.clear_all(); state.reset(); history.clear_pending()
	end)

	it("serializes agent -> model -> prompt and never marks admission idle", function()
		assert.is_true(send.send("Hello", { variant = "fast" }))
		callbacks.get(nil, { id = "ses_a", agent = "other", model = model() })
		assert.equals("agent", calls[2].method)
		callbacks.agent(nil)
		assert.equals("model", calls[3].method)
		assert.same({ providerID = "p", id = "catalog-id", variant = "fast" }, calls[3].body)
		callbacks.model(nil)
		assert.equals("prompt", calls[4].method)
		local payload = calls[4].body
		assert.equals("build", require("opencode.local").message_agent.get("ses_a", payload.id))
		assert.is_nil(payload.parts); assert.is_nil(payload.model); assert.is_nil(payload.agent)
		assert.is_nil(payload.messageID); assert.equals("Hello", payload.text)
		accepted()
		assert.equals("queued", pending.get("ses_a", payload.id).status)
		assert.equals("busy", state.get_session_status("ses_a").type)
		assert.equals(1, #sync.get_messages("ses_a"))
	end)

	for _, status in ipairs({ "idle", "busy", "retry" }) do
		it("queues by default when session is " .. status .. " until delivery is confirmed", function()
			state.set_session_status("ses_a", { type = status })
			assert.is_true(send.send("стой", {}))
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
			local payload = calls[2].body
			assert.equals("queue", payload.delivery)
			assert.equals("Sending…", selectors.prompt_status("ses_a", payload.id))
			accepted()
			assert.equals("queued", pending.get("ses_a", payload.id).status)
			assert.equals("Queued", selectors.prompt_status("ses_a", payload.id))
			assert.is_true(sync.get_message("ses_a", payload.id).provisional)
			local effect = sync.handle_v2_event({ id = "evt_delivery", created = 30, type = "session.inbox.delivered",
				data = { sessionID = "ses_a", inboxID = payload.id } })
			pending.update("ses_a", effect.delivered, { status = "delivered" })
			assert.is_nil(selectors.prompt_status("ses_a", payload.id))
			assert.is_nil(sync.get_message("ses_a", payload.id).provisional)
			assert.equals(1, #sync.get_messages("ses_a"))
		end)
	end

	it("keeps explicit queue delivery while an agent is busy", function()
		state.set_session_status("ses_a", { type = "busy" })
		assert.is_true(send.send("After this turn", { delivery = "queue", resume = false }))
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		local payload = calls[2].body
		assert.equals("queue", payload.delivery)
		assert.is_false(payload.resume)
		accepted()
		assert.equals("queued", pending.get("ses_a", payload.id).status)
		assert.equals("Queued", selectors.prompt_status("ses_a", payload.id))
		assert.equals("busy", state.get_session_status("ses_a").type)
	end)

	it("promotes the existing inbox item without resending or changing its attachments", function()
		send.send("стой", { parts = { { type = "file", url = "file:///tmp/context" } } })
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id = calls[2].body.id
		assert.is_true(send.steer_input("ses_a", id))
		assert.same({ method = "delivery", sid = "ses_a", id = id, delivery = "steer" }, calls[3])
		assert.equals("Queued", selectors.prompt_status("ses_a", id))
		state.set_session("ses_b", "B")
		callbacks.delivery(nil)
		assert.equals("Steering pending", selectors.prompt_status("ses_a", id))
		assert.equals("steer", pending.get("ses_a", id).inbox.delivery)
		assert.equals("file:///tmp/context", sync.get_parts(id)[2].url)
		assert.equals(1, #sync.get_messages("ses_a"))
		assert.equals(0, #sync.get_messages("ses_b"))
		assert.equals(3, #calls)
	end)

	it("keeps queue state when a steering request fails", function()
		send.send("Queued", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, failure = calls[2].body.id
		send.steer_input("ses_a", id, function(err) failure = err end)
		callbacks.delivery({ status = 409, message = "Already delivered" })
		assert.equals(409, failure.status)
		assert.equals("queued", pending.get("ses_a", id).status)
		assert.is_not_nil(sync.get_message("ses_a", id))
		assert.equals(3, #calls)
	end)

	for _, terminal in ipairs({ "delivered", "cancelled" }) do
		it("does not regress " .. terminal .. " when steering completes late", function()
			send.send("Queued", {})
			callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
			local id = calls[2].body.id
			send.steer_input("ses_a", id)
			pending.update("ses_a", id, { status = terminal })
			callbacks.delivery(nil)
			assert.equals(terminal, pending.get("ses_a", id).status)
			assert.is_nil(selectors.prompt_status("ses_a", id))
			assert.is_false(send.steer_input("ses_a", id))
			assert.equals(3, #calls)
		end)
	end

	it("ignores a steering response after disconnect or session deletion", function()
		send.send("Queued", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, called = calls[2].body.id, false
		send.steer_input("ses_a", id, function() called = true end)
		pending.clear_session("ses_a")
		callbacks.delivery(nil)
		assert.is_nil(pending.get("ses_a", id))
		assert.is_false(called)
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
		assert.equals("Steering pending", selectors.prompt_status("ses_a", payload.id))
	end)

	it("stops after a failed selection change and preserves the draft", function()
		send.send("Keep this", {})
		callbacks.get(nil, { id = "ses_a", agent = "other" })
		callbacks.agent({ status = 400, message = "Invalid agent" })
		assert.equals(2, #calls)
		assert.equals("Keep this", history.get_pending())
		assert.equals("idle", state.get_session_status("ses_a").type)
	end)

	it("cancels only the confirmed inbox item and keeps the executing session busy", function()
		send.send("Queued", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id = calls[#calls].body.id
		send.cancel_input("ses_a", id)
		state.set_session("ses_b", "B")
		callbacks.cancel(nil)
		assert.equals("cancelled", pending.get("ses_a", id).status)
		assert.is_nil(require("opencode.local").message_agent.get("ses_a", id))
		assert.is_nil(sync.get_message("ses_a", id))
		assert.equals("busy", state.get_session_status("ses_a").type)
		assert.equals("idle", state.get_session_status("ses_b").type)
	end)

	it("does not erase a delivered message when cancellation loses the race", function()
		send.send("Already delivered", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id = calls[#calls].body.id
		send.cancel_input("ses_a", id)
		pending.update("ses_a", id, { status = "delivered" })
		callbacks.cancel({ status = 404, message = "Inbox item not found" })
		assert.equals("delivered", pending.get("ses_a", id).status)
		assert.is_not_nil(sync.get_message("ses_a", id))
	end)

	it("ignores a cancellation callback after the session was deleted", function()
		local called = false
		send.cancel_input("ses_a", "gone", function() called = true end)
		pending.clear_session("ses_a")
		callbacks.cancel(nil)
		assert.is_false(called)
	end)

	it("edits only after confirmed cancellation and preserves the original send context", function()
		local parts = { { type = "file", url = "data:image/png;base64,AAAA", filename = "shot.png", _marker = "[Image 1]" } }
		send.send("Edit\n[Image 1]", { parts = parts, directory = "/original", resume = false })
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, draft = calls[#calls].body.id
		send.edit_input("ses_a", id, function(err, result) assert.is_nil(err); draft = result end)
		assert.is_nil(draft)
		state.set_session("ses_b", "B")
		callbacks.cancel(nil)
		assert.equals("Edit\n[Image 1]", draft.text)
		assert.same(parts, draft.parts)
		assert.equals("ses_a", draft.options.session_id)
		assert.equals("/original", draft.options.directory)
		assert.equals(false, draft.options.resume)
		assert.equals("cancelled", pending.get("ses_a", id).status)
		assert.is_nil(sync.get_message("ses_a", id))
	end)

	it("restores native inbox attachments after reconnect for editing", function()
		pending.admit({ sessionID = "ses_a", id = "restored", delivery = "steer", type = "user", payload = {
			text = "Native draft", files = { { uri = "file:///tmp/file", name = "file" } },
			agents = { { name = "explore" } }, skills = { { id = "review" } },
		} })
		local draft
		send.edit_input("ses_a", "restored", function(err, result) assert.is_nil(err); draft = result end)
		callbacks.cancel(nil)
		local payload = require("opencode.protocol.v2.requests").prompt(draft.text, { parts = draft.parts }, "new")
		assert.same({ { uri = "file:///tmp/file", name = "file" } }, payload.files)
		assert.same({ { name = "explore" } }, payload.agents)
		assert.same({ { id = "review" } }, payload.skills)
		assert.equals("steer", draft.options.delivery)
	end)

	it("uses a fresh admission attempt when editing a prompt across a reconnect", function()
		send.send("Reconnect draft", { _token = pending.token("ses_a"), _catalog_ready = true, _catalog_deadline = 1 })
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, draft = calls[#calls].body.id
		pending.invalidate()
		send.edit_input("ses_a", id, function(err, value) assert.is_nil(err); draft = value end)
		callbacks.cancel(nil)
		assert.is_nil(draft.options._token)
		assert.is_nil(draft.options._catalog_ready)
		assert.is_nil(draft.options._catalog_deadline)
		assert.is_true(send.send(draft.text, draft.options))
	end)

	it("does not open an edit draft when cancellation loses to delivery", function()
		send.send("Keep delivered", {})
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() }); accepted()
		local id, error, draft = calls[#calls].body.id
		send.edit_input("ses_a", id, function(err, result) error, draft = err, result end)
		pending.update("ses_a", id, { status = "delivered" })
		callbacks.cancel({ status = 404, message = "Already delivered" })
		assert.is_not_nil(error)
		assert.is_nil(draft)
		assert.is_not_nil(sync.get_message("ses_a", id))
	end)

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

	it("keeps an operation in its original session across a tab change", function()
		send.send("A", {})
		state.set_session("ses_b", "B")
		callbacks.get(nil, { id = "ses_a", agent = "build", model = model() })
		assert.equals("ses_a", calls[2].sid)
		accepted()
		assert.equals("idle", state.get_session_status("ses_b").type)
		assert.equals(0, #sync.get_messages("ses_b"))
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

	it("creates with captured location and selection, then sends to the created session", function()
		state.set_session(nil)
		send.send("New", { directory = "/tmp/project А" })
		assert.same({ location = { directory = "/tmp/project А" }, agent = "build", model = model() }, calls[1].body)
		state.set_session("ses_b", "B")
		callbacks.create(nil, { id = "ses_new", agent = "build", model = model(), location = { directory = "/tmp/project А" } })
		assert.equals("ses_new", calls[2].sid)
		assert.equals("ses_b", state.get_session().id)
	end)

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
