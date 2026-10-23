local state, sync = require("opencode.state"), require("opencode.sync")
local locks, selectors = require("opencode.session.lock"), require("opencode.selectors")
local server = require("opencode.events.handlers.server")
local client = require("opencode.client")

describe("native child execution selection", function()
	local handlers, saved
	local function event(kind, data)
		handlers.server_event({ type = kind, data = data, created = 200 })
	end
	before_each(function()
		server.clear(); state.reset(); sync.clear_all(); locks.clear_all()
		require("opencode.session.pending").clear_all()
		handlers = {}
		server.setup({ on = function(name, callback) handlers[name] = callback end, emit = function() end })
		saved = { get_session = client.get_session, get_messages = client.get_messages, get_inbox = client.get_inbox }
		state.set_session("root", "Root")
		state.upsert_session({ id = "child", parentID = "root", agent = "explore",
			model = { providerID = "old", id = "original", variant = "deep" } }, { touch = false })
		locks.set("child", { agent = "explore", model = { providerID = "old", modelID = "original" }, variant = "deep",
			child_session = state.get_session_record("child") })
	end)
	after_each(function()
		for name, fn in pairs(saved) do client[name] = fn end
		server.clear(); state.reset(); sync.clear_all(); locks.clear_all()
		require("opencode.session.pending").clear_all()
	end)

	local function recover()
		local reply
		client.get_session = function(_, callback) reply = callback end
		client.get_messages = function(_, _, callback) callback(nil, {}) end
		client.get_inbox = function(_, callback) callback(nil, {}) end
		handlers.session_reconcile({ session_id = "child" })
		assert.is_true(vim.wait(1000, function() return reply ~= nil end, 10))
		return reply
	end

	it("refreshes an existing child lock from recovered native metadata", function()
		local reply = recover()
		reply(nil, { id = "child", agent = "build", model = { providerID = "new", id = "recovered" } })
		local selection = selectors.send_selection({ session_id = "child" })
		assert.equals("build", selection.agent)
		assert.equals("recovered", selection.model.modelID)
		assert.is_nil(selection.variant)
	end)

	it("keeps a newer native selection when an older recovery response arrives", function()
		local reply = recover()
		event("session.model.selected", { sessionID = "child", model = { providerID = "new", id = "live" } })
		reply(nil, { id = "child", model = { providerID = "old", id = "stale" } })
		assert.equals("live", selectors.send_selection({ session_id = "child" }).model.modelID)
	end)

	it("does not apply another session's recovered selection to a child", function()
		local original, reply = locks.get("child"), recover()
		reply(nil, { id = "other", agent = "build", model = { providerID = "new", id = "wrong" } })
		assert.same(original, locks.get("child"))
	end)

	it("updates the locked model atomically and clears an omitted variant", function()
		local selected = { providerID = "new", id = "current" }
		event("session.model.selected", { sessionID = "child", model = selected })
		local selection = selectors.send_selection({ session_id = "child" })
		assert.same({ providerID = "new", modelID = "current" }, selection.model)
		assert.is_nil(selection.variant)
		assert.equals("explore", selection.agent)
		assert.same(selected, locks.get("child").child_session.model)
		assert.is_true(locks.is_locked("child"))
		assert.equals("root", state.get_session().id)
	end)

	it("updates the locked agent without changing its model or allowing local overrides", function()
		event("session.agent.selected", { sessionID = "child", agent = "build" })
		local choices = require("opencode.session.selection")
		choices.choose("child", "agent", "plan")
		choices.choose("child", "model", { providerID = "override", modelID = "override" })
		assert.is_nil(choices.pending_values("child"))
		local selection = selectors.send_selection({ session_id = "child", agent = "plan",
			model = { providerID = "override", modelID = "override" }, variant = "override" })
		assert.equals("build", selection.agent)
		assert.same({ providerID = "old", modelID = "original" }, selection.model)
		assert.equals("deep", selection.variant)
		assert.equals("build", locks.get("child").child_session.agent)
		assert.is_true(locks.is_locked("child"))
	end)

	it("resolves a pending child only when its native model arrives", function()
		locks.set("child", { pending = true, error = "Model unavailable" })
		event("session.agent.selected", { sessionID = "child", agent = "explore" })
		assert.is_true(selectors.send_selection({ session_id = "child" }).blocked)
		event("session.model.selected", { sessionID = "child", model = { providerID = "new", id = "resolved", variant = "fast" } })
		local selection = selectors.send_selection({ session_id = "child" })
		assert.is_nil(selection.blocked)
		assert.is_nil(locks.get("child").pending)
		assert.is_nil(locks.get("child").error)
		assert.equals("explore", selection.agent)
		assert.equals("fast", selection.variant)
		assert.equals("resolved", selection.model.modelID)
	end)

	it("keeps unrelated events and sessions from changing or creating execution locks", function()
		local original = locks.get("child")
		event("session.model.selected", { sessionID = "other", model = { providerID = "new", id = "other" } })
		event("session.agent.selected", { sessionID = "other", agent = "build" })
		event("session.renamed", { sessionID = "child", title = "Renamed" })
		assert.same(original, locks.get("child"))
		assert.is_nil(locks.get("other"))
	end)

	it("does not use incomplete native selections to unblock a pending child", function()
		locks.set("child", { pending = true, error = "Model unavailable" })
		event("session.model.selected", { sessionID = "child", model = { id = "missing-provider" } })
		event("session.model.selected", { sessionID = "child", model = { providerID = "", id = "empty-provider" } })
		event("session.agent.selected", { sessionID = "child", agent = "" })
		assert.is_nil(locks.get("child").model)
		assert.is_nil(locks.get("child").agent)
		assert.is_true(selectors.send_selection({ session_id = "child" }).blocked)
	end)
end)
