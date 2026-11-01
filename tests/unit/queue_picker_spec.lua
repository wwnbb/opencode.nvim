describe("queue picker and promotion", function()
	local state, pending = require("opencode.state"), require("opencode.session.pending")
	local input, history = require("opencode.ui.input"), require("opencode.ui.input.history")
	local actions, client, lifecycle, menu = require("opencode.actions"), require("opencode.client"), require("opencode.lifecycle"), require("opencode.ui.menu")
	local events = require("opencode.events")
	local saved, inbox_callback, picker, requests, views, cancels, notices
	local function item(id, delivery, text)
		return { id = id, sessionID = "s", type = "user", delivery = delivery, payload = { text = text or id }, time = { created = 1 } }
	end
	local function key(action)
		for _, shortcut in ipairs(picker.keys) do
			if shortcut.action == action then return shortcut end
		end
		error("Missing queue menu key " .. action)
	end
	local function labels()
		local result = {}
		for index, entry in ipairs(picker.items) do result[index] = entry.label .. " · " .. entry.description end
		return result
	end
	before_each(function()
		state.reset(); pending.clear_all(); history.clear(); require("opencode.sync").clear_all()
		state.set_config(vim.deepcopy(require("opencode.config").defaults)); state.set_session("s", "Session")
		state.set_connection("connected")
		saved = { inbox = client.get_inbox, delivery = client.set_input_delivery, cancel = client.cancel_input,
			history = client.get_all_messages,
			connect = lifecycle.ensure_connected, menu = menu.open, notify = vim.notify }
		lifecycle.ensure_connected = function(cb) cb() end
		client.get_inbox = function(_, cb) inbox_callback = cb end
		client.get_all_messages = function(_, cb) cb(nil, {}, { complete = true }) end
		requests, views, cancels, notices = {}, {}, {}, {}
		client.set_input_delivery = function(sid, id, delivery, cb) requests[#requests + 1] = { sid = sid, id = id, delivery = delivery }; cb(nil) end
		client.cancel_input = function(_, id, cb) cancels[#cancels + 1] = id; cb(nil) end
		menu.open = function(opts)
			picker = opts
			opts.closed = false
			return { close = function() opts.closed = true; if opts.on_close then opts.on_close() end end,
				set_items = function(items, set_opts) opts.items, opts.preserved = items, set_opts end }
		end
		vim.notify = function(message) notices[#notices + 1] = message end
	end)
	after_each(function()
		for _, view in ipairs(views) do require("opencode.ui.chat.state").remove(view) end
		input.close(false); history.clear(); state.reset(); pending.clear_all(); require("opencode.sync").clear_all()
		client.get_inbox, client.set_input_delivery, client.cancel_input = saved.inbox, saved.delivery, saved.cancel
		client.get_all_messages = saved.history
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
	it("lists only queued prompts in admission order and steers the selected one", function()
		pending.admit(item("msg_2", "queue", "second\nline")); pending.admit(item("msg_1", "queue", "first"))
		pending.admit(item("msg_3", "steer", "steering"))
		pending.begin({ session_id = "s", message_id = "msg_4", status = "queued", immediate = true })
		require("opencode.ui.palette.queue").show()
		assert.equals(" Queued prompts ", picker.title)
		assert.equals("steer", picker.confirm_label)
		assert.is_true(picker.searchable)
		assert.same({ "first · 1 of 2", "second line · 2 of 2" }, labels())
		picker.on_select(picker.items[2], { close = function() picker.closed = true end })
		assert.same({ { sid = "s", id = "msg_2", delivery = "steer" } }, requests)
		assert.is_true(picker.closed)
	end)
	it("keeps the menu open when steering fails", function()
		client.set_input_delivery = function(_, _, _, cb) cb({ message = "Unavailable" }) end
		pending.admit(item("q", "queue"))
		require("opencode.ui.palette.queue").show()
		picker.on_select(picker.items[1], { close = function() picker.closed = true end })
		assert.is_false(picker.closed)
		assert.equals("Could not steer queued prompt: Unavailable", notices[1])
	end)
	it("deletes queued prompts, follows the queue and closes after the last", function()
		require("tests.helpers.schedule").with(function(flush)
			pending.admit(item("q1", "queue")); pending.admit(item("q2", "queue")); pending.admit(item("q3", "queue"))
			require("opencode.ui.palette.queue").show()
			key("delete").handler({ close = function() end }, picker.items[1]); flush()
			inbox_callback(nil, {}); flush()
			assert.same({ "q1" }, cancels)
			assert.same({ "q2 · 1 of 2", "q3 · 2 of 2" }, labels())
			assert.same({ preserve_selection = true }, picker.preserved)
			-- The list follows changes made elsewhere while it is open.
			pending.update("s", "q2", { status = "delivered" })
			events.emit("sync_changed", { session_id = "s", kind = "inbox" })
			assert.same({ "q3 · 1 of 1" }, labels())
			key("delete").handler({ close = function() end }, picker.items[1]); flush()
			inbox_callback(nil, {}); flush()
			assert.is_true(picker.closed)
			pending.admit(item("q4", "queue"))
			events.emit("sync_changed", { session_id = "s", kind = "inbox" })
			assert.same({ "q3 · 1 of 1" }, labels())
		end)
	end)
	it("restores a selected queued payload into the existing draft after confirmed cancellation", function()
		require("tests.helpers.schedule").with(function(flush)
			input.set_pending_draft("existing draft", {})
			pending.admit(item("selected", "queue", "queued draft"))
			require("opencode.ui.palette.queue").show()
			key("undo").handler({ close = function() picker.closed = true end }, picker.items[1]); flush()
			inbox_callback(nil, {}); flush()
			assert.is_true(picker.closed); assert.equals("cancelled", pending.get("s", "selected").status)
			assert.equals("existing draft\n\nqueued draft", input.get_pending_text())
		end)
	end)
	it("does not cancel a queued prompt that cannot join a shell draft", function()
		input.set_pending_draft("ls", {}, { mode = "shell" })
		pending.admit(item("selected", "queue", "queued draft"))
		require("opencode.ui.palette.queue").show()
		key("undo").handler({ close = function() picker.closed = true end }, picker.items[1])
		assert.same({}, cancels)
		assert.is_false(picker.closed)
		assert.equals("ls", input.get_pending_text())
		assert.equals("queued", pending.get("s", "selected").status)
		assert.is_truthy(notices[1]:find("shell", 1, true))
	end)
	it("does not act on a queue menu belonging to another session", function()
		pending.admit(item("q", "queue"))
		require("opencode.ui.palette.queue").show()
		state.set_session("other", "Other")
		local closed = 0
		local ctx = { close = function() closed = closed + 1 end }
		picker.on_select(picker.items[1], ctx)
		key("delete").handler(ctx, picker.items[1])
		key("undo").handler(ctx, picker.items[1])
		assert.same({}, requests)
		assert.same({}, cancels)
		assert.equals(3, closed)
	end)
	it("retains the queue owner after focus changes and defers edits after that pane is rebound", function()
		require("tests.helpers.schedule").with(function(flush)
			local view = require("opencode.ui.chat.state").new()
			view.session_id, view.visible = "s", true
			views[#views + 1] = view
			local cancel_reply
			client.cancel_input = function(sid, id, callback)
				assert.equals("s", sid); assert.equals("selected", id); cancel_reply = callback
			end
			pending.admit(item("selected", "queue", "owned draft"))
			require("opencode.ui.palette.queue").show({ view = view })
			state.set_session("other", "Other")
			assert.equals(view, picker.context.view)
			key("undo").handler({ close = function() end }, picker.items[1])
			view.generation = view.generation + 1
			cancel_reply(nil); flush()
			inbox_callback(nil, {}); flush()
			assert.equals("", input.get_pending_text())
			assert.equals("owned draft", history.take_deferred("s").text)
		end)
	end)
	it("retains queued context while merging into an existing draft's selection", function()
		require("tests.helpers.schedule").with(function(flush)
			local context = { { type = "text", text = "queued context" } }
			pending.begin({ session_id = "s", message_id = "selected", text = "queued draft", options = { context = context, agent = "explore" } })
			input.set_pending_draft("existing draft", {}, { options = { agent = "build", directory = "/current" } })
			pending.admit(item("selected", "queue", "queued draft\n\nqueued context"))
			require("opencode.ui.palette.queue").show()
			key("undo").handler({ close = function() end }, picker.items[1]); flush()
			inbox_callback(nil, {}); flush()
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
	it("offers View Queued Prompts only while prompts wait in the queue", function()
		local command
		require("opencode.ui.palette.queue").register({ register = function(record) command = record end })
		assert.equals("View Queued Prompts", command.title)
		assert.equals("queued", command.slash.name)
		assert.is_false(command.enabled())
		pending.admit(item("q", "queue"))
		assert.is_true(command.enabled())
	end)
	it("routes a blank steer composer key to promotion and keeps shell mode unchanged", function()
		require("tests.helpers.schedule").with(function(flush)
			local original, count = actions.promote_queued_input, 0
			actions.promote_queued_input = function(sid, cb) assert.equals("s", sid); count = count + 1; cb(nil) end
			input.show({ text = "", on_send = function() error("empty prompt must not be sent") end })
			vim.fn.maparg("<C-g>", "n", false, true).callback()
			assert.equals(1, count)
			vim.fn.maparg("<C-S-g>", "n", false, true).callback()
			input.set_mode("shell"); vim.fn.maparg("<C-g>", "n", false, true).callback()
			input.close(false)
			-- Dialog inputs (answers, review notes) keep no prompt draft and never promote the queue.
			input.show({ text = "", persist_pending = false, add_history = false,
				on_send = function() error("empty answer must not be sent") end })
			vim.fn.maparg("<C-g>", "n", false, true).callback()
			actions.promote_queued_input = original
			assert.equals(1, count)
		end)
	end)
end)
