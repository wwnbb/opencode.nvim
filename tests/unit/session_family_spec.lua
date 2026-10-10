local state, sync = require("opencode.state"), require("opencode.sync")
local actions, client = require("opencode.actions"), require("opencode.client")
local pending, lifecycle = require("opencode.session.pending"), require("opencode.lifecycle")

describe("native session family", function()
	local saved, records, pages, calls
	local function receive(run)
		local result
		run(function(err, family, root) result = { err = err, family = family, root = root } end)
		assert.is_true(vim.wait(500, function() return result ~= nil end, 1))
		return result
	end
	before_each(function()
		state.reset(); sync.clear_all(); pending.clear_all()
		state.set_session("neighbor", "Neighbor")
		state.set_session("grandchild", "Grandchild", { runtime = false })
		saved = { get_session = client.get_session, list_sessions = client.list_sessions,
			get_session_statuses = client.get_session_statuses, abort_session = client.abort_session,
			ensure_connected = lifecycle.ensure_connected }
		records = {
			root = { id = "root", title = "Root", location = { directory = "/root" } },
			child = { id = "child", parentID = "root", title = "Child", location = { directory = "/root" } },
			sibling = { id = "sibling", parentID = "root", title = "Sibling", location = { directory = "/root" } },
			grandchild = { id = "grandchild", parentID = "child", title = "Grandchild", location = { directory = "/root" } },
		}
		pages, calls = {}, {}
		lifecycle.ensure_connected = function(callback) callback() end
		client.get_session = function(id, callback)
			if records[id] then callback(nil, vim.deepcopy(records[id])) else callback({ message = "Session not found", status = 404 }) end
		end
		client.list_sessions = function(opts, callback)
			pages[#pages + 1] = vim.deepcopy(opts)
			if opts.parentID == "root" then
				if not opts.cursor then callback(nil, { records.child }, { cursor = { next = "older" } })
				else callback(nil, { records.child, records.sibling }, { cursor = {} }) end
			elseif opts.parentID == "child" then callback(nil, { records.grandchild }, { cursor = {} })
			else callback(nil, {}, { cursor = {} }) end
		end
		client.get_session_statuses = function(callback) callback(nil, { child = { type = "busy" } }) end
		client.abort_session = function(id, callback) calls[#calls + 1] = id; callback(nil, { interrupted = true }) end
	end)
	after_each(function()
		for name, fn in pairs(saved) do
			if name == "ensure_connected" then lifecycle[name] = fn else client[name] = fn end
		end
		state.reset(); sync.clear_all(); pending.clear_all()
	end)

	it("finds the native root from a child and loads every paginated descendant without changing tabs", function()
		local order = state.get_runtime_session_order()
		local result = receive(function(callback) actions.get_session_family("grandchild", callback) end)
		assert.is_nil(result.err)
		assert.equals("root", result.root)
		assert.same({ "root", "child", "sibling", "grandchild" }, vim.tbl_map(function(record) return record.id end, result.family))
		assert.equals(5, #pages)
		assert.equals("older", pages[2].cursor)
		assert.equals("grandchild", state.get_session().id)
		assert.same(order, state.get_runtime_session_order())
		assert.equals("busy", state.get_session_status("child").type)
		assert.equals("idle", state.get_session_status("sibling").type)
		assert.equals("root", state.get_session_record("child").parentID)
	end)

	it("reports a parent cycle or a missing ancestor instead of returning a partial family", function()
		records.root.parentID = "grandchild"
		local cycle = receive(function(callback) actions.get_session_family("grandchild", callback) end)
		assert.matches("cycle", cycle.err.message)
		assert.is_nil(cycle.family)
		records.root.parentID = "missing"
		local missing = receive(function(callback) actions.get_session_family("grandchild", callback) end)
		assert.equals(404, missing.err.status)
		assert.is_nil(missing.family)
	end)

	it("preserves a newer native metadata event while an ancestor response is pending", function()
		local deferred, original = nil, client.get_session
		client.get_session = function(id, callback)
			if id == "child" and not deferred then deferred = callback else original(id, callback) end
		end
		local result
		actions.get_session_family("grandchild", function(err, family) result = { err = err, family = family } end)
		state.upsert_session({ id = "child", parentID = "root", title = "Newer title" }, { touch = false })
		deferred(nil, records.child)
		assert.is_true(vim.wait(500, function() return result ~= nil end, 1))
		assert.is_nil(result.err)
		assert.equals("Newer title", state.get_session_record("child").title)
	end)

	it("does not resurrect a deleted ancestor or continue a previous connection's response", function()
		local deferred
		client.get_session = function(id, callback) deferred = callback end
		local result
		require("tests.helpers.schedule").with(function(flush)
			actions.get_session_family("child", function(err) result = err end)
			pending.clear_session("child")
			deferred(nil, records.child)
			assert.is_nil(state.get_session_record("child"))
			assert.equals(0, #pages)
			pending.invalidate()
			actions.get_session_family("grandchild", function(err) result = err end)
			pending.invalidate()
			deferred(nil, records.grandchild)
			flush()
			assert.is_nil(state.get_session_record("grandchild").parentID)
			assert.equals(0, #pages)
		end)
	end)

	it("preserves an SSE status that arrives before the active-session snapshot", function()
		local deferred, result
		client.get_session_statuses = function(callback) deferred = callback end
		actions.get_session_family("grandchild", function(err, family) result = { err = err, family = family } end)
		require("opencode.session").set_session_status("child", { type = "busy" })
		deferred(nil, {})
		assert.is_true(vim.wait(500, function() return result ~= nil end, 1))
		assert.equals("busy", state.get_session_status("child").type)
	end)

	it("interrupts only the addressed child without switching the current view or guessing idle", function()
		state.set_session_status("child", { type = "busy" })
		local result = receive(function(callback) actions.interrupt_session("child", callback) end)
		assert.is_nil(result.err)
		assert.same({ "child" }, calls)
		assert.equals("grandchild", state.get_session().id)
		assert.equals("busy", state.get_session_status("child").type)
	end)
end)
