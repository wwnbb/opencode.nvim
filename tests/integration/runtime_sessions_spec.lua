-- Runtime-session contracts migrated from the former require/setup smoke test.
-- Each case uses a fresh application graph and the real pinned UI dependencies.

local function is_opencode(name)
	return name == "opencode" or name:match("^opencode%.") ~= nil
end

describe("runtime sessions", function()
	local opencode, state, sync, saved_modules, autocmds, buffers, timers
	local original_defer, original_notify, notifications, original_winid

	before_each(function()
		saved_modules, autocmds, buffers, timers, notifications = {}, {}, {}, {}, {}
		for name, module in pairs(package.loaded) do
			if is_opencode(name) then saved_modules[name] = module; package.loaded[name] = nil end
		end
		for _, entry in ipairs(vim.api.nvim_get_autocmds({})) do
			if entry.id then autocmds[entry.id] = true end
		end
		for _, id in ipairs(vim.api.nvim_list_bufs()) do buffers[id] = true end
		original_winid = vim.api.nvim_get_current_win()
		original_defer, original_notify = vim.defer_fn, vim.notify
		vim.defer_fn = function(callback, delay)
			local timer = original_defer(callback, delay)
			timers[#timers + 1] = timer
			return timer
		end
		vim.notify = function(message, level)
			notifications[#notifications + 1] = { message = tostring(message), level = level }
		end
		opencode = require("opencode")
		local keymaps = {}
		for name in pairs(require("opencode.config").defaults.keymaps) do keymaps[name] = false end
		opencode.setup({
			server = { auto_start = false },
			keymaps = keymaps,
			chat = { session_tabs = { colors = {
				active_fg = "#ffffff", active_bg = "#3b82f6", inactive_bg = "#1f2937",
				running_fg = "#22c55e", active_running_fg = "#86efac",
			} } },
			lualine = { enabled = false },
		})
		state, sync = require("opencode.state"), require("opencode.sync")
	end)

	after_each(function()
		require("opencode.events.bus").clear()
		state.clear_listeners()
		require("opencode.session.pending").clear_all()
		require("opencode.events.handlers.v2").clear()
		require("opencode.completion").teardown()
		require("opencode.explanation").teardown()
		local chat = package.loaded["opencode.ui.chat"]
		if chat then chat.close() end
		for _, entry in ipairs(vim.api.nvim_get_autocmds({})) do
			if entry.id and not autocmds[entry.id] then pcall(vim.api.nvim_del_autocmd, entry.id) end
		end
		if vim.api.nvim_win_is_valid(original_winid) then vim.api.nvim_set_current_win(original_winid) end
		for _, id in ipairs(vim.api.nvim_list_bufs()) do
			if not buffers[id] then pcall(vim.api.nvim_buf_delete, id, { force = true }) end
		end
		for _, timer in ipairs(timers) do
			if not timer:is_closing() then timer:stop(); timer:close() end
		end
		local drained = false
		vim.schedule(function() drained = true end)
		vim.wait(500, function() return drained end, 10)
		vim.defer_fn, vim.notify = original_defer, original_notify
		for name in pairs(package.loaded) do if is_opencode(name) then package.loaded[name] = nil end end
		for name, module in pairs(saved_modules) do package.loaded[name] = module end
		for _, notice in ipairs(notifications) do
			assert.is_true(notice.level ~= vim.log.levels.ERROR and notice.level ~= vim.log.levels.WARN, notice.message)
		end
	end)

	local function active_ids()
		return vim.tbl_map(function(session) return session.id end, state.get_active_sessions())
	end

	it("registers distinct clear and new commands and offers close for an active session", function()
		local slash = require("opencode.slash")
		local commands = {}
		for _, command in ipairs(slash.get_commands()) do commands[command.name] = command end
		assert.is_not_nil(commands.clear)
		assert.is_not_nil(commands.new)
		assert.is_false(vim.tbl_contains(commands.new.aliases or {}, "clear"))
		state.set_session("runtime-session", "Runtime Session")
		commands = {}
		for _, command in ipairs(slash.get_commands()) do commands[command.name] = command end
		assert.is_not_nil(commands.close)
	end)

	it("keeps historical and untouched records out of runtime tabs while retaining backend counts", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_recent_sessions({ { id = "historical-session", title = "Historical Session", message_count = 5 } }, 30)
		state.upsert_session({ id = "remembered-session", title = "Remembered Session" }, { touch = false })
		assert.equals(5, state.get_session_record("historical-session").message_count)
		assert.same({ "runtime-session" }, active_ids())
	end)

	it("renders the runtime tab with configured static active and running colors", function()
		state.set_session("runtime-session", "Runtime Session")
		vim.cmd("new")
		local winid = vim.api.nvim_get_current_win()
		local chat_view = require("opencode.ui.chat.state").state
		chat_view.winid, chat_view.bufnr = winid, vim.api.nvim_win_get_buf(winid)
		require("opencode.ui.chat").update_winbar()
		assert.is_truthy(vim.wo[winid].winbar:find("Runtime Session", 1, true))
		local current = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarCurrent", link = false })
		assert.equals(0xffffff, current.fg)
		assert.equals(0x3b82f6, current.bg)
		local running = vim.api.nvim_get_hl(0, { name = "OpenCodeWinbarRunning", link = false })
		assert.equals(0x22c55e, running.fg)
		assert.equals(0x1f2937, running.bg)
	end)

	it("closes the current tab through the public API and selects its neighbor without deleting its record", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_session("second-session", "Second Session")
		assert.is_true(opencode.close_session({ silent = true }))
		assert.equals("runtime-session", state.get_session().id)
		assert.is_not_nil(state.get_session_record("second-session"))
		assert.same({ "runtime-session" }, active_ids())
	end)

	it("keeps the runtime root visible when navigating to a child", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_session("child-session", "Child Session", { runtime = false })
		assert.same({ "runtime-session" }, active_ids())
	end)

	it("shows pending widgets from a task child but excludes an unrelated session", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_session("child-session", "Child Session", { runtime = false })
		sync.handle_message_updated({
			id = "task-message", sessionID = "runtime-session", role = "assistant", time = { created = 1 },
		})
		sync.handle_part_updated({
			id = "task-part", messageID = "task-message", sessionID = "runtime-session",
			type = "tool", tool = "task", metadata = { sessionId = "child-session" },
		})
		local widgets = require("opencode.ui.chat.widget_support")
		assert.is_true(widgets.should_render("child-session", "pending", "runtime-session", false))
		assert.is_false(widgets.should_render("historical-session", "pending", "runtime-session", false))
	end)

	it("removes a runtime root while its child is being viewed", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_session("child-session", "Child Session", { runtime = false })
		state.remove_session("runtime-session")
		assert.same({}, active_ids())
	end)

	it("resets the message count when clearing the active session", function()
		state.set_session("runtime-session", "Runtime Session")
		state.set_message_count(7)
		state.set_session(nil, nil)
		assert.equals(0, state.get_message_count())
	end)
end)
