describe("prompt history search", function()
	local state = require("opencode.state")
	local history = require("opencode.ui.input.history")
	local input = require("opencode.ui.input")
	local actions = require("opencode.actions")
	local menu = require("opencode.ui.menu")
	local pending = require("opencode.session.pending")
	local saved, path, picker, ctx, jobs, notices, focused

	local function flush()
		local done = false
		vim.schedule(function() done = true end)
		assert.is_true(vim.wait(500, function() return done end))
	end

	local function show(provider)
		state.set_config({ input = { history_file = path, history_search_provider = provider } })
		return require("opencode.ui.palette.history").show()
	end

	local function search(query)
		picker.on_search(query, ctx)
		return jobs[#jobs]
	end

	local function choose(index)
		local item = ctx.items[index or 1]
		assert.is_not_nil(item)
		ctx.close()
		picker.on_select(item, ctx)
		flush()
	end

	before_each(function()
		saved = { system = vim.system, executable = vim.fn.executable, notify = vim.notify, open = menu.open,
			focus_input = actions.focus_input, send = actions.send, getcwd = vim.fn.getcwd }
		state.reset()
		state.set_session("history-session", "History")
		path = vim.fn.tempname()
		history.configure({ history_file = path, max_history = 100 })
		history.clear()
		input.set_pending_draft("", {}, { mode = "normal" })
		picker, ctx, jobs, notices, focused = nil, nil, {}, {}, 0
		vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
		vim.fn.executable = function() return 1 end
		actions.focus_input = function() focused = focused + 1 end
		actions.send = function() error("History selection must not send a prompt") end
		vim.system = function(argv, opts, callback)
			local job = { argv = argv, opts = opts, callback = callback, killed = false }
			function job:kill() self.killed = true end
			jobs[#jobs + 1] = job
			return job
		end
		menu.open = function(opts)
			picker = opts
			ctx = { items = opts.items, closed = false }
			function ctx.set_items(items) if not ctx.closed then ctx.items = items end end
			function ctx.close()
				if ctx.closed then return end
				ctx.closed = true
				if opts.on_close then opts.on_close(ctx) end
			end
			return ctx
		end
	end)

	after_each(function()
		if ctx then ctx.close() end
		flush()
		input.close(false)
		history.clear()
		state.reset()
		vim.system, vim.fn.executable, vim.notify, menu.open = saved.system, saved.executable, saved.notify, saved.open
		actions.focus_input, actions.send, vim.fn.getcwd = saved.focus_input, saved.send, saved.getcwd
		os.remove(path)
	end)

	it("registers a palette command and defaults to grep", function()
		local commands = {}
		require("opencode.ui.palette.history").register({ register = function(command) commands[#commands + 1] = command end })
		assert.equals(1, #commands)
		assert.equals("prompt.history", commands[1].id)
		assert.equals("Search Prompt History", commands[1].title)
		assert.is_nil(commands[1].slash)
		assert.equals("grep", require("opencode.config").merge({}).input.history_search_provider)
	end)

	it("loads saved records newest first and restores full text and attachments into the current draft", function()
		local part = { type = "file", mime = "image/png", url = "data:image/png;base64,Yg==", _marker = "[Image 1]",
			source = { text = { value = "[Image 1]", start = -1, ["end"] = -1 } } }
		history.add("old")
		history.add("new\nsecond line [Image 1]", { part }, "normal")
		history.configure({ history_file = path .. ".other" })
		input.set_pending_draft("draft [Image 1]", { part }, { options = { context = { { type = "text", text = "keep context" } } } })
		assert.equals(show(), ctx)
		assert.equals(2, #ctx.items)
		assert.equals("new\nsecond line [Image 1]", ctx.items[1].entry.text)
		assert.equals("old", ctx.items[2].entry.text)
		assert.is_nil(ctx.items[1].label:find("\n", 1, true))
		choose()
		assert.equals("draft [Image 1]\n\nnew\nsecond line [Image 2]", input.get_pending_text())
		assert.equals(2, #input.get_pending_parts())
		assert.equals(part.url, input.get_pending_parts()[2].url)
		assert.equals("keep context", input.get_pending_options().context[1].text)
		assert.equals(1, focused)
		assert.equals("new\nsecond line [Image 1]", history.list()[2].text)
		assert.equals("[Image 1]", history.list()[2].parts[1]._marker)
	end)

	it("restores shell mode into an empty draft and preserves a conflicting chat draft", function()
		history.add("printf 'hello\\n'", {}, "shell")
		show()
		choose()
		assert.equals("shell", input.get_mode())
		assert.equals("printf 'hello\\n'", input.get_pending_text())
		input.set_pending_draft("keep chat", {}, { mode = "normal" })
		show()
		choose()
		assert.equals("keep chat", input.get_pending_text())
		assert.equals("normal", input.get_mode())
		assert.equals(1, focused)
		assert.is_true(#notices > 0)
	end)

	it("passes literal queries as arguments to the configured executable and history through stdin", function()
		history.add("Older\nsecond line")
		history.add("Newer")
		for _, case in ipairs({ { nil, "grep" }, { "ripgrep", "rg" } }) do
			show(case[1])
			local query = "-x [abc] $(touch example)"
			local job = search(query)
			assert.equals(case[2], job.argv[1])
			assert.is_true(vim.tbl_contains(job.argv, "-F"))
			assert.is_true(vim.tbl_contains(job.argv, "-n"))
			local pattern_index
			for index, arg in ipairs(job.argv) do if arg == "-e" then pattern_index = index + 1 end end
			assert.equals(query, job.argv[pattern_index])
			assert.equals("-", job.argv[#job.argv])
			assert.equals("string", type(job.opts.stdin))
			assert.matches("older second line", job.opts.stdin)
			assert.equals(0, #ctx.items)
			ctx.close()
		end
	end)

	it("ignores stale query results and cancels searches when changing query or closing", function()
		history.add("older")
		history.add("newer")
		show()
		local first = search("older")
		local second = search("newer")
		assert.is_true(first.killed)
		second.callback({ code = 0, stdout = "1:newer\n", stderr = "" })
		flush()
		assert.equals("newer", ctx.items[1].entry.text)
		first.callback({ code = 0, stdout = "2:older\n", stderr = "" })
		flush()
		assert.equals("newer", ctx.items[1].entry.text)
		local cleared = search("older")
		search("")
		assert.is_true(cleared.killed)
		assert.equals(2, #ctx.items)
		cleared.callback({ code = 0, stdout = "2:older\n", stderr = "" })
		flush()
		assert.equals(2, #ctx.items)
		assert.equals("newer", ctx.items[1].entry.text)
		local third = search("older")
		ctx.close()
		assert.is_true(third.killed)
		third.callback({ code = 2, stderr = "cancelled" })
		flush()
		assert.equals(0, #notices)
	end)

	it("treats no matches as an empty list and reports process failures without stale results", function()
		history.add("saved")
		show()
		search("missing").callback({ code = 1, stdout = "", stderr = "" })
		flush()
		assert.equals(0, #ctx.items)
		assert.equals(0, #notices)
		search("error").callback({ code = 2, stdout = "", stderr = "grep failed" })
		flush()
		assert.equals(0, #ctx.items)
		assert.equals(1, #notices)
		search("")
		assert.equals("saved", ctx.items[1].entry.text)
		vim.system = function() error("Executable disappeared") end
		assert.has_no.errors(function() search("failed spawn") end)
		flush()
		assert.equals(0, #ctx.items)
		assert.equals(2, #notices)
	end)

	it("restores all items when clearing an active query and never restarts a closed search", function()
		history.add("older"); history.add("newer")
		local backend = require("opencode.ui.history_search").new({ history_file = path })
		local results, loading
		local function update(items, busy) results, loading = items, busy end
		assert.equals("history", backend.items[1].kind)
		backend.search("older", update)
		assert.is_true(loading); assert.equals(0, #results)
		local job = jobs[1]
		backend.search("", update)
		assert.is_true(job.killed); assert.is_false(loading)
		assert.equals(2, #results); assert.equals("newer", results[1].entry.text)
		job.callback({ code = 0, stdout = "2:older\n" }); flush()
		assert.equals(2, #results); assert.equals("newer", results[1].entry.text)
		assert.equals(1, #jobs)
		backend.close()
		backend.search("newer", function() error("closed search called back") end)
		assert.equals(1, #jobs)
		assert.equals(0, #notices)
	end)

	it("ends loading on search failures and allows the pending callback to close the search", function()
		history.add("saved")
		local backend = require("opencode.ui.history_search").new({ history_file = path })
		local results, loading
		local function update(items, busy) results, loading = items, busy end
		backend.search("error", update)
		assert.is_true(loading)
		jobs[1].callback({ code = 2, stderr = "failed" }); flush()
		assert.is_false(loading); assert.same({}, results)
		vim.system = function() error("spawn failed") end
		backend.search("spawn", update)
		assert.is_false(loading); assert.same({}, results)
		backend.search("close", function(_, busy)
			assert.is_true(busy)
			backend.close()
		end)
		assert.equals(2, #notices)
	end)

	it("reports unsupported providers and unavailable executables without running a search", function()
		history.add("saved")
		show("unknown")
		if picker then search("saved"); ctx.close() end
		assert.equals(0, #jobs)
		assert.is_true(#notices > 0)
		picker, ctx, notices = nil, nil, {}
		vim.fn.executable = function() return 0 end
		show("ripgrep")
		if picker then search("saved") end
		assert.equals(0, #jobs)
		assert.is_true(#notices > 0)
	end)

	it("does not restore a selection after the draft, session, project or request generation changes", function()
		history.add("saved")
		for _, invalidate in ipairs({
			function() input.set_pending_draft("edited", {}) end,
			function() state.set_session("other", "Other") end,
			function() state.upsert_session({ id = "history-session", directory = "/moved-session" }) end,
			function() vim.fn.getcwd = function() return "/another-project" end end,
			function() pending.clear_session("history-session") end,
		}) do
			vim.fn.getcwd = saved.getcwd
			state.set_session("history-session", "History")
			input.set_pending_draft("keep", {}, { mode = "normal" })
			show()
			invalidate()
			local before = input.get_pending_text()
			choose()
			assert.equals(before, input.get_pending_text())
			assert.equals(0, focused)
		end
	end)

	it("matches Unicode, punctuation and later prompt lines with installed grep and ripgrep", function()
		vim.system, vim.fn.executable = saved.system, saved.executable
		history.add("Not this prompt")
		history.add("ПРОВЕРКА\nsecond [abc].lua", {}, "normal")
		for _, provider in ipairs({ "grep", "ripgrep" }) do
			local command = provider == "ripgrep" and "rg" or "grep"
			if saved.executable(command) == 1 then
				show(provider)
				for _, query in ipairs({ "проверка", "second [abc].lua", "проверка second" }) do
					search(query)
					assert.is_true(vim.wait(3000, function() return #ctx.items == 1 end), provider .. ": " .. query)
					assert.equals("ПРОВЕРКА\nsecond [abc].lua", ctx.items[1].entry.text)
				end
				ctx.close()
			end
		end
		assert.equals(0, #notices)
	end)
end)
