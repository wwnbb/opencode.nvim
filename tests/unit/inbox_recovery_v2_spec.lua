local pending, sync = require("opencode.session.pending"), require("opencode.sync")
local state, bus = require("opencode.state"), require("opencode.events.bus")
local client, handler = require("opencode.client"), require("opencode.events.handlers.v2")
local projection, selectors = require("opencode.protocol.v2.messages"), require("opencode.selectors")

describe("v2 inbox/history recovery", function()
	local saved, callbacks
	local function item(id, delivery)
		return { sessionID = "s", id = id or "q", type = "user", delivery = delivery or "queue",
			payload = { text = "Queued text", files = { { type = "file", uri = "file:///fixture.txt" } } }, time = { created = 10 } }
	end
	local function start()
		bus.emit("v2_reconcile", { session_id = "s", complete = true })
		assert.is_true(vim.wait(1000, function() return callbacks.history and callbacks.inbox end, 10))
	end
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all(); bus.clear(); handler.clear()
		state.upsert_session({ id = "s", title = "Queue" }); state.set_session("s", "Queue")
		saved, callbacks = {}, {}
		for _, name in ipairs({ "get_session", "get_all_messages", "get_inbox" }) do saved[name] = client[name] end
		client.get_session = function(_, cb) cb(nil, { id = "s", title = "Queue" }) end
		client.get_all_messages = function(_, cb) callbacks.history = cb end
		client.get_inbox = function(_, cb) callbacks.inbox = cb end
		handler.setup(bus)
	end)
	after_each(function()
		for name, original in pairs(saved) do client[name] = original end
		bus.clear(); handler.clear(); state.reset(); sync.clear_all(); pending.clear_all()
	end)

	it("keeps an admitted prompt outside complete native history", function()
		pending.admit(item())
		sync.handle_session_messages("s", projection.page("s", { { id = "q", type = "user", text = "Queued text" } }))
		start(); callbacks.inbox(nil, { item() }); callbacks.history(nil, {})
		assert.equals("Queued text", sync.get_parts("q")[1].text)
		assert.is_true(sync.get_message("s", "q").provisional)
		assert.equals("queued", pending.get("s", "q").status)
		assert.equals("Queued · cancel from the palette", selectors.prompt_status("s", "q"))
	end)

	it("materializes the server inbox in a fresh client, preserving attachments", function()
		start(); callbacks.history(nil, {}); callbacks.inbox(nil, { item() })
		assert.equals("Queued text", sync.get_parts("q")[1].text)
		assert.equals("file:///fixture.txt", sync.get_message("s", "q")._v2.files[1].uri)
	end)

	for _, terminal in ipairs({ "cancelled", "delivered" }) do
		it("does not resurrect an unknown item after an earlier " .. terminal .. " event", function()
			start()
			bus.emit("v2_event", { id = "evt_end", created = 20, type = "session.inbox." .. terminal,
				data = { sessionID = "s", inboxID = "q" } })
			callbacks.inbox(nil, { item() }); callbacks.history(nil, {})
			assert.equals(terminal, pending.get("s", "q").status)
			assert.is_nil(sync.get_message("s", "q"))
			assert.is_nil(selectors.prompt_status("s", "q"))
		end)
	end

	it("uses native history over a stale inbox snapshot", function()
		pending.admit(item()); start()
		callbacks.inbox(nil, { item() })
		callbacks.history(nil, projection.page("s", { { id = "q", type = "user", text = "Delivered", time = { created = 30 } } }))
		assert.equals("delivered", pending.get("s", "q").status)
		assert.equals("Delivered", sync.get_parts("q")[1].text)
		assert.is_nil(selectors.prompt_status("s", "q"))
	end)

	it("keeps an external steering change newer than the inbox read", function()
		pending.admit(item()); start()
		bus.emit("v2_event", { id = "evt_change", created = 20, type = "session.inbox.delivery.changed",
			data = { sessionID = "s", inboxID = "q", delivery = "steer" } })
		callbacks.history(nil, {}); callbacks.inbox(nil, { item() })
		assert.equals("steer", pending.get("s", "q").inbox.delivery)
		assert.equals("Steering pending", selectors.prompt_status("s", "q"))
	end)

	it("does not infer cancellation from absence in two non-atomic snapshots", function()
		pending.admit(item()); start(); callbacks.history(nil, {}); callbacks.inbox(nil, {})
		assert.equals("queued", pending.get("s", "q").status)
		assert.is_true(pending.get("s", "q").delivery_missing)
		assert.is_not_nil(sync.get_message("s", "q"))
		assert.equals("Delivery unknown · reconnect to check", selectors.prompt_status("s", "q"))
	end)

	it("preserves a known inbox item when that endpoint fails", function()
		pending.admit(item()); start(); callbacks.history(nil, {}); callbacks.inbox({ status = 500, message = "Unavailable" })
		assert.equals("queued", pending.get("s", "q").status)
		assert.is_not_nil(sync.get_message("s", "q"))
	end)
end)
