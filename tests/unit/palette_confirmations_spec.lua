local actions = require("opencode.actions")
local menu = require("opencode.ui.menu")
local state = require("opencode.state")

local function command(module, id)
	local commands = {}
	require(module).register({ register = function(record) commands[record.id] = record end })
	return assert(commands[id])
end

describe("palette confirmations", function()
	local saved, opened

	before_each(function()
		saved = {
			menu_open = menu.open,
			delete_session = actions.delete_session,
			set_active_session = actions.set_active_session,
			forget_session = actions.forget_session,
			clear_session_data = actions.clear_session_data,
			reload_locations = actions.reload_locations,
			list_integrations = actions.list_integrations,
			change_credential = actions.change_credential,
			notify = vim.notify,
		}
		opened = {}
		menu.open = function(opts) opened[#opened + 1] = opts end
		vim.notify = function() end
	end)

	after_each(function()
		menu.open = saved.menu_open
		for _, name in ipairs({ "delete_session", "set_active_session", "forget_session", "clear_session_data",
			"reload_locations", "list_integrations", "change_credential" }) do
			actions[name] = saved[name]
		end
		vim.notify = saved.notify
		state.reset()
	end)

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
