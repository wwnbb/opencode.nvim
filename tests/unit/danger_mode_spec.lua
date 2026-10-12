local app = require("opencode")
local state = require("opencode.state")
local permissions = require("opencode.permission.state")
local edits = require("opencode.edit.state")
local changes = require("opencode.artifact.changes")
local danger = require("opencode.permission.danger")
local client = require("opencode.client")

describe("danger mode", function()
	local respond, review_rpc, accept, notify, path, approved
	local function clear()
		permissions.clear_all()
		edits.clear_all()
		changes.clear()
		danger.clear()
		state.reset()
	end
	before_each(function()
		clear()
		respond, review_rpc, accept, notify = client.respond_permission, client.review_rpc, changes.accept, vim.notify
		approved, path = {}, nil
		client.respond_permission = function(id, reply, opts, callback)
			approved[#approved + 1] = { id = id, reply = reply, opts = opts }
			callback(nil, true)
		end
	end)
	after_each(function()
		-- Resolve or invalidate queued approvals before resetting their stores.
		require("opencode.session.pending").clear_all()
		local drained = false
		vim.schedule(function() drained = true end)
		vim.wait(500, function() return drained end, 10)
		client.respond_permission, client.review_rpc, changes.accept, vim.notify = respond, review_rpc, accept, notify
		clear()
		if path then vim.fn.delete(path) end
	end)

	it("enables and disables through the public API", function()
		app.enable_danger_mode({ silent = true })
		assert.is_true(app.is_danger_mode_enabled())
		app.disable_danger_mode({ silent = true })
		assert.is_false(app.is_danger_mode_enabled())
	end)

	it("approves an existing pending permission once", function()
		state.set_session("session", "Session")
		permissions.add_permission("pending", "session", "bash", {})
		assert.equals(1, danger.approve_pending())
		assert.equals(1, #approved)
		assert.equals("pending", approved[1].id)
		assert.equals("once", approved[1].reply)
		assert.is_true(vim.wait(500, function()
			return permissions.get_permission("pending").status == "approved"
		end, 10))
	end)

	it("uses the permission's owning session and forwards its approval message", function()
		permissions.add_permission("pending", "owner", "bash", {})
		local handled, queued = danger.approve("pending", { session_id = "other", message = "Approved" })
		assert.is_true(handled)
		assert.is_true(queued)
		assert.same({ id = "pending", reply = "once", opts = { session_id = "owner", message = "Approved" } }, approved[1])
	end)

	for _, reset in ipairs({ "close", "reconnect", "owner" }) do
		for _, failed in ipairs({ false, true }) do
			it("owns each approval attempt after " .. reset .. " despite an old " .. (failed and "failure" or "success"), function()
				local callbacks, notices = {}, {}
				client.respond_permission = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
				vim.notify = function(message) notices[#notices + 1] = message end
				state.set_session("session", "Session")
				permissions.add_permission("pending", "session", "bash", {})
				assert.equals(1, danger.approve_pending())
				assert.equals(0, danger.approve_pending())
				local pending = require("opencode.session.pending")
				if reset == "close" then pending.clear_session("session")
				elseif reset == "reconnect" then pending.invalidate()
				else permissions.clear_all(); permissions.add_permission("pending", "session", "bash", {}) end
				assert.equals(1, danger.approve_pending())
				assert.equals(2, #callbacks)
				callbacks[1](failed and { message = "Old request failed" } or nil)
				vim.wait(20)
				assert.equals("pending", permissions.get_permission("pending").status)
				assert.same({}, notices)
				assert.equals(0, danger.approve_pending())
				assert.equals(2, #callbacks)
				callbacks[2](nil)
				assert.is_true(vim.wait(500, function() return permissions.get_permission("pending").status == "approved" end, 10))
			end)
		end
	end

	for _, first in ipairs({ "manual", "auto" }) do
		it("sends only one permission reply when " .. first .. " starts first", function()
			local callbacks = {}
			client.respond_permission = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
			state.set_session("session", "Session")
			permissions.add_permission("pending", "session", "bash", {})
			local actions = require("opencode.actions")
			local function manual()
				return actions.respond_permission("pending", "reject", {}, function(err)
					if not err then permissions.mark_rejected("pending") end
				end)
			end
			if first == "manual" then
				manual()
				local handled, queued = danger.approve("pending")
				assert.is_true(handled); assert.is_false(queued)
			else
				danger.approve("pending")
				assert.is_false(manual())
			end
			assert.equals(1, #callbacks)
			assert.is_true(permissions.get_permission("pending").submitting)
			callbacks[1](nil)
			assert.is_true(vim.wait(500, function()
				return permissions.get_permission("pending").status == (first == "manual" and "rejected" or "approved")
			end, 10))
		end)
	end
	it("finishes an in-flight approval across disabling and enabling danger mode", function()
		local callbacks = {}
		client.respond_permission = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
		state.set_session("session", "Session")
		permissions.add_permission("pending", "session", "bash", {})
		app.enable_danger_mode({ silent = true })
		app.disable_danger_mode({ silent = true })
		app.enable_danger_mode({ silent = true })
		assert.equals(1, #callbacks)
		callbacks[1](nil)
		assert.is_true(vim.wait(500, function() return permissions.get_permission("pending").status == "approved" end, 10))
	end)
	it("unlocks a failed approval after disabling danger mode and allows a retry", function()
		local callbacks = {}
		client.respond_permission = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
		vim.notify = function() end
		state.set_session("session", "Session")
		local item = permissions.add_permission("pending", "session", "bash", {})
		app.enable_danger_mode({ silent = true })
		assert.is_true(item.submitting)
		app.disable_danger_mode({ silent = true })
		callbacks[1]({ message = "Reply failed" })
		assert.is_true(vim.wait(500, function() return not item.submitting and item.error ~= nil end, 10))
		app.enable_danger_mode({ silent = true })
		assert.equals(2, #callbacks)
		assert.is_true(item.submitting)
		callbacks[2](nil)
		assert.is_true(vim.wait(500, function() return item.status == "approved" end, 10))
	end)

	for _, failed in ipairs({ false, true }) do
		it("retries a recovered permission after reconnect despite an old " .. (failed and "failure" or "success"), function()
			local callbacks = {}
			client.respond_permission = function(_, _, _, callback) callbacks[#callbacks + 1] = callback end
			vim.notify = function() end
			state.set_session("session", "Session")
			app.enable_danger_mode({ silent = true })
			local handler = require("opencode.events.handlers.permission_flow.non_edit")
			local request = { id = "pending", session_id = "session", type = "bash", metadata = {} }
			local emitted = {}
			local events = { emit = function(name) emitted[#emitted + 1] = name end }
			local logger = { debug = function() end, info = function() end }
			handler.handle(events, request, logger)
			handler.handle(events, request, logger)
			assert.equals(1, #callbacks)
			local item = permissions.get_permission("pending")
			permissions.set_message("pending", "Keep my note")
			require("opencode.session.pending").invalidate()
			request.metadata = { tool = "bash", input = { command = "echo recovered" } }
			handler.handle(events, request, logger)
			assert.equals(item, permissions.get_permission("pending"))
			assert.equals("Keep my note", item.message)
			assert.equals("bash", item.tool_name)
			assert.same({ command = "echo recovered" }, item.tool_input)
			assert.equals(2, #callbacks)
			callbacks[1](failed and { message = "Old reply failed" } or nil)
			vim.wait(20)
			assert.equals("pending", item.status)
			assert.is_true(item.submitting)
			callbacks[2](nil)
			assert.is_true(vim.wait(500, function() return item.status == "approved" end, 10))
			handler.handle(events, request, logger)
			assert.equals(2, #callbacks)
			assert.same({ "interaction_changed" }, emitted)
		end)
	end

	it("leaves failed local edits pending without sending approval", function()
		state.set_session("session", "Session")
		path = vim.fn.tempname()
		vim.fn.writefile({ "before" }, path)
		edits.add_edit("failed", "session", {
			{ filePath = path, before = "before\n", after = "after\n" },
		}, {})
		local edit = edits.get_edit("failed")
		changes.accept = function(id, opts)
			if id == edit.files[1].change_id then return false, "local write failed" end
			return accept(id, opts)
		end
		local notifications = {}
		vim.notify = function(message) notifications[#notifications + 1] = message end
		assert.equals(0, danger.approve_pending())
		assert.same({}, approved)
		assert.equals("pending", edit.files[1].status)
		assert.is_truthy(notifications[1]:find("local write failed", 1, true))
	end)

	it("does not approve hidden permissions or reviews after closing their tab", function()
		local session = require("opencode.session")
		state.set_config({ server = { shared_filesystem = false } })
		state.set_connection("connected")
		state.set_session("hidden", "Hidden")
		permissions.add_permission("hidden-permission", "hidden", "shell", {})
		edits.add_edit("hidden-review", "hidden", {
			{ fileID = "hidden-file", filePath = "/tmp/hidden-file", before = "before", after = "after", type = "update" },
		}, {
			transport = "review_rpc", review_id = "hidden-review", revision = 1,
			location = { directory = "/tmp" }, native_review = { status = "pending" },
		})
		local review_calls = 0
		client.review_rpc = function() review_calls = review_calls + 1 end

		assert.is_true(session.close("hidden", { silent = true }))
		state.set_session("visible", "Visible")
		app.enable_danger_mode({ silent = true })

		assert.same({}, approved)
		assert.equals(0, review_calls)
		assert.equals("pending", permissions.get_permission("hidden-permission").status)
		assert.equals("pending", edits.get_edit("hidden-review").files[1].status)
	end)
end)
