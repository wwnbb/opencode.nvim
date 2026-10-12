describe("session shell process UI", function()
	local state, pending = require("opencode.state"), require("opencode.session.pending")
	local actions, stubs, timers, requests, saved_defer, saved_columns, saved_lines, processes, popup
	local function entry(id, sid)
		return { id = id or "sh_one", command = "echo 😀", status = "running", metadata = { sessionID = sid or "ses_a" },
			location = { directory = "/original" } }
	end
	local function output_text()
		return table.concat(vim.api.nvim_buf_get_lines(popup.bufnr, 3, -1, false), "\n")
	end
	local function stub(object, name, fn)
		stubs[#stubs + 1] = require("luassert.stub")(object, name, fn)
	end
	before_each(function()
		state.reset(); pending.clear_all(); state.upsert_session({ id = "ses_a", directory = "/original" }); state.set_session("ses_a", "A")
		state.set_connection("connected")
		actions, stubs, timers, requests = require("opencode.actions"), {}, {}, {}
		saved_defer, saved_columns, saved_lines = vim.defer_fn, vim.o.columns, vim.o.lines
		vim.o.columns, vim.o.lines = 120, 45
		vim.defer_fn = function(fn, delay)
			local timer = { fn = fn, delay = delay, closed = false }
			function timer:stop() end
			function timer:close() self.closed = true end
			function timer:is_closing() return self.closed end
			timers[#timers + 1] = timer; return timer
		end
		stub(actions, "get_shell", function(id, opts, cb)
			assert.equals("sh_one", id); assert.equals("/original", opts.directory)
			cb(nil, entry())
		end)
		stub(actions, "get_shell_output", function(id, opts, cb) requests[#requests + 1] = { id = id, opts = opts, cb = cb } end)
		processes = require("opencode.ui.palette.processes")
	end)
	after_each(function()
		if popup then popup:close(); popup = nil end
		for _, timer in ipairs(timers) do if not timer.closed then timer:close() end end
		for _, replacement in ipairs(stubs) do replacement:revert() end
		vim.defer_fn, vim.o.columns, vim.o.lines = saved_defer, saved_columns, saved_lines
		pending.clear_all(); state.reset(); require("opencode.sync").clear_all()
	end)

	it("reassembles multibyte output across native byte-page boundaries", function()
		popup = processes.output(entry())
		requests[1].cb(nil, { output = "A�", cursor = 3, size = 5, truncated = false })
		timers[#timers].fn()
		assert.equals(1, requests[2].opts.cursor)
		requests[2].cb(nil, { output = "😀", cursor = 5, size = 5, truncated = false })
		assert.equals("A😀", output_text())
		popup:close()
		local count = #requests
		timers[#timers].fn()
		assert.equals(count, #requests)
	end)

	it("resumes output after reconnect and ignores an old page without changing its original location", function()
		popup = processes.output(entry())
		local old = requests[1].cb
		pending.invalidate(); state.set_connection("idle")
		timers[#timers].fn()
		assert.equals(1, #requests)
		state.set_session("ses_b", "B"); state.set_connection("connected")
		timers[#timers].fn()
		old(nil, { output = "stale", cursor = 5, size = 5, truncated = false })
		assert.is_nil(output_text():find("stale", 1, true))
		assert.equals(0, requests[2].opts.cursor)
		assert.equals("/original", requests[2].opts.directory)
		requests[2].cb(nil, { output = "restored", cursor = 8, size = 8, truncated = false })
		assert.equals("restored", output_text())
	end)

	it("keeps final output when the running inventory no longer contains the process", function()
		popup = processes.output(entry())
		requests[1].cb(nil, { output = "done\n", cursor = 5, size = 5, truncated = false })
		requests[1].cb(nil, { output = "late duplicate", cursor = 14, size = 14, truncated = false })
		assert.equals("done\n", output_text())
	end)

	it("lists only this session and kills only the selected ID in its captured location", function()
		local menu, removed
		stub(actions, "list_shells", function(opts, cb)
			assert.equals("/original", opts.directory)
			cb(nil, { entry(), entry("sh_two"), entry("sh_unrelated", "ses_b") })
		end)
		stub(require("opencode.ui.menu"), "open", function(opts)
			menu = opts
			return { refresh = function() end, popup = { winid = vim.api.nvim_get_current_win() } }
		end)
		stub(actions, "remove_shell", function(id, opts, cb) removed = { id = id, opts = opts }; cb(nil) end)
		processes.list({ session_id = "ses_a" })
		assert.equals(2, #menu.items)
		state.set_session("ses_b", "B")
		menu.keys[2].handler(nil, menu.items[2])
		assert.equals("sh_two", removed.id)
		assert.equals("/original", removed.opts.directory)
	end)

	it("does not open the process list when its session changes while the request is pending", function()
		local reply, opened = nil, false
		stub(actions, "list_shells", function(_, cb) reply = cb end)
		stub(require("opencode.ui.menu"), "open", function() opened = true end)
		processes.list({ session_id = "ses_a" })
		state.set_session("ses_b", "B"); reply(nil, { entry() })
		assert.is_false(opened)
	end)
	it("cannot refresh, reopen or kill from a stale process menu after reconnect", function()
		local menu, loads, kills = nil, 0, 0
		stub(actions, "list_shells", function(_, cb) loads = loads + 1; cb(nil, { entry() }) end)
		stub(require("opencode.ui.menu"), "open", function(opts) menu = opts; return { popup = { winid = vim.api.nvim_get_current_win() }, refresh = function() end } end)
		stub(actions, "remove_shell", function() kills = kills + 1 end)
		processes.list({ session_id = "ses_a" }); pending.invalidate()
		menu.keys[1].handler(); menu.keys[2].handler(nil, menu.items[1]); menu.on_select(menu.items[1])
		assert.equals(1, loads); assert.equals(0, kills); assert.equals(0, #requests)
	end)
	it("reports endpoint capability failures without stopping ordinary chat", function()
		local notices = {}
		stub(vim, "notify", function(message) notices[#notices + 1] = message end)
		for _, status in ipairs({ 404, 405, 501, 503 }) do
			stub(actions, "list_shells", function(_, cb) cb({ status = status, message = "opaque server error" }) end)
			processes.list({ session_id = "ses_a" })
			stubs[#stubs]:revert(); table.remove(stubs)
			assert.matches("unavailable", notices[#notices]); assert.is_true(state.is_connected())
		end
	end)

	it("reports idle/background-unavailable work instead of claiming success", function()
		local count = 0
		stub(actions, "background_session", function() count = count + 1 end)
		processes.background({ session_id = "ses_a" })
		assert.equals(0, count)
		local sync = require("opencode.sync")
		sync.handle_session_messages("ses_a", { require("opencode.protocol.messages").project("ses_a", {
			id = "msg_running", type = "assistant", content = { { id = "call_shell", type = "tool", name = "shell", state = { status = "running" } } },
		}) })
		processes.background({ session_id = "ses_a" })
		assert.equals(1, count)
	end)
end)
