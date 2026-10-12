describe("queue picker and promotion", function()
	local state, pending = require("opencode.state"), require("opencode.session.pending")
	local input, history = require("opencode.ui.input"), require("opencode.ui.input.history")
	local actions, client, lifecycle, menu = require("opencode.actions"), require("opencode.client"), require("opencode.lifecycle"), require("opencode.ui.menu")
	local saved, inbox_callback, picker, requests
	local function item(id, delivery, text)
		return { id = id, sessionID = "s", type = "user", delivery = delivery, payload = { text = text or id }, time = { created = 1 } }
	end
	before_each(function()
		state.reset(); pending.clear_all(); history.clear(); require("opencode.sync").clear_all()
		state.set_config(vim.deepcopy(require("opencode.config").defaults)); state.set_session("s", "Session")
		state.set_connection("connected")
		saved = { inbox = client.get_inbox, delivery = client.set_input_delivery, cancel = client.cancel_input,
			connect = lifecycle.ensure_connected, menu = menu.open, notify = vim.notify }
		lifecycle.ensure_connected = function(cb) cb() end
		client.get_inbox = function(_, cb) inbox_callback = cb end
		requests = {}
		client.set_input_delivery = function(sid, id, delivery, cb) requests[#requests + 1] = { sid = sid, id = id, delivery = delivery }; cb(nil) end
		client.cancel_input = function(_, _, cb) cb(nil) end
		menu.open = function(opts) picker = opts end
		vim.notify = function() end
	end)
	after_each(function()
		input.close(false); history.clear(); state.reset(); pending.clear_all(); require("opencode.sync").clear_all()
		client.get_inbox, client.set_input_delivery, client.cancel_input = saved.inbox, saved.delivery, saved.cancel
		lifecycle.ensure_connected, menu.open, vim.notify = saved.connect, saved.menu, saved.notify
	end)
	it("admits a fresh native snapshot but does not resurrect an item delivered before the response", function()
		require("tests.helpers.schedule").with(function(flush)
			local seen
			actions.list_pending_inputs("s", function(_, items) seen = items end)
			pending.update("s", "delivered", { status = "delivered" })
			inbox_callback(nil, { item("delivered", "queue"), item("fresh", "queue") }); flush()
			assert.equals(2, #seen); assert.equals("delivered", pending.get("s", "delivered").status)
			assert.equals("queued", pending.get("s", "fresh").status)
		end)
	end)
	it("promotes only the first queued user input without submitting a new prompt", function()
		require("tests.helpers.schedule").with(function(flush)
			actions.promote_queued_input("s", function(err) assert.is_nil(err) end)
			inbox_callback(nil, { item("steering", "steer"), item("first", "queue"), item("next", "queue") }); flush()
			assert.same({ { sid = "s", id = "first", delivery = "steer" } }, requests)
		end)
	end)
	it("restores a selected queued payload into the existing draft after confirmed cancellation", function()
		require("tests.helpers.schedule").with(function(flush)
			input.set_pending_draft("existing draft", {})
			require("opencode.ui.palette.queue").show()
			inbox_callback(nil, { item("selected", "queue", "queued draft") }); flush()
			assert.equals("Queued", picker.items[1].description)
			local closed = false
			picker.on_select(picker.items[1], { close = function() closed = true end }); flush()
			assert.is_true(closed); assert.equals("cancelled", pending.get("s", "selected").status)
			assert.equals("existing draft\n\nqueued draft", input.get_pending_text())
		end)
	end)
	it("does not act on a queue menu belonging to another session", function()
		require("tests.helpers.schedule").with(function(flush)
			require("opencode.ui.palette.queue").show(); inbox_callback(nil, { item("q", "queue") }); flush()
			state.set_session("other", "Other")
			picker.keys[3].handler({ close = function() error("stale menu closed") end }, picker.items[1]); flush()
			assert.same({}, requests)
		end)
	end)
	it("retains queued context while merging into an existing draft's selection", function()
		require("tests.helpers.schedule").with(function(flush)
			local context = { { type = "text", text = "queued context" } }
			pending.begin({ session_id = "s", message_id = "selected", text = "queued draft", options = { context = context, agent = "explore" } })
			input.set_pending_draft("existing draft", {}, { options = { agent = "build", directory = "/current" } })
			require("opencode.ui.palette.queue").show(); inbox_callback(nil, { item("selected", "queue", "queued draft\n\nqueued context") }); flush()
			picker.on_select(picker.items[1], { close = function() end }); flush()
			assert.equals("existing draft\n\nqueued draft", input.get_pending_text())
			assert.same({ agent = "build", directory = "/current", context = context }, input.get_pending_options())
			local request = assert(require("opencode.protocol.requests").prompt(input.get_pending_text(), input.get_pending_options(), "msg_1"))
			assert.equals("existing draft\n\nqueued draft\n\nqueued context", request.text)
			input.set_pending_draft("unconfigured draft", {})
			assert.is_true(input.merge_pending_draft({ text = "recalled", parts = {}, options = { agent = "explore", context = context } }))
			assert.same({ context = context }, input.get_pending_options())
			assert.is_true(input.merge_pending_draft({ text = "recalled again", parts = {}, options = { context = context } }))
			assert.equals(1, #input.get_pending_options().context)
		end)
	end)
	it("routes a blank steer composer key to promotion and keeps shell mode unchanged", function()
		require("tests.helpers.schedule").with(function(flush)
			local original, count = actions.promote_queued_input, 0
			actions.promote_queued_input = function(sid, cb) assert.equals("s", sid); count = count + 1; cb(nil) end
			input.show({ text = "", on_send = function() error("empty prompt must not be sent") end })
			vim.fn.maparg("<C-x><C-s>", "n", false, true).callback()
			assert.equals(1, count)
			input.set_mode("shell"); vim.fn.maparg("<C-x><C-s>", "n", false, true).callback()
			actions.promote_queued_input = original
			assert.equals(1, count)
		end)
	end)
end)
