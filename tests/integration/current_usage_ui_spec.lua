local app, state, sync = require("opencode"), require("opencode.state"), require("opencode.sync")
local input, events, render = require("opencode.ui.input"), require("opencode.events"), require("opencode.ui.chat.render")
local projection = require("opencode.protocol.v2.messages")

describe("current usage surfaces", function()
	local saved, origin
	local usage = { input = 1000, output = 100, reasoning = 20, cache = { read = 800, write = 80 } }
	local function info()
		local win = input.get_winids()[2]
		return win and vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)[1] or ""
	end
	local function wait_text(value)
		assert.is_true(vim.wait(500, function() return info():find(value, 1, true) ~= nil end, 1), info())
	end
	local function seed()
		state.upsert_session({ id = "usage", directory = "/project", cost = 1.5 }, { touch = false })
		sync.handle_providers({ { id = "p", name = "Provider", models = { m = { name = "Model", limit = { context = 10000 } } } } })
		sync.handle_agents({ { id = "build", name = "Build" } })
		state.upsert_session({ id = "usage", agent = "build", model = { providerID = "p", id = "m" } }, { touch = false })
		sync.handle_session_messages("usage", { projection.project("usage", { id = "a", type = "assistant", agent = "build", model = { providerID = "p", id = "m" },
			tokens = usage, cost = 0.05, time = { created = 1, completed = 2 }, content = {}, finish = "stop" }) })
	end
	before_each(function()
		saved = { columns = vim.o.columns, lines = vim.o.lines, local_state = package.loaded["opencode.local"] }
		vim.o.columns, vim.o.lines = 180, 45
		app.setup({ server = { auto_start = false }, lualine = { enabled = false }, input = { width = 140 } })
		sync.clear_all(); state.set_session("usage", "Usage")
		package.loaded["opencode.local"] = {
			agent = { current = function() return { name = "build" } end, color = function() return "OpenCodeInputAgent" end },
			model = { parsed = function() return { name = "Model", provider = "Provider" } end },
			variant = { current = function() end },
		}
		seed()
		origin = vim.api.nvim_get_current_win()
	end)
	after_each(function()
		input.close(false); require("opencode.cleanup").reset_all()
		package.loaded["opencode.local"] = saved.local_state
		vim.o.columns, vim.o.lines = saved.columns, saved.lines
	end)

	it("reacts to native cost, history and revert events without typing or changing focus", function()
		local baseline = events.listener_count("sync_changed")
		input.show({ winid = origin })
		wait_text("ctx 2.0K (20%)"); wait_text("$1.50")
		assert.equals(baseline + 1, events.listener_count("sync_changed"))
		local focused = vim.api.nvim_get_current_win()
		events.emit("v2_event", { id = "evt_usage", type = "session.usage.updated", created = 3, data = { sessionID = "usage", cost = 2.75, tokens = usage } })
		wait_text("$2.75"); assert.equals(focused, vim.api.nvim_get_current_win())
		sync.handle_session_messages("usage", { projection.project("usage", { id = "u", type = "user", text = "Undo me", time = { created = 4 } }),
			projection.project("usage", { id = "b", type = "assistant", model = { providerID = "p", id = "m" }, tokens = { input = 3000, output = 100, reasoning = 20, cache = { read = 800, write = 80 } }, time = { created = 5 }, content = {} }) })
		events.emit("sync_changed", { session_id = "usage", kind = "message" })
		wait_text("ctx 4.0K (40%)")
		events.emit("v2_event", { id = "evt_revert", type = "session.revert.staged", created = 6, data = { sessionID = "usage", revert = { messageID = "u" } } })
		wait_text("ctx 2.0K (20%)"); wait_text("$2.75")
		input.close(false)
		assert.equals(baseline, events.listener_count("sync_changed"))
		events.emit("sync_changed", { session_id = "usage" })
		assert.is_false(input.is_visible())
	end)

	it("shows a partial family cost explicitly, omits unknowns, and keeps narrow output within the available width", function()
		state.upsert_session({ id = "unknown-child", parentID = "usage" }, { touch = false })
		input.show({ winid = origin }); wait_text("≥$1.50")
		input.close(false)
		state.set_session("empty", "Empty")
		input.show({ winid = origin })
		assert.is_nil(info():find("ctx ", 1, true)); assert.is_nil(info():find("$0", 1, true))
		input.close(false)
		local info_bar = require("opencode.ui.input.info_bar")
		state.set_session("usage", "Usage")
		local buf = vim.api.nvim_create_buf(false, true)
		info_bar.update({ visible = true, session_id = "usage", info_bufnr = buf, layout = { content_width = 21 } })
		assert.is_true(vim.fn.strdisplaywidth(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1]) <= 21)
		vim.api.nvim_buf_delete(buf, { force = true })
	end)

	it("renders step cost and detailed new/cached/total usage in high verbosity", function()
		local message = sync.get_message("usage", "a")
		local normal = render.render_metadata_footer(message, sync.get_messages("usage")):content()
		assert.truthy(normal:find("$0.05", 1, true)); assert.is_nil(normal:find("step ", 1, true))
		local config = state.get_config(); config.session.verbosity = "high"; state.set_config(config)
		local detailed = render.render_metadata_footer(message, sync.get_messages("usage")):content()
		assert.truthy(detailed:find("step 1.2k new + 800 cached = 2k tok", 1, true))
		assert.truthy(detailed:find("$0.05", 1, true))
	end)
end)
