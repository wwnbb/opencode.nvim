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
		assert.equals("Activity on the connected server only", opened[1].message)
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

	it("ignores refreshes, interrupt completions and actions after closing", function()
		family.show()
		local picker, reply, interrupted, refreshes, notifications = opened[1], nil, nil, 0, 0
		local original = vim.deepcopy(picker.items)
		actions.get_session_family = function(_, callback) assert.is_nil(reply); reply = callback end
		actions.interrupt_session = function(id, callback) interrupts[#interrupts + 1] = id; interrupted = callback end
		vim.notify = function() notifications = notifications + 1 end
		local ctx = { refresh = function() refreshes = refreshes + 1 end, close = function() error("Closed picker selected") end }
		picker.keys[2].handler(ctx)
		picker.keys[3].handler(ctx, picker.items[2])
		picker.on_close()
		reply(nil, { records[1] })
		interrupted({ message = "Late error" })
		picker.keys[1].handler(ctx)
		picker.keys[2].handler(ctx)
		picker.keys[3].handler(ctx, picker.items[2])
		picker.on_select(picker.items[2], ctx)
		assert.same(original, picker.items)
		assert.same({ "active-child" }, interrupts)
		assert.equals(0, refreshes)
		assert.equals(0, notifications)
		assert.equals(1, #opened)
	end)

	it("does not cancel a newer picker when its predecessor closes", function()
		family.show()
		local previous, reply = opened[1]
		actions.get_session_family = function(_, callback) reply = callback end
		family.show()
		previous.on_close()
		reply(nil, records)
		assert.equals(2, #opened)
		local refreshes = 0
		opened[2].keys[2].handler({ refresh = function() refreshes = refreshes + 1 end })
		reply(nil, records)
		assert.equals(1, refreshes)
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

	it("renders long identical titles and selects by full ID in the source pane through the actual menu", function()
		local cs, ctx, selected = require("opencode.ui.chat.state"), nil, {}
		local columns, lines = vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 100, 32
		local view = cs.new()
		view.session_id, view.visible = "current-child", true
		view.winid, view.bufnr = vim.api.nvim_get_current_win(), vim.api.nvim_get_current_buf()
		views[#views + 1] = view
		local nav = cs.module(view, require("opencode.ui.chat.nav"))
		nav.open_family_session = function(id) selected[#selected + 1] = id end
		local title = "W1 discovery business rules and session persistence"
		local first_id, second_id = "ses_f39179dcdffeP4LJNVt7vA123456", "ses_f39179dcdffeP4LJNVt7vB123456"
		records[2].title, records[3].title = title, title
		records[2].id, records[3].id, records[4].parentID = first_id, second_id, first_id
		records[2].agent, records[3].agent = "general", "general"
		state.set_session_status(first_id, { type = "busy" })
		menu.open = function(opts) opened[#opened + 1] = opts; ctx = saved.open(opts); return ctx end
		local ok, err = pcall(function()
			family.show({ view = view })
			assert.equals(opened[1].items[2].label, opened[1].items[4].label)
			assert.equals("general · Active · A123456", opened[1].items[2].description)
			assert.equals("general · Inactive · B123456", opened[1].items[4].description)
			local rows = vim.api.nvim_buf_get_lines(ctx.popup.bufnr, 0, -1, false)
			for _, index in ipairs({ 2, 4 }) do
				assert.is_truthy(rows[index]:find(title, 1, true))
				assert.is_nil(rows[index]:find("ses_", 1, true))
			end
			vim.api.nvim_buf_set_lines(ctx.input.bufnr, 0, -1, false, { second_id })
			vim.api.nvim_exec_autocmds("TextChanged", { buffer = ctx.input.bufnr })
			assert.equals(second_id, ctx.current().value)
			assert.equals(1, vim.api.nvim_buf_line_count(ctx.popup.bufnr))
			local detail = table.concat(vim.api.nvim_buf_get_lines(ctx.frame.bufnr, 0, -1, false), "\n")
			assert.is_truthy(detail:find(title, 1, true))
			assert.is_truthy(detail:find(second_id, 1, true))
			state.set_session("other", "Other")
			vim.api.nvim_set_current_win(ctx.popup.winid)
			vim.api.nvim_win_set_cursor(ctx.popup.winid, { 1, 0 })
			local select
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(ctx.popup.bufnr, "n")) do
				if mapping.lhs == "<CR>" then select = mapping.callback end
			end
			assert.is_function(select)
			local winid = ctx.popup.winid
			select()
			assert.same({ second_id }, selected)
			assert.is_false(vim.api.nvim_win_is_valid(winid))
			assert.equals("current-child", view.session_id)
		end)
		if ctx then ctx.close() end
		vim.o.columns, vim.o.lines = columns, lines
		if not ok then error(err) end
	end)

	it("updates visible activity and filters from session events and unsubscribes on close", function()
		local events, ctx = require("opencode.events")
		local listeners = events.listener_count("session_status_change")
		menu.open = function(opts) opened[#opened + 1] = opts; ctx = saved.open(opts); return ctx end
		local ok, err = pcall(function()
			family.show()
			assert.equals(listeners + 1, events.listener_count("session_status_change"))
			local picker = opened[1]
			picker.keys[1].handler(ctx)
			assert.same({ "active-child" }, ids(picker))
			require("opencode.session").set_session_status("inactive-child", { type = "busy" })
			assert.same({ "active-child", "inactive-child" }, ids(picker))
			assert.equals("Active", picker.items[2].description)
			assert.equals(2, vim.api.nvim_buf_line_count(ctx.popup.bufnr))
			require("opencode.session").set_session_status("active-child", { type = "idle" })
			assert.same({ "inactive-child" }, ids(picker))
			picker.keys[1].handler(ctx)
			assert.same({ "root", "active-child", "current-child" }, ids(picker))
			require("opencode.session").set_session_status("inactive-child", { type = "idle" })
			assert.same({ "root", "active-child", "current-child", "inactive-child" }, ids(picker))
			ctx.close()
			assert.equals(listeners, events.listener_count("session_status_change"))
			local previous = vim.deepcopy(picker.items)
			require("opencode.session").set_session_status("active-child", { type = "busy" })
			assert.same(previous, picker.items)
		end)
		if ctx then ctx.close() end
		if not ok then error(err) end
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
