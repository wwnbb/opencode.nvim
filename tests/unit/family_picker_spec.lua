local family = require("opencode.ui.palette.family")
local actions, menu = require("opencode.actions"), require("opencode.ui.menu")
local state, pending = require("opencode.state"), require("opencode.session.pending")
local registry = require("opencode.command_registry")

describe("family picker", function()
	local saved, records, opened, interrupts, views
	before_each(function()
		state.reset(); pending.clear_all()
		state.set_session("root", "Root")
		state.set_session("current-child", "Current", { runtime = false })
		records = {
			{ id = "root", title = "Root" },
			{ id = "active-child", parentID = "root", title = "Running" },
			{ id = "inactive-child", parentID = "root", title = "Finished" },
			{ id = "current-child", parentID = "active-child", title = "Current" },
		}
		state.set_session_status("active-child", { type = "busy" })
		saved = { get_session_family = actions.get_session_family, interrupt_session = actions.interrupt_session,
			open = menu.open, notify = vim.notify, command = registry.get("session.family") }
		opened, interrupts, views = {}, {}, {}
		menu.open = function(opts) opened[#opened + 1] = opts end
		vim.notify = function() end
		actions.get_session_family = function(id, callback)
			assert.equals("current-child", id)
			callback(nil, records, "root")
		end
		actions.interrupt_session = function(id, callback) interrupts[#interrupts + 1] = id; callback(nil, { interrupted = true }) end
		family.register({ register = registry.register })
	end)
	after_each(function()
		for _, view in ipairs(views) do require("opencode.ui.chat.state").remove(view) end
		actions.get_session_family, actions.interrupt_session = saved.get_session_family, saved.interrupt_session
		menu.open, vim.notify = saved.open, saved.notify
		registry.unregister("session.family")
		if saved.command then registry.register(saved.command) end
		state.reset(); pending.clear_all()
	end)
	local function ids(picker) return vim.tbl_map(function(item) return item.value end, picker.items) end

	it("shares /family and the palette and displays the complete tree with active/inactive status", function()
		local command = registry.get("session.family")
		assert.equals(command, registry.get_slash("family"))
		assert.is_true(registry.select(command.id, { source = "completion" }))
		assert.same({ "root", "active-child", "current-child", "inactive-child" }, ids(opened[1]))
		assert.equals("Active", opened[1].items[2].description)
		assert.equals("Inactive", opened[1].items[3].description)
		assert.matches("● Current", opened[1].items[3].label)
	end)

	it("refreshes activity filters and interrupts the selected active child without entering it", function()
		family.show()
		local picker, refreshes = opened[1], 0
		local ctx = { refresh = function() refreshes = refreshes + 1 end }
		picker.keys[1].handler(ctx)
		assert.same({ "active-child" }, ids(picker))
		picker.keys[3].handler(ctx, picker.items[1])
		assert.same({ "active-child" }, interrupts)
		assert.equals("current-child", state.get_session().id)
		assert.same({ "root" }, state.get_runtime_session_order())
		picker.keys[1].handler(ctx)
		assert.same({ "root", "current-child", "inactive-child" }, ids(picker))
		picker.keys[3].handler(ctx, picker.items[1])
		assert.equals(1, #interrupts)
		assert.equals(3, refreshes)
	end)

	it("ignores a family response after changing the view or connection", function()
		local deferred
		actions.get_session_family = function(_, callback) deferred = callback end
		family.show()
		state.set_session("other", "Other")
		deferred(nil, records)
		assert.equals(0, #opened)
		state.set_session("current-child", "Current", { runtime = false })
		family.show()
		pending.invalidate()
		deferred(nil, records)
		assert.equals(0, #opened)
	end)

	it("ignores a superseded refresh response", function()
		family.show()
		local picker, replies = opened[1], {}
		actions.get_session_family = function(_, callback) replies[#replies + 1] = callback end
		local ctx = { refresh = function() end }
		picker.keys[2].handler(ctx)
		picker.keys[2].handler(ctx)
		replies[2](nil, { records[1] })
		replies[1](nil, records)
		assert.same({ "root" }, ids(picker))
	end)
	it("keeps concurrent family responses with their panes and rejects a rebound owner", function()
		local cs, replies = require("opencode.ui.chat.state"), {}
		actions.get_session_family = function(id, callback) replies[id] = callback end
		for _, id in ipairs({ "current-child", "other" }) do
			local view = cs.new()
			view.session_id, view.visible = id, true
			views[#views + 1] = view
			family.show({ view = view })
		end
		state.set_session("other", "Other")
		replies["current-child"](nil, records)
		replies.other(nil, { { id = "other", title = "Other" } })
		assert.equals(2, #opened)
		assert.equals(views[1], opened[1].context.view)
		assert.equals(views[2], opened[2].context.view)
		views[1].generation = views[1].generation + 1
		opened[1].keys[3].handler({ refresh = function() end }, opened[1].items[2])
		assert.same({}, interrupts)
	end)

	it("can leave an empty active filter through the actual menu keymap", function()
		local ctx
		actions.get_session_family = function(_, callback) callback(nil, { records[1] }, "root") end
		menu.open = function(opts) ctx = saved.open(opts); return ctx end
		local function press(key)
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(ctx.input.bufnr, "n")) do
				if mapping.lhs == key then return mapping.callback() end
			end
			error("Missing family key " .. key)
		end
		local ok, err = pcall(function()
			family.show()
			assert.equals("root", ctx.current().value)
			press("a")
			assert.is_nil(ctx.current())
			press("r")
			assert.is_nil(ctx.current())
			press("a")
			assert.equals("root", ctx.current().value)
		end)
		if ctx then ctx.close() end
		if not ok then error(err) end
	end)
end)
