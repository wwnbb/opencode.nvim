local state = require("opencode.state")
local sync = require("opencode.sync")
local selectors = require("opencode.selectors")
local projection = require("opencode.protocol.messages")

describe("core state and status regressions", function()
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

	it("builds active sessions in runtime order and counts lualine attention from pending counts", function()
		state.reset()
		for _, id in ipairs({ "quality-b", "quality-a", "quality-c" }) do state.upsert_session({ id = id, title = id }) end
		state.set_session("quality-a", "A")
		state.set_session_pending_counts("quality-b", { questions = 1 })
		state.set_session_pending_counts("quality-c", { permissions = 2 })
		local ids = vim.tbl_map(function(session) return session.id end, state.get_active_sessions())
		assert.same(state.get_runtime_session_order(), ids)
		assert.same({ "quality-b", "quality-a", "quality-c" }, ids)
		assert.same(selectors.get_active_sessions(), state.get_active_sessions())
		local active = state.get_active_sessions()
		assert.is_true(active[2].is_current); assert.equals(1, active[1].pending.questions)
		assert.same(active, state.get_status_summary().active_sessions)
		local lualine = require("opencode.components.lualine")
		lualine.setup({ show_attention = true, attention_icon = "!", show_diff_stats = false })
		assert.is_truthy(lualine.component():find("!2", 1, true))
		state.reset()
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
		local handler = require("opencode.events.handlers.server")
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
