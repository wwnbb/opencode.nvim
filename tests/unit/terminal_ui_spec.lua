describe("persistent terminals in Neovim", function()
	local actions = require("opencode.actions")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local terminals = require("opencode.ui.terminals")
	local stubs, menus, notices, info, buffers, connections, input_callback, sent, removed, created, endpoint, original_config
	local function key(opts, name)
		for _, mapping in ipairs(opts.keys) do if mapping.key == name or require("opencode.util.keymap").matches(require("opencode.util.keymap").get(opts.keymap_scope or "menu")[mapping.action], name) then mapping.handler({ close = function() end }, opts.items[1]); return end end
		error("Missing menu key " .. name)
	end
	before_each(function()
		original_config = state.get_config()
		state.reset(); pending.clear_all()
		state.upsert_session({ id = "s", title = "S", directory = "/remote/project" }); state.set_session("s", "S")
		stubs, menus, notices, buffers, connections, sent, removed, created = {}, {}, {}, {}, {}, {}, {}, {}
		endpoint = { identity = "http://localhost:4096", generation = 1 }
		info = { id = "pty_one", sessionID = "s", title = "Remote terminal", cwd = "/remote/project", status = "running", output = { tail = 4 } }
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(actions, "terminal_endpoint", function() return vim.deepcopy(endpoint) end)
		stubs[#stubs + 1] = stub(vim, "notify", function(message) notices[#notices + 1] = message end)
		stubs[#stubs + 1] = stub(require("opencode.ui.menu"), "open", function(opts) menus[#menus + 1] = opts end)
		stubs[#stubs + 1] = stub(actions, "list_terminals", function(sid, cb) assert.equals("s", sid); cb(nil, { info }) end)
		stubs[#stubs + 1] = stub(actions, "get_terminal", function(id, sid, cb) assert.equals("pty_one", id); assert.equals("s", sid); cb(nil, info) end)
		stubs[#stubs + 1] = stub(actions, "get_terminal_snapshot", function(_, _, cb)
			cb(nil, { info = info, checkpoint = vim.base64.encode("\27[2J\27[Hremote prompt\r\n"), cursor = { x = 0, y = 1 } })
		end)
		stubs[#stubs + 1] = stub(actions, "connect_terminal", function(opts)
			connections[#connections + 1] = opts
			return { close = function() sent[#sent + 1] = { "detach" } end,
				control = function(cols, rows) sent[#sent + 1] = { "control", cols, rows }; return true end,
				input = function(data, cols, rows) sent[#sent + 1] = { "input", data, cols, rows }; return true end }
		end)
		stubs[#stubs + 1] = stub(actions, "remove_terminal", function(id, sid, cb) removed[#removed + 1] = { id, sid }; cb(nil) end)
		stubs[#stubs + 1] = stub(actions, "create_terminal", function(sid, opts, cb) created[#created + 1] = { sid, opts }; cb(nil, info) end)
		local open_term = vim.api.nvim_open_term
		stubs[#stubs + 1] = stub(vim.api, "nvim_open_term", function(bufnr, opts)
			buffers[#buffers + 1], input_callback = bufnr, opts.on_input
			return open_term(bufnr, opts)
		end)
	end)
	after_each(function()
		terminals.detach_all(); vim.cmd("stopinsert")
		vim.cmd("silent! tabonly!")
		for _, bufnr in ipairs(buffers) do if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end end
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		state.reset(); pending.clear_all(); state.set_config(original_config)
	end)
	it("uses terminal aliases and escapes their winbar labels", function()
		state.set_config({ terminal = { keymaps = { reconnect = { "%", "<F6>" }, close = false } } })
		terminals.open(info, "s", "/remote/project")
		vim.cmd("stopinsert")
		local buf, win = buffers[1], vim.api.nvim_get_current_win()
		local mappings = {}
		for _, item in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do mappings[item.lhs] = item end
		assert.is_nil(mappings.R); assert.is_nil(mappings.q)
		assert.is_function(mappings["%"].callback); assert.is_function(mappings["<F6>"].callback)
		connections[1].on_event({ type = "replay_complete" }, 4)
		local bar = vim.api.nvim_eval_statusline(vim.wo[win].winbar, { winid = win, use_winbar = true }).str
		assert.is_truthy(bar:find("% / <F6> reconnect", 1, true))
		assert.is_truthy(bar:find("(disabled) detach", 1, true))
		connections[1].on_close("closed", 4)
		assert.is_nil(vim.wo[win].winbar:find("R reconnect", 1, true))
		mappings["<F6>"].callback()
		assert.equals(2, #connections)
	end)
	it("renders the remote checkpoint/output in a real terminal and forwards raw keyboard input", function()
		terminals.show(); menus[1].on_select(menus[1].items[1])
		assert.equals("terminal", vim.bo[buffers[1]].buftype)
		assert.equals(4, connections[1].cursor)
		connections[1].on_event({ type = "replay_complete" }, 4)
		connections[1].on_data("live output\r\n", 17)
		assert.is_true(vim.wait(1000, function()
			return table.concat(vim.api.nvim_buf_get_lines(buffers[1], 0, -1, false), "\n"):find("live output", 1, true) ~= nil
		end))
		input_callback("input", 0, buffers[1], "echo test\r")
		assert.equals("control", sent[1][1]); assert.equals("input", sent[2][1]); assert.equals("echo test\r", sent[2][2])
		assert.equals("/remote/project", connections[1].directory)
	end)
	it("reuses the retained terminal with its latest output cursor after detaching", function()
		terminals.open(info, "s", "/remote/project")
		connections[1].on_data("live", 8)
		terminals.detach_all()
		terminals.open(info, "s", "/remote/project")
		assert.equals(1, #buffers); assert.equals(8, connections[2].cursor)
	end)
	it("reconnects R after SSE invalidation only after fresh same-terminal metadata, without replaying input", function()
		terminals.open(info, "s", "/remote/project")
		connections[1].on_data("live", 8)
		pending.invalidate(); connections[1].on_close("stale", 8)
		local reply
		actions.get_terminal = function(_, _, cb) reply = cb end
		vim.fn.maparg("R", "n", false, true).callback()
		assert.equals(1, #connections)
		reply(nil, info)
		assert.equals(2, #connections); assert.equals(8, connections[2].cursor); assert.equals(1, #buffers)
		connections[2].on_event({ type = "replay_complete" }, 8)
		connections[1].on_data("stale", 100)
		input_callback("input", 0, buffers[1], "fresh\r")
		local inputs = {}; for _, entry in ipairs(sent) do if entry[1] == "input" then inputs[#inputs + 1] = entry[2] end end
		assert.same({ "fresh\r" }, inputs)
	end)
	it("rejects R on moved, deleted or other-endpoint terminals and ignores invalidated metadata replies", function()
		terminals.open(info, "s", "/remote/project")
		local count, reply = 0, nil
		actions.get_terminal = function(_, _, cb) count = count + 1; reply = cb end
		local reconnect = vim.fn.maparg("R", "n", false, true).callback
		state.upsert_session({ id = "s", directory = "/remote/moved" }); reconnect(); assert.equals(0, count)
		state.upsert_session({ id = "s", directory = "/remote/project" })
		endpoint.identity = "http://other:4096"; reconnect(); assert.equals(0, count)
		endpoint.identity = "http://localhost:4096"
		pending.invalidate(); reconnect(); reply({ status = 404, message = "Deleted" }); assert.equals(1, #connections)
		reconnect(); reply(nil, vim.tbl_extend("force", info, { sessionID = "other" })); assert.equals(1, #connections)
		reconnect(); endpoint.generation = endpoint.generation + 1; reply(nil, info); assert.equals(1, #connections)
		reconnect(); reply(nil, info); assert.equals(2, #connections); assert.equals(4, connections[2].cursor)
		reconnect(); pending.invalidate(); reply(nil, info); assert.equals(2, #connections)
	end)
	it("creates a native remote terminal and removes it only after its separate confirmation", function()
		terminals.show(); key(menus[1], "n")
		assert.equals("s", created[1][1]); assert.equals("/remote/project", created[1][2].cwd)
		assert.same({}, created[1][2].args); assert.same(vim.empty_dict(), created[1][2].env)
		terminals.show(); key(menus[2], "d")
		menus[3].on_select("Cancel"); assert.equals(0, #removed)
		menus[3].on_select("Remove"); assert.same({ { "pty_one", "s" } }, removed)
	end)
	it("drops late picker selection and snapshot output after session/location invalidation", function()
		terminals.show(); state.set_session("other", "Other"); menus[1].on_select(menus[1].items[1])
		assert.equals(0, #connections)
		state.set_session("s", "S")
		local reply
		actions.get_terminal_snapshot = function(_, _, cb) reply = cb end
		terminals.open(info, "s", "/remote/project")
		state.upsert_session({ id = "s", directory = "/remote/moved" })
		reply(nil, { info = info, checkpoint = vim.base64.encode("late") })
		assert.equals(0, #connections)
	end)
	it("reports unavailable native routes and stale removal cannot target a new connection", function()
		actions.list_terminals = function(_, cb) cb({ status = 503, message = "Daemon unavailable" }) end
		terminals.show(); assert.equals(0, #menus)
		assert.truthy(notices[1]:find("unavailable", 1, true))
		actions.list_terminals = function(_, cb) cb(nil, { info }) end
		terminals.show(); key(menus[1], "d"); pending.invalidate(); menus[2].on_select("Remove")
		assert.equals(0, #removed)
	end)
end)
