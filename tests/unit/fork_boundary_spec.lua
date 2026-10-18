local actions = require("opencode.actions")
local client = require("opencode.client")
local lifecycle = require("opencode.lifecycle")
local session = require("opencode.session")
local state = require("opencode.state")
local api = require("opencode.client.api")
local sync = require("opencode.sync")
local bus, server = require("opencode.events.bus"), require("opencode.events.handlers.server")

describe("session fork boundary", function()
	local original_request, original_fork, original_connection, original_schedule

	before_each(function()
		state.reset()
		sync.clear_all(); bus.clear(); server.clear()
		original_request = api.request
		original_fork = client.fork_session
		original_connection = lifecycle.ensure_connected
		original_schedule = vim.schedule
		vim.schedule = function(callback) callback() end
	end)

	after_each(function()
		api.request = original_request
		client.fork_session = original_fork
		lifecycle.ensure_connected = original_connection
		vim.schedule = original_schedule
		state.reset()
		sync.clear_all(); bus.clear(); server.clear()
	end)

	it("can remember a completed fork without switching the active session", function()
		session.set_active("ses_other", "Other session")
		local forked = { id = "ses_fork", title = "Forked session", location = { directory = "/project" } }
		local remembered = actions.remember_session(forked)
		assert.equals("ses_fork", remembered.id)
		assert.equals("ses_fork", state.get_session_record("ses_fork").id)
		assert.equals("ses_other", state.get_session().id)
		assert.is_false(state.is_runtime_session("ses_fork"))
	end)

	it("forwards a selected boundary through the action layer", function()
		local called
		lifecycle.ensure_connected = function(callback) callback() end
		client.fork_session = function(session_id, opts, callback)
			called = { session_id = session_id, before = opts.before }
			callback(nil, { id = "ses_fork" })
		end
		local result
		actions.fork_session("ses_original", { before = "msg_selected" }, function(err, forked)
			assert.is_nil(err)
			result = forked
		end)
		assert.same({ session_id = "ses_original", before = "msg_selected" }, called)
		assert.equals("ses_fork", result.id)
	end)
	it("serializes selected and whole-session fork boundaries", function()
		for _, opts in ipairs({ { before = "msg_selected" }, {} }) do
			local operation, args
			api.request = function(name, request, callback)
				operation, args = name, request
				callback(nil, { id = "ses_fork" })
			end
			local result
			client.fork_session("ses_original", opts, function(_, forked) result = forked end)
			assert.equals("session_fork", operation)
			assert.equals("ses_original", args.path.sessionID)
			assert.equals(opts.before, args.body.before)
			assert.equals(opts.before and '{"before":"msg_selected"}' or "{}", vim.json.encode(args.body))
			assert.equals("ses_fork", result.id)
		end
	end)

	it("keeps native ancestry separate from a fork source in DTOs and later fork events", function()
		server.setup(bus)
		for _, id in ipairs({ "source", "native-parent" }) do session.remember({ id = id }, { touch = false }) end
		session.remember({ id = "child-fork", parentID = "native-parent", fork = { sessionID = "source" } }, { touch = false })
		bus.emit("server_event", { id = "evt-fork", type = "session.forked", created = 10,
			data = { sessionID = "child-fork", parentID = "source", boundary = { type = "after", messageID = "message" } } })
		session.remember({ id = "child-fork", title = "Partial metadata" }, { touch = false })
		assert.equals("native-parent", state.get_session_parent_id("child-fork"))
		assert.equals("source", state.get_session_fork_source_id("child-fork"))
		assert.same({ "native-parent", "child-fork" }, sync.collect_session_tree("native-parent"))
		assert.same({ "source" }, sync.collect_session_tree("source"))
	end)

end)
