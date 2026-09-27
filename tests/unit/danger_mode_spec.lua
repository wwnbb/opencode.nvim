local app = require("opencode")
local state = require("opencode.state")
local permissions = require("opencode.permission.state")
local edits = require("opencode.edit.state")
local changes = require("opencode.artifact.changes")
local danger = require("opencode.permission.danger")
local client = require("opencode.client")

describe("danger mode", function()
	local respond, accept, notify, path, approved
	local function clear()
		permissions.clear_all()
		edits.clear_all()
		changes.clear()
		danger.clear()
		state.reset()
	end
	before_each(function()
		clear()
		respond, accept, notify = client.respond_permission, changes.accept, vim.notify
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
		client.respond_permission, changes.accept, vim.notify = respond, accept, notify
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
		permissions.add_permission("pending", "session", "bash", {})
		assert.equals(1, danger.approve_pending())
		assert.equals(1, #approved)
		assert.equals("pending", approved[1].id)
		assert.equals("once", approved[1].reply)
		assert.is_true(vim.wait(500, function()
			return permissions.get_permission("pending").status == "approved"
		end, 10))
	end)

	it("leaves failed local edits pending without sending approval", function()
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
end)
