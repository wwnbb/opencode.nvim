local state = require("opencode.state")
local sync = require("opencode.sync")
local selectors = require("opencode.selectors")
local projection = require("opencode.protocol.v2.messages")

describe("core quality regression guards", function()
	local restored
	local function replace(object, key, value)
		local original = object[key]
		restored[#restored + 1] = function() object[key] = original end
		object[key] = value
		return original
	end
	local function put_usage(input)
		sync.handle_session_messages("quality-root", { projection.project("quality-root", {
			id = "quality-message", type = "assistant", time = { created = 1 },
			model = { providerID = "p", id = "m" },
			tokens = { input = input, output = 0, reasoning = 0, cache = { read = 0, write = 0 } },
			content = {},
		}) })
	end
	local function catalog(limit)
		sync.handle_location_catalog("/quality", "providers", {
			providers = { { id = "p", models = { m = { limit = { context = limit } } } } }, default = {},
		})
	end
	before_each(function()
		restored = {}
		state.reset(); sync.clear_all()
		state.set_session("quality-root", "Root")
		state.upsert_session({ id = "quality-root", directory = "/quality", cost = 1 }, { touch = false })
		catalog(100); sync.select_catalog_location("/quality"); put_usage(10)
	end)
	after_each(function()
		for index = #restored, 1, -1 do restored[index]() end
		state.reset(); sync.clear_all()
	end)

	it("reuses warmed context and family cost without traversing messages or records", function()
		state.upsert_session({ id = "quality-child", parentID = "quality-root", cost = 2 }, { touch = false })
		assert.equals(10, selectors.current_context().tokens)
		assert.equals(3, selectors.session_cost())
		local scans = 0
		local messages, records
		messages = replace(sync, "get_messages", function(...) scans = scans + 1; return messages(...) end)
		records = replace(state, "get_session_record", function(...) scans = scans + 1; return records(...) end)
		for _ = 1, 20 do
			local context = selectors.current_context()
			context.breakdown.total = -1
			assert.equals(10, context.tokens)
			local cost, complete = selectors.session_cost()
			assert.equals(3, cost); assert.is_true(complete)
		end
		assert.equals(0, scans)
	end)

	it("preserves absent current-session results for sessionless input consumers", function()
		replace(state, "get_session", function() return nil end)
		assert.is_nil(selectors.current_context())
		assert.is_nil(selectors.session_cost())
	end)

	it("invalidates usage caches on catalogs, history, family ownership and reset", function()
		assert.equals(10, selectors.current_context().percent)
		assert.equals(1, selectors.session_cost())
		catalog(200)
		assert.equals(5, selectors.current_context().percent)
		put_usage(20)
		assert.equals(20, selectors.current_context().tokens)
		state.upsert_session({ id = "quality-child", parentID = "quality-root", cost = 2 }, { touch = false })
		assert.equals(3, selectors.session_cost())
		state.upsert_session({ id = "quality-child", parentID = "elsewhere" }, { touch = false })
		assert.equals(1, selectors.session_cost())
		local old_revision, old_catalog = state.get_revision(), sync.get_catalog_generation()
		state.reset(); sync.clear_all()
		assert.is_true(state.get_revision() > old_revision)
		assert.is_true(sync.get_catalog_generation() > old_catalog)
		state.set_session("quality-root", "Replacement")
		state.upsert_session({ id = "quality-root", directory = "/quality", cost = 9 }, { touch = false })
		assert.is_nil(selectors.current_context())
		assert.equals(9, selectors.session_cost())
	end)

	it("constructs detached session views without a full application snapshot", function()
		replace(state, "get_full_state", function() error("unrelated app state was copied") end)
		state.upsert_session({ id = "quality-root", custom = { nested = 1 }, is_runtime = "source" }, { touch = false })
		state.set_session_status("quality-root", { type = "busy", nested = { value = 1 } })
		local view = selectors.get_current_session_view()
		assert.equals("source", view.record.is_runtime)
		assert.is_nil(view.is_runtime)
		view.record.custom.nested = 2
		view.status.nested.value = 2
		assert.equals(1, view.record.custom.nested)
		assert.equals(1, state.get_session_record("quality-root").custom.nested)
		assert.equals(1, state.get_session_status("quality-root").nested.value)
	end)

	it("keeps lazy action forwarder arity, dropped extra arguments and multiple returns", function()
		local calls = {}
		local api = {}
		for _, name in ipairs({ "open", "open_input_at_end", "ask_btw" }) do
			api[name] = function(...) calls[name] = { count = select("#", ...), ... }; return "result", nil, 3 end
		end
		replace(package.loaded, "opencode", api)
		local actions = require("opencode.actions")
		local a, b, c = actions.open("ignored")
		assert.equals("result", a); assert.is_nil(b); assert.equals(3, c)
		actions.open_input_at_end(nil, "ignored")
		actions.ask_btw("question", nil, "ignored")
		assert.equals(0, calls.open.count)
		assert.equals(1, calls.open_input_at_end.count)
		assert.equals(2, calls.ask_btw.count)
		assert.equals("question", calls.ask_btw[1])
	end)

	it("preserves direct decoder EOF reentry from the final length body callback", function()
		local completed, failures, decoder = 0, 0, nil
		decoder = require("opencode.client.http_decoder").new({
			on_body = function(body) assert.equals("OK", body); decoder:finish_eof() end,
			on_complete = function() completed = completed + 1 end,
			on_error = function() failures = failures + 1 end,
		})
		decoder:push("HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nOK")
		decoder:finish_eof()
		assert.equals(1, completed); assert.equals(0, failures)
	end)

	it("resolves permission tool input and name with one ordered part scan", function()
		local reads = 0
		replace(sync, "get_parts", function()
			reads = reads + 1
			return { { type = "tool", callID = "call", tool = "bash", state = { input = { command = "pwd" } } } }
		end)
		local request = { message_id = "message", call_id = "call", metadata = {} }
		local input, name = require("opencode.events.handlers.permission_flow.request").resolve_tool(request)
		assert.equals("pwd", input.command); assert.equals("bash", name); assert.equals(1, reads)
	end)

	it("skips full status summaries and inactive attention data in lualine", function()
		local lualine = require("opencode.components.lualine")
		replace(state, "get_status_summary", function() error("unused summary") end)
		replace(state, "get_active_sessions", function() error("disabled attention") end)
		lualine.setup({ show_attention = false, show_diff_stats = false })
		assert.equals("", lualine.component())
	end)

	it("keeps immediate first and expired Git reads, stable TTL hits, zero TTL and cwd isolation", function()
		local lualine = require("opencode.components.lualine")
		local clock, additions, cwd, commands = 1000, 1, "/quality", 0
		vim.fn.system({ "true" }) -- Set the native exit status used by systemlist.
		replace(vim.uv or vim.loop, "now", function() return clock end)
		replace(vim.fn, "getcwd", function() return cwd end)
		replace(vim.fn, "executable", function() return 1 end)
		replace(vim.fn, "systemlist", function(args)
			commands = commands + 1
			if args[4] == "rev-parse" then return { args[3] } end
			if vim.tbl_contains(args, "ls-files") then return {} end
			return { additions .. "\t0\tfile" }
		end)
		lualine.setup({ show_attention = false, show_diff_stats = true, diff_stats_cache_ms = 100 })
		local first = lualine.component()
		assert.is_truthy(first:find("+1", 1, true)); assert.equals(3, commands)
		clock, additions = 1050, 2
		assert.equals(first, lualine.component()); assert.equals(3, commands)
		clock = 1100
		assert.is_truthy(lualine.component():find("+2", 1, true)); assert.equals(6, commands)
		cwd, additions = "/other", 3
		assert.is_truthy(lualine.component():find("+3", 1, true)); assert.equals(9, commands)
		lualine.setup({ diff_stats_cache_ms = 0 })
		assert.is_truthy(lualine.component():find("+3", 1, true))
		additions = 4
		assert.is_truthy(lualine.component():find("+4", 1, true)); assert.equals(15, commands)
	end)

	it("uses one status read and one delayed metadata read per tab when both recovery handlers connect", function()
		local sessions, client = require("opencode.session"), require("opencode.client")
		local handler = require("opencode.events.handlers.v2")
		handler.clear()
		restored[#restored + 1] = handler.clear
		local handlers, timers, statuses, metadata = {}, {}, 0, {}
		local events = {
			on = function(name, callback) handlers[name] = handlers[name] or {}; table.insert(handlers[name], callback) end,
			emit = function() end,
		}
		replace(vim, "schedule", function(callback) callback() end)
		replace(vim, "defer_fn", function(callback)
			timers[#timers + 1] = callback
			return { stop = function() end, close = function() end }
		end)
		replace(sessions, "refresh_status", function() statuses = statuses + 1 end)
		replace(client, "get_session", function(id) metadata[id] = (metadata[id] or 0) + 1 end)
		replace(client, "get_all_messages", function() end)
		replace(client, "get_inbox", function() end)
		state.upsert_session({ id = "quality-other", title = "Other" }, { touch = false })
		state.set_runtime_session_order({ "quality-root", "quality-other" })
		require("opencode.events.handlers.session_store").setup(events)
		handler.setup(events)
		for _, connected in ipairs(handlers.connected) do connected() end
		assert.equals(1, statuses)
		assert.same({}, metadata)
		assert.equals(2, #timers)
		for _, callback in ipairs(timers) do callback() end
		assert.same({ ["quality-root"] = 1, ["quality-other"] = 1 }, metadata)
	end)
end)
