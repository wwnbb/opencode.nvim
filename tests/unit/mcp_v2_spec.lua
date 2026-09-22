local state = require("opencode.state")
local catalogs = require("opencode.protocol.v2.catalogs")
describe("v2 MCP palette", function()
	local saved, actions, menu, toggle, refresh_callback, read_options, messages, notify
	before_each(function()
		state.reset(); state.set_session("s", "S"); state.upsert_session({ id = "s", directory = "/one" })
		saved = {}; for _, name in ipairs({ "opencode.actions", "opencode.ui.menu", "opencode.ui.palette.mcp" }) do saved[name] = package.loaded[name] end
		messages = {}; notify = vim.notify; vim.notify = function(message) messages[#messages + 1] = message end
		actions = {
			get_mcp_status = function(cb, opts)
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
	end)
	after_each(function()
		for name, module in pairs(saved) do package.loaded[name] = module end
		package.loaded["opencode.ui.palette.mcp"] = saved["opencode.ui.palette.mcp"]
		vim.notify = notify; state.reset()
	end)
	it("freezes location, blocks duplicate toggles and waits for authoritative status", function()
		local commands = {}
		require("opencode.ui.palette.mcp").register({ register = function(command) commands[command.id] = command end })
		commands["mcp.status"].action()
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
end)
