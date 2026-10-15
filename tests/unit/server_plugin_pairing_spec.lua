describe("native server plugin manager", function()
	local actions = require("opencode.actions")
	local state = require("opencode.state")
	local pending = require("opencode.session.pending")
	local plugins = require("opencode.ui.palette.plugins")
	local menus, calls, notices, stubs, rendered, bufnr, inventory
	local function key(opts, name, index)
		for _, mapping in ipairs(opts.keys) do
			if require("opencode.util.keymap").get(opts.keymap_scope)[mapping.action] == name then mapping.handler({ close = function() end }, opts.items[index or 1]); return end
		end
		error("Missing menu key " .. name)
	end
	before_each(function()
		state.reset(); pending.clear_all()
		state.upsert_session({ id = "s", title = "S", directory = "/remote/project" }); state.set_session("s", "S")
		menus, calls, notices, stubs = {}, {}, {}, {}
		inventory = {
			{ id = "Package", source = { type = "package", target = "@test/package", version = "1.2.3" }, state = { status = "active" } },
			{ id = "Broken local", source = { type = "local", path = "/remote/plugin.ts" }, state = { status = "failed", error = "Failed to load\nDetail", ref = "diagnostic" } },
		}
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(require("opencode.ui.menu"), "open", function(opts) menus[#menus + 1] = opts end)
		stubs[#stubs + 1] = stub(vim, "notify", function(message) notices[#notices + 1] = message end)
		stubs[#stubs + 1] = stub(actions, "list_server_plugins", function(opts, cb)
			calls[#calls + 1] = { "list", vim.deepcopy(opts) }; cb(nil, inventory)
		end)
		stubs[#stubs + 1] = stub(actions, "check_server_plugins", function(target, opts, cb)
			calls[#calls + 1] = { "check", target, vim.deepcopy(opts) }
			inventory[1].source.outdated = true; cb(nil, inventory)
		end)
		stubs[#stubs + 1] = stub(actions, "update_server_plugins", function(targets, opts, cb)
			calls[#calls + 1] = { "update", targets, vim.deepcopy(opts) }; cb(nil)
		end)
		bufnr = vim.api.nvim_create_buf(false, true)
		stubs[#stubs + 1] = stub(require("opencode.ui.float"), "create_centered_popup", function()
			return { mount = function() end, close = function() end, render = function(_, lines) rendered = lines end }, bufnr
		end)
	end)
	after_each(function()
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		if vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		state.reset(); pending.clear_all()
	end)
	it("lists version and state and opens multiline native error details", function()
		plugins.show()
		assert.equals("/remote/project", menus[1].message)
		assert.equals("active, package, 1.2.3", menus[1].items[1].description)
		assert.equals("failed, local", menus[1].items[2].description)
		menus[1].on_select(menus[1].items[2])
		assert.same({ "Broken local", "Source: /remote/plugin.ts", "Status: failed", "", "Failed to load", "Detail", "Diagnostic: diagnostic" }, rendered)
	end)
	it("checks the selected package, uses the returned inventory, and targets updates to its captured location", function()
		plugins.show(); state.set_session("other", "Other")
		key(menus[1], "c")
		assert.same({ "check", "@test/package", { directory = "/remote/project" } }, calls[2])
		assert.truthy(menus[2].items[1].description:find("update available", 1, true))
		key(menus[2], "u")
		assert.same({ "update", { "@test/package" }, { directory = "/remote/project" } }, calls[3])
		assert.equals("list", calls[4][1])
	end)
	it("keeps local plugins and unchecked packages from update and supports checking all", function()
		plugins.show(); key(menus[1], "u"); key(menus[1], "u", 2); key(menus[1], "c", 2)
		assert.equals(1, #calls)
		key(menus[1], "C")
		assert.is_nil(calls[2][2])
		assert.equals("check", calls[2][1])
	end)
	it("does not report an update success after a native failure or act after reconnect", function()
		inventory[1].source.outdated = true
		actions.update_server_plugins = function(_, _, cb) cb({ status = 503, message = "Package update failed" }) end
		plugins.show(); key(menus[1], "u")
		assert.truthy(notices[#notices]:find("Package update failed", 1, true))
		assert.equals(1, #menus)
		pending.invalidate(); key(menus[1], "c"); key(menus[1], "u")
		assert.equals(1, #calls)
	end)
	it("reports actual unavailable endpoints and ignores old inventory callbacks", function()
		actions.list_server_plugins = function(_, cb) cb({ status = 404, message = "Not found" }) end
		plugins.show(); assert.equals(0, #menus)
		assert.truthy(notices[1]:find("does not support", 1, true))
		local reply
		actions.list_server_plugins = function(_, cb) reply = cb end
		plugins.show(); pending.invalidate(); reply(nil, inventory)
		assert.equals(0, #menus)
	end)
end)

describe("single-use native server pairing", function()
	local actions = require("opencode.actions")
	local pending = require("opencode.session.pending")
	local pairing = require("opencode.ui.palette.pairing")
	local stubs, menus, notices, opened, registers, now, info, count, closed
	local function context() return { close = function() closed = closed + 1 end } end
	before_each(function()
		pending.clear_all()
		stubs, menus, notices, opened, registers, now, count, closed = {}, {}, {}, {}, {}, 1000, 0, 0
		info = { urls = { "https://example.test/base/", "http://[::1]:4096", "https://example.test/other" } }
		local stub = require("luassert.stub")
		stubs[#stubs + 1] = stub(actions, "get_server_info", function(cb) cb(nil, info) end)
		stubs[#stubs + 1] = stub(actions, "pair_server", function(cb) count = count + 1; cb(nil, { code = "public-test-code", expires_in = 300 }) end)
		stubs[#stubs + 1] = stub(require("opencode.ui.menu"), "open", function(opts) menus[#menus + 1] = opts end)
		stubs[#stubs + 1] = stub(vim, "notify", function(message) notices[#notices + 1] = message end)
		stubs[#stubs + 1] = stub(vim.ui, "open", function(url) opened[#opened + 1] = url end)
		stubs[#stubs + 1] = stub(vim.fn, "setreg", function(name, value) registers[name] = value; return 0 end)
		stubs[#stubs + 1] = stub(vim.fn, "getreg", function(name) return registers[name] end)
		stubs[#stubs + 1] = stub(vim.uv or vim.loop, "now", function() return now end)
	end)
	after_each(function()
		for index = #stubs, 1, -1 do stubs[index]:revert() end
		pending.clear_all()
	end)
	it("shows advertised origin links and expiry and makes copy and open reachable", function()
		pairing.show()
		assert.equals(1, count); assert.equals(2, #menus[1].items)
		assert.equals("https://example.test/auth/connect/public-test-code", menus[1].items[1].value)
		assert.equals("http://[::1]:4096/auth/connect/public-test-code", menus[1].items[2].value)
		assert.truthy(menus[1].message:find("work once and expire", 1, true))
		menus[1].keys[1].handler(context(), menus[1].items[2])
		assert.equals(menus[1].items[2].value, registers["+"])
		menus[1].on_select(menus[1].items[1], context())
		assert.same({ menus[1].items[1].value }, opened)
	end)
	it("blocks both open and copy at expiry without requesting a replacement code", function()
		pairing.show(); now = 301000
		menus[1].on_select(menus[1].items[1], context())
		menus[1].keys[1].handler(context(), menus[1].items[1])
		assert.equals(2, closed); assert.equals(0, #opened); assert.same({}, registers)
		assert.equals(1, count)
	end)
	it("blocks links from a replaced connection or an earlier pairing dialog", function()
		pairing.show(); pairing.show()
		menus[1].on_select(menus[1].items[1], context())
		pending.invalidate(); menus[2].keys[1].handler(context(), menus[2].items[1])
		assert.equals(0, #opened); assert.same({}, registers)
	end)
	it("rejects unsafe advertised URLs and does not issue a code without usable links", function()
		info.urls = { "javascript:alert(1)", "https://user:password@example.test", "http://example.test\n/injection" }
		pairing.show(); assert.equals(0, count); assert.equals(0, #menus)
		assert.truthy(notices[1]:find("HTTP(S)", 1, true))
	end)
	it("reports unavailable pairing and ignores a delayed code after reconnect", function()
		actions.pair_server = function(cb) cb({ status = 404, message = "No route" }) end
		pairing.show(); assert.equals(0, #menus)
		assert.truthy(notices[1]:find("does not support pairing", 1, true))
		local reply
		actions.pair_server = function(cb) reply = cb end
		pairing.show(); pending.invalidate(); reply(nil, { code = "old", expires_in = 300 })
		assert.equals(0, #menus)
	end)
end)
