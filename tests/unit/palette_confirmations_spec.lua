local actions = require("opencode.actions")
local menu = require("opencode.ui.menu")
local state = require("opencode.state")
local float = require("opencode.ui.float")

local function command(module, id)
	local commands = {}
	require(module).register({ register = function(record) commands[record.id] = record end })
	return assert(commands[id])
end

describe("palette confirmations", function()
	local saved, opened, inputs

	before_each(function()
		saved = {
			menu_open = menu.open,
			float_input = float.create_input_popup,
			delete_session = actions.delete_session,
			set_active_session = actions.set_active_session,
			forget_session = actions.forget_session,
			clear_session_data = actions.clear_session_data,
			reload_locations = actions.reload_locations,
			list_integrations = actions.list_integrations,
			change_credential = actions.change_credential,
			list_sessions = actions.list_sessions,
			switch_session = actions.switch_session,
			refresh_session_activity = actions.refresh_session_activity,
			close_session = actions.close_session,
			list_pending_inputs = actions.list_pending_inputs,
			cancel_pending_input = actions.cancel_pending_input,
			notify = vim.notify,
		}
		opened, inputs = {}, {}
		menu.open = function(opts) opened[#opened + 1] = opts end
		float.create_input_popup = function(opts) inputs[#inputs + 1] = opts end
		vim.notify = function() end
	end)

	after_each(function()
		menu.open = saved.menu_open
		float.create_input_popup = saved.float_input
		for _, name in ipairs({ "delete_session", "set_active_session", "forget_session", "clear_session_data",
			"reload_locations", "list_integrations", "change_credential", "list_sessions", "switch_session",
			"refresh_session_activity", "close_session", "list_pending_inputs", "cancel_pending_input" }) do
			actions[name] = saved[name]
		end
		vim.notify = saved.notify
		state.reset()
	end)

	for _, invalidation in ipairs({ "connection", "session", "none" }) do
		it("owns the pending-input picker across " .. invalidation .. " cancellation", function()
			state.set_session("ses_one", "One")
			local cancelled = {}
			actions.list_pending_inputs = function(_, cb) cb(nil, { { id = "input-one", payload = { text = "Queued" } } }) end
			actions.cancel_pending_input = function(sid, id) cancelled[#cancelled + 1] = { sid, id } end
			command("opencode.ui.palette.prompt", "prompt.cancel_pending").run()
			local pending = require("opencode.session.pending")
			if invalidation == "connection" then pending.invalidate()
			elseif invalidation == "session" then pending.clear_session("ses_one")
			else state.set_session("ses_two", "Two") end
			opened[1].on_select(opened[1].items[1])
			assert.same(invalidation == "none" and { { "ses_one", "input-one" } } or {}, cancelled)
		end)
	end

	for _, stale in ipairs({ false, true }) do
		it(stale and "ignores a session picker from an old connection" or "switches to a session from the current picker", function()
			local selected = {}
			actions.list_sessions = function(_, cb) cb(nil, { { id = "ses_pick", title = "Picked" } }) end
			actions.switch_session = function(session) selected[#selected + 1] = session.id end
			command("opencode.ui.palette.session", "session.list").run()
			if stale then require("opencode.session.pending").invalidate() end
			opened[1].on_select(opened[1].items[1])
			assert.same(stale and {} or { "ses_pick" }, selected)
		end)

		it(stale and "ignores select and close in an old active-session menu" or "selects and closes entries in the current active-session menu", function()
			local selected, closed, menu_closed = {}, {}, false
			state.set_session("ses_one", "One")
			state.set_session("ses_two", "Two")
			actions.refresh_session_activity = function(cb) cb() end
			actions.switch_session = function(session) selected[#selected + 1] = session.id end
			actions.close_session = function(opts) closed[#closed + 1] = opts.session_id; return true end
			require("opencode.ui.active_sessions").show()
			local opts = opened[1]
			local item = opts.items[1]
			if stale then require("opencode.session.pending").invalidate() end
			opts.on_select(item)
			opts.keys[1].handler({ close = function() menu_closed = true end }, item)
			assert.same(stale and {} or { item.value }, selected)
			assert.same(stale and {} or { item.value }, closed)
			assert.equals(stale and 2 or 1, #opts.items)
			assert.is_false(menu_closed)
		end)
	end

	it("keeps delete choices in order and leaves the session intact on cancellation", function()
		state.set_session("delete-me", "A session")
		local deleted = 0
		actions.delete_session = function(_, cb) deleted = deleted + 1; cb(nil) end
		actions.set_active_session = function() end
		actions.forget_session = function() end
		actions.clear_session_data = function() end
		local run = command("opencode.ui.palette.session", "session.delete").run
		run()
		assert.same({ "Yes", "No" }, opened[1].items)
		assert.is_false(opened[1].sort)
		assert.is_truthy(opened[1].message:find("A session", 1, true))
		opened[1].on_select("No")
		assert.equals(0, deleted)
		run()
		-- Escape closes the menu without invoking on_select.
		assert.equals(0, deleted)
		opened[2].on_select("Yes")
		assert.equals(1, deleted)
	end)

	it("does not delete from a confirmation opened on an old connection", function()
		state.set_session("delete-me", "A session")
		local deleted = 0
		actions.delete_session = function() deleted = deleted + 1 end
		command("opencode.ui.palette.session", "session.delete").run()
		require("opencode.session.pending").invalidate()
		opened[1].on_select("Yes")
		assert.equals(0, deleted)
	end)

	it("reloads only after choosing the first option", function()
		local reloaded = 0
		actions.reload_locations = function(cb) reloaded = reloaded + 1; cb(nil) end
		local run = command("opencode.ui.palette.system", "system.reload").run
		run()
		assert.same({ "Reload all locations", "Cancel" }, opened[1].items)
		assert.is_false(opened[1].sort)
		assert.is_truthy(opened[1].message:find("every project", 1, true))
		opened[1].on_select("Cancel")
		assert.equals(0, reloaded)
		run()
		opened[2].on_select("Reload all locations")
		assert.equals(1, reloaded)
	end)

	it("does not reload a replacement server from an old confirmation", function()
		local reloaded = 0
		actions.reload_locations = function() reloaded = reloaded + 1 end
		command("opencode.ui.palette.system", "system.reload").run()
		require("opencode.session.pending").invalidate()
		opened[1].on_select("Reload all locations")
		assert.equals(0, reloaded)
	end)
	for _, stage in ipairs({ "connections", "manage", "disconnect", "rename" }) do
		it("does not act on an old account after reconnect at " .. stage, function()
			local changed = 0
			actions.list_integrations = function(cb)
				cb(nil, { { id = "provider", name = "Provider", connections = {
					{ id = "credential", label = "Work", type = "credential" },
				} } })
			end
			actions.change_credential = function(_, _, _, _, _, cb) changed = changed + 1; cb(nil, { connections = {} }) end
			require("opencode.ui.palette.integration").connections()
			if stage ~= "connections" then opened[1].on_select(opened[1].items[1]) end
			if stage == "disconnect" then opened[2].on_select(opened[2].items[3])
			elseif stage == "rename" then opened[2].on_select(opened[2].items[2]) end
			local count = #opened
			require("opencode.session.pending").invalidate()
			if stage == "connections" then opened[1].on_select(opened[1].items[1])
			elseif stage == "manage" then opened[2].on_select(opened[2].items[1])
			elseif stage == "disconnect" then opened[3].on_select("Disconnect")
			else inputs[1].on_submit("New label") end
			assert.equals(0, changed)
			assert.equals(count, #opened)
		end)
	end

	it("asks before disconnecting a credential", function()
		local changed = 0
		actions.list_integrations = function(cb)
			cb(nil, { { id = "provider", name = "Provider", connections = {
				{ id = "credential", label = "Work", type = "credential" },
			} } })
		end
		actions.change_credential = function(_, _, _, _, _, cb)
			changed = changed + 1
			cb(nil, { connections = {} })
		end
		require("opencode.ui.palette.integration").connections()
		opened[1].on_select(opened[1].items[1])
		assert.same({ "Activate", "Rename", "Disconnect" }, vim.tbl_map(function(item) return item.label end, opened[2].items))
		opened[2].on_select(opened[2].items[3])
		assert.same({ "Disconnect", "Cancel" }, opened[3].items)
		assert.is_false(opened[3].sort)
		assert.equals("Disconnect account Work?", opened[3].message)
		opened[3].on_select("Cancel")
		assert.equals(0, changed)
		opened[3].on_select("Disconnect")
		assert.equals(1, changed)
	end)
end)
