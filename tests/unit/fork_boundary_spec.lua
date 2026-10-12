local actions = require("opencode.actions")
local client = require("opencode.client")
local lifecycle = require("opencode.lifecycle")
local session = require("opencode.session")
local state = require("opencode.state")
local v2 = require("opencode.client.api")

describe("session fork boundary", function()
	local original_request, original_fork, original_connection, original_schedule

	before_each(function()
		state.reset()
		original_request = v2.request
		original_fork = client.fork_session
		original_connection = lifecycle.ensure_connected
		original_schedule = vim.schedule
		vim.schedule = function(callback) callback() end
	end)

	after_each(function()
		v2.request = original_request
		client.fork_session = original_fork
		lifecycle.ensure_connected = original_connection
		vim.schedule = original_schedule
		state.reset()
	end)

	it("sends the selected user message as an exclusive before boundary", function()
		local operation, args
		v2.request = function(name, request, callback)
			operation, args = name, request
			callback(nil, { id = "ses_fork" })
		end
		local result
		client.fork_session("ses_original", { before = "msg_selected" }, function(_, forked) result = forked end)
		assert.equals("session_fork", operation)
		assert.equals("ses_original", args.path.sessionID)
		assert.same({ before = "msg_selected" }, args.body)
		assert.equals("ses_fork", result.id)
	end)

	it("encodes a whole-session fork request as an empty object", function()
		local body
		v2.request = function(_, args) body = args.body end
		client.fork_session("ses_original", {}, function() end)
		assert.equals("{}", vim.json.encode(body))
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
end)
