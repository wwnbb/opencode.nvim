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
end)
