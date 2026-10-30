local state, sync, bus = require("opencode.state"), require("opencode.sync"), require("opencode.events.bus")
local client, pending = require("opencode.client"), require("opencode.session.pending")
local permissions, forms = require("opencode.permission.state"), require("opencode.question.state")

local function reset()
	bus.clear(); state.reset(); sync.clear_all(); pending.clear_all(); permissions.clear_all(); forms.clear_all()
end

local function stub(saved, name, fn)
	if saved[name] == nil then saved[name] = client[name] end
	client[name] = fn
end

describe("event pipeline request and memory bounds", function()
	local saved
	before_each(function()
		reset(); saved = {}
		state.upsert_session({ id = "a", directory = "/project" })
		state.upsert_session({ id = "b", directory = "/project" })
		state.set_session("a", "A")
	end)
	after_each(function()
		for name, original in pairs(saved) do client[name] = original end
		reset()
	end)

	it("recovers reviews only for a newly relevant tree", function()
		local calls = {}
		stub(saved, "review_rpc", function(method, _, directory) calls[#calls + 1] = method .. ":" .. directory end)
		require("opencode.events.handlers.review").setup(bus)
		bus.emit("connected", {})
		assert.equals(2, #calls)
		calls = {}
		state.set_session("b", "B")
		bus.emit("session_change", { id = "b", previous_id = "a", reason = "pane_focus" })
		assert.same({}, calls)
		bus.emit("session_change", { id = "b", previous_id = "a", reason = "session_switch" })
		assert.equals(1, #calls)
		calls = {}
		state.upsert_session({ id = "c", directory = "/elsewhere" })
		state.set_session("c", "C")
		bus.emit("session_change", { id = "c", previous_id = "b", reason = "pane_focus" })
		assert.same({ "capabilities:/elsewhere" }, calls)
	end)

	it("lists interactions only for the selected session tree", function()
		local listed = {}
		stub(saved, "list_permissions", function(opts) listed[#listed + 1] = opts.session_id end)
		stub(saved, "list_questions", function() end)
		require("opencode.events.handlers.interactions").setup(bus)
		bus.emit("session.selected", { sessionID = "b", previousSessionID = "a" })
		assert.same({ "b" }, listed)
	end)

	it("forgets finished interaction IDs when their session closes", function()
		require("opencode.events.handlers.interactions").setup(bus)
		local function event(kind, data) bus.emit("server_interaction", { id = "evt", type = kind, created = 1, data = data }) end
		local asked = { id = "p", sessionID = "a", action = "read", resources = {} }
		event("permission.replied", { requestID = "p", sessionID = "a", reply = "once" })
		event("permission.asked", asked)
		assert.is_nil(permissions.get_permission("p"))
		bus.emit("session.closed", { session_id = "a", session_ids = { "a" } })
		event("permission.asked", asked)
		assert.equals("pending", permissions.get_permission("p").status)
		-- A reply for a session this client does not track leaves no tombstone.
		event("permission.replied", { requestID = "q", sessionID = "z", reply = "once" })
		state.upsert_session({ id = "z" }); state.set_session("z", "Z")
		event("permission.asked", { id = "q", sessionID = "z", action = "read", resources = {} })
		assert.equals("pending", permissions.get_permission("q").status)
	end)

	it("forgets finished policy gates when their session closes", function()
		local lookups = 0
		stub(saved, "get_permission", function() lookups = lookups + 1 end)
		require("opencode.events.handlers.review").setup(bus)
		local function policy(status)
			bus.emit("server_interaction", { type = "rpc.opencode_nvim.policy.updated", data = { policy = {
				protocolVersion = 2, sessionID = "a", gateID = "g", status = status,
				request = { id = "perm" }, location = { directory = "/project" } } } })
		end
		policy("settled"); policy("pending")
		assert.equals(0, lookups)
		bus.emit("session.closed", { session_id = "a", session_ids = { "a" } })
		policy("pending")
		assert.equals(1, lookups)
	end)

	it("retries only catalogs that never loaded for an unchanged location", function()
		local handlers, calls, callbacks = {}, {}, {}
		for domain, method in pairs({ providers = "get_config_providers", agents = "list_agents", commands = "list_commands",
			skills = "list_skills", mcp = "get_mcp_status", config = "get_config" }) do
			stub(saved, method, function(cb) calls[#calls + 1] = domain; callbacks[domain] = cb end)
		end
		require("opencode.events.handlers.sync_data").setup({
			on = function(event, callback) handlers[event] = callback end, emit = function() end })
		state.set_connection("connected")
		handlers.connected()
		assert.equals(6, #calls)
		calls = {}
		handlers.session_change({ reason = "session_switch" })
		assert.same({}, calls, "requests in flight are not repeated")
		local data = { providers = { providers = {}, default = {} }, agents = {}, commands = {}, skills = {}, config = {} }
		for domain, cb in pairs(callbacks) do
			if domain == "mcp" then cb({ message = "unavailable" }) else cb(nil, data[domain]) end
		end
		handlers.session_change({ reason = "session_switch" })
		assert.same({ "mcp" }, calls)
	end)

	it("keeps a bounded set of delivered tombstones from history", function()
		local messages = {}
		for i = 1, 500 do messages[i] = { info = { id = string.format("msg_%04d", i), role = "user" } } end
		pending.admit({ sessionID = "a", id = "queued", type = "user", delivery = "queue", payload = { text = "later" } })
		pending.reconcile_history("a", messages)
		pending.reconcile_history("a", messages)
		assert.is_true(vim.tbl_count(pending.list("a")) <= 65)
		assert.equals("delivered", pending.get("a", "msg_0500").status)
		assert.is_nil(pending.get("a", "msg_0001"))
		for i = 1, 300 do pending.update("a", "evt_" .. i, { status = i % 2 == 0 and "delivered" or "cancelled" }) end
		assert.is_true(vim.tbl_count(pending.list("a")) <= 129)
		assert.equals("cancelled", pending.get("a", "evt_299").status)
		assert.equals("queued", pending.get("a", "queued").status)
	end)
end)
