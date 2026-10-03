local owner = require("opencode.permission.state")
local chat = require("opencode.ui.chat.permissions")
local actions = require("opencode.actions")
local events = require("opencode.events")
local render = require("opencode.ui.chat.render_coordinator")
local input = require("opencode.ui.input")
local chat_view = require("opencode.ui.chat")

describe("permission reply callback ownership", function()
	local respond, schedule, notify, emit, request, show, focus, callbacks, queued, notices, emitted
	before_each(function()
		owner.clear_all()
		respond, schedule, notify, emit, request = actions.respond_permission, vim.schedule, vim.notify, events.safe_emit, render.request
		show, focus = input.show, chat_view.focus
		chat_view.focus = function() end
		callbacks, queued, notices, emitted = {}, {}, {}, {}
		actions.respond_permission = function(_, reply, _, callback)
			callbacks[#callbacks + 1] = { reply = reply, done = callback }
		end
		vim.schedule = function(callback) queued[#queued + 1] = callback end
		vim.notify = function(message) notices[#notices + 1] = message end
		events.safe_emit = function(name, data) emitted[#emitted + 1] = { name, data } end
		render.request = function() end
	end)
	after_each(function()
		actions.respond_permission, vim.schedule, vim.notify, events.safe_emit, render.request = respond, schedule, notify, emit, request
		input.show, chat_view.focus = show, focus
		owner.clear_all()
	end)

	local function submit(reject)
		local item = owner.add_permission("permission", "session", "bash")
		if reject then chat.handle_permission_reject("permission")
		else chat.handle_permission_confirm("permission", item) end
		return item
	end

	for _, reject in ipairs({ false, true }) do
		for _, failed in ipairs({ false, true }) do
			it("ignores queued " .. (reject and "reject" or "approval") .. (failed and " failure" or " success") .. " after replacement", function()
				submit(reject)
				callbacks[1].done(failed and { message = "Old request failed" } or nil)
				owner.clear_all()
				local replacement = owner.add_permission("permission", "session", "bash")
				assert.is_true(owner.begin_submission("permission"))
				for _, callback in ipairs(queued) do callback() end
				assert.equals("pending", replacement.status)
				assert.is_true(replacement.submitting)
				assert.same({}, notices)
				assert.same({}, emitted)
			end)
		end

		for _, failed in ipairs({ false, true }) do
			it("ignores an invalidated queued " .. (reject and "reject" or "approval") .. (failed and " failure" or " success"), function()
				local item = submit(reject)
				assert.is_true(owner.begin_submission("permission"))
				callbacks[1].done(failed and { message = "Old request failed" } or nil)
				require("opencode.session.pending").clear_session("session")
				for _, callback in ipairs(queued) do callback() end
				assert.equals("pending", item.status)
				assert.is_true(item.submitting)
				assert.same({}, notices)
				assert.same({}, emitted)
			end)
		end

		it("completes an owned " .. (reject and "rejection" or "approval"), function()
			local item = submit(reject)
			callbacks[1].done(nil)
			for _, callback in ipairs(queued) do callback() end
			local status = reject and "rejected" or "approved"
			assert.equals(status, item.status)
			assert.same({
				{ "permission_" .. status, reject and { permission_id = "permission" } or { permission_id = "permission", reply = "once" } },
				{ "interaction_changed", { kind = "permission", action = status, id = "permission" } },
			}, emitted)
		end)
	end

	for _, method in ipairs({ "on_send", "on_cancel" }) do
		for _, reset in ipairs({ "owner", "close", "reconnect" }) do
			it("ignores an old message input " .. method .. " after " .. reset, function()
				local shown
				input.show = function(opts) shown = opts end
				owner.add_permission("permission", "session", "bash")
				chat.handle_permission_message("permission")
				assert.is_function(shown[method])
				local pending = require("opencode.session.pending")
				if reset == "owner" then owner.clear_all(); owner.add_permission("permission", "session", "bash")
				elseif reset == "close" then pending.clear_session("session")
				else pending.invalidate() end
				owner.set_message("permission", "New note")
				shown[method]("Old note")
				assert.equals("New note", owner.get_permission("permission").message)
			end)
		end
	end

	it("does not publish a second decision after a terminal server event", function()
		submit(false)
		callbacks[1].done(nil)
		assert.is_true(owner.mark_rejected("permission"))
		for _, callback in ipairs(queued) do callback() end
		assert.equals("rejected", owner.get_permission("permission").status)
		assert.same({}, emitted)
	end)
end)
