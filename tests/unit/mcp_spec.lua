local state = require("opencode.state")
local catalogs = require("opencode.protocol.catalogs")
describe("MCP palette", function()
	local saved, actions, menu, toggle, refresh_callback, read_options, messages, notify, reads, auth_calls
	before_each(function()
		state.reset(); state.set_session("s", "S"); state.upsert_session({ id = "s", directory = "/one" })
		saved = {}; for _, name in ipairs({ "opencode.actions", "opencode.ui.menu", "opencode.ui.palette.mcp", "opencode.ui.palette.integration" }) do saved[name] = package.loaded[name] end
		reads, auth_calls, refresh_callback = 0, 0, nil
		messages = {}; notify = vim.notify; vim.notify = function(message) messages[#messages + 1] = message end
		actions = {
			get_mcp_status = function(cb, opts)
				reads = reads + 1
				read_options = opts
				if not menu then cb(nil, catalogs.mcp({ { name = "one", status = { status = "disabled" }, integrationID = "auth-id" } }))
				else refresh_callback = cb end
			end,
			toggle_mcp = function(name, connected, cb, opts) toggle[#toggle + 1] = { cb = cb, directory = opts.directory } end,
		}
		toggle, menu = {}, nil
		package.loaded["opencode.actions"] = actions
		package.loaded["opencode.ui.menu"] = { open = function(opts) menu = opts end }
		package.loaded["opencode.ui.palette.mcp"] = nil
		package.loaded["opencode.ui.palette.integration"] = { connect = function() auth_calls = auth_calls + 1 end }
	end)
	after_each(function()
		for _, name in ipairs({ "opencode.actions", "opencode.ui.menu", "opencode.ui.palette.mcp", "opencode.ui.palette.integration" }) do
			package.loaded[name] = saved[name]
		end
		vim.notify = notify; state.reset()
	end)
	it("freezes location, blocks duplicate toggles and waits for authoritative status", function()
		local commands = {}
		require("opencode.ui.palette.mcp").register({ register = function(command) commands[command.id] = command end })
		assert.is_nil(commands["mcp.tools"])
		commands["mcp.status"].run()
		local item = menu.items[1]
		assert.equals("auth-id", item.server.integrationID)
		state.upsert_session({ id = "other", directory = "/two" }); state.set_session("other", "Other")
		local handler = menu.keys[2].handler
		local ctx = { refresh = function() end }
		handler(ctx, item); handler(ctx, item)
		assert.equals(1, #toggle)
		assert.equals("/one", toggle[1].directory)
		toggle[1].cb(nil, true)
		assert.equals("/one", read_options.directory)
		assert.equals("disabled", item.status)
		refresh_callback(nil, catalogs.mcp({ { name = "one", status = { status = "pending" } } }))
		assert.equals("pending", item.status)
		assert.equals("Connecting", item.status_text)
		handler(ctx, item)
		assert.equals(1, #toggle)
		assert.equals("one: Connecting", messages[#messages])
	end)
	local function open()
		local command
		require("opencode.ui.palette.mcp").register({ register = function(definition) command = definition end })
		command.run()
		return menu.items[1]
	end
	for _, key in ipairs({ "t", "r", "a" }) do
		it("does not execute " .. key .. " from a previous connection", function()
			local item = open()
			local closed = false
			local ctx = { close = function() closed = true end, refresh = function() end }
			require("opencode.session.pending").invalidate()
			for _, shortcut in ipairs(menu.keys) do if shortcut.key == key then shortcut.handler(ctx, item) end end
			assert.equals(0, #toggle)
			assert.equals(1, reads)
			assert.equals(0, auth_calls)
			assert.is_nil(item.pending)
			assert.is_true(closed)
		end)
	end
	it("closes an obsolete list instead of reporting its old status", function()
		local item, closed = open(), false
		require("opencode.session.pending").invalidate()
		menu.on_select(item, { close = function() closed = true end })
		assert.same({}, messages)
		assert.is_true(closed)
	end)
	it("does not open a queued inspector after the connection changes", function()
		local item = open()
		local callback, schedule = nil, vim.schedule
		vim.schedule = function(fn) callback = fn end
		local ok, err = pcall(menu.keys[1].handler, { close = function() end }, item)
		vim.schedule = schedule
		assert.is_true(ok, err); assert.is_function(callback)
		require("opencode.session.pending").invalidate()
		local float = require("opencode.ui.float")
		local create = float.create_centered_popup
		float.create_centered_popup = function() error("Stale MCP inspector opened") end
		ok, err = pcall(callback)
		float.create_centered_popup = create
		assert.is_true(ok, err)
	end)
	it("opens wrapped server details from the MCP list and closes cleanly", function()
		local commands = {}
		require("opencode.ui.palette.mcp").register({ register = function(command) commands[command.id] = command end })
		commands["mcp.status"].run()
		local item = menu.items[1]
		item.server.error = string.rep("Long MCP authorization detail with spaces. ", 12)
		menu.keys[1].handler({ close = function() end }, item)
		local info_buf, info_win
		assert.is_true(vim.wait(1000, function()
			for _, win in ipairs(vim.api.nvim_list_wins()) do
				local buf = vim.api.nvim_win_get_buf(win)
				local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
				if lines[1] == "Name: one" then info_buf, info_win = buf, win; return true end
			end
			return false
		end, 10))
		local lines = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
		assert.equals("Status: Disabled", lines[2])
		assert.is_true(#lines > 8)
		for _, line in ipairs(lines) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(info_win))
		end
		local original_columns = vim.o.columns
		vim.o.columns = 54
		vim.api.nvim_exec_autocmds("VimResized", {})
		local narrower = vim.api.nvim_buf_get_lines(info_buf, 0, -1, false)
		assert.is_true(#narrower > #lines)
		for _, line in ipairs(narrower) do
			assert.is_true(vim.fn.strdisplaywidth(line) <= vim.api.nvim_win_get_width(info_win))
		end
		vim.o.columns = original_columns
		vim.api.nvim_exec_autocmds("VimResized", {})
		for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(info_buf, "n")) do
			if mapping.lhs == "q" then mapping.callback(); break end
		end
		assert.is_false(vim.api.nvim_win_is_valid(info_win))
	end)
	it("shares /mcp and /mcps and updates the actual open menu for location-matched native events", function()
		local registry, events = require("opencode.command_registry"), require("opencode.events")
		local previous = registry.get("mcp.status")
		local ctx
		package.loaded["opencode.ui.menu"] = nil
		local real_menu = require("opencode.ui.menu")
		package.loaded["opencode.ui.menu"] = { open = function(opts) menu = opts; ctx = real_menu.open(opts); return ctx end }
		local baseline = events.listener_count("catalog_invalidated")
		require("opencode.ui.palette.mcp").register({ register = registry.register })
		local ok, err = pcall(function()
			assert.equals(registry.get_slash("mcp"), registry.get_slash("mcps"))
			registry.select("mcp.status", { source = "completion" })
			assert.equals(baseline + 1, events.listener_count("catalog_invalidated"))
			events.emit("catalog_invalidated", { type = "mcp.status.changed", location = { directory = "/other" } })
			assert.equals(1, reads)
			events.emit("catalog_invalidated", { type = "mcp.status.changed", location = { directory = "/one" } })
			assert.is_true(vim.wait(500, function() return refresh_callback ~= nil end, 1))
			refresh_callback(nil, { aaa = { status = "disabled" }, one = { status = "connected" }, two = { status = "failed", error = "Broken" } })
			local one = vim.tbl_filter(function(item) return item.value == "one" end, menu.items)[1]
			assert.equals("connected", one.status)
			assert.equals(3, #menu.items); assert.equals("aaa", menu.items[1].value)
			assert.equals("one", ctx.current().value)
			local text = table.concat(vim.api.nvim_buf_get_lines(ctx.popup.bufnr, 0, -1, false), "\n")
			assert.truthy(text:find("● one", 1, true)); assert.truthy(text:find("× two", 1, true))
			events.emit("catalog_invalidated", { type = "mcp.status.changed", location = { directory = "/one" } })
			local expected = reads + 1
			assert.is_true(vim.wait(500, function() return reads == expected end, 1))
			refresh_callback(nil, {})
			assert.is_nil(ctx.current())
			for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(ctx.input.bufnr, "n")) do if mapping.lhs == "r" then mapping.callback(); break end end
			refresh_callback(nil, { one = { status = "connected" } })
			assert.equals("one", ctx.current().value)
			ctx.close(); assert.equals(baseline, events.listener_count("catalog_invalidated"))
			local old = reads
			events.emit("catalog_invalidated", { type = "mcp.status.changed", location = { directory = "/one" } })
			assert.equals(old, reads)
		end)
		if ctx then ctx.close() end
		registry.unregister("mcp.status"); if previous then registry.register(previous) end
		if not ok then error(err) end
	end)
end)
