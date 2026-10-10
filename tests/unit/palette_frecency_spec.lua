describe("palette usage statistics", function()
	local app_state = require("opencode.state")
	local registry = require("opencode.command_registry")
	local float_context = require("opencode.ui.float_context")
	local saved_palette, palette, directory, path, old_config, old_defer, old_context, old_focus, deferred, old_columns, old_lines
	local alpha, beta = "palette.audit.alpha", "palette.audit.beta"

	local function configure(file)
		app_state.set_config({ palette = { frecency = true, frecency_file = file, show_keybinds = false } })
	end
	local function flush()
		for _, callback in ipairs(deferred) do callback() end
		deferred = {}
	end
	local function write(file, data)
		vim.fn.writefile({ vim.json.encode(data) }, file)
	end
	local function read(file)
		return vim.json.decode(table.concat(vim.fn.readfile(file)))
	end
	local function first_command()
		local win = palette.get_winids()[2]
		for _, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
			if line:find("Alpha", 1, true) then return "Alpha" end
			if line:find("Beta", 1, true) then return "Beta" end
		end
	end

	before_each(function()
		old_columns, old_lines = vim.o.columns, vim.o.lines
		saved_palette = package.loaded["opencode.ui.palette"]
		package.loaded["opencode.ui.palette"] = nil
		palette = require("opencode.ui.palette")
		palette.register_defaults = function() end
		old_config, old_defer = app_state.get_config(), vim.defer_fn
		old_context, old_focus = float_context.get_chat_context, float_context.focus_chat_if_visible
		float_context.get_chat_context = function() return nil end
		float_context.focus_chat_if_visible = function() return false end
		deferred = {}
		vim.defer_fn = function(callback) deferred[#deferred + 1] = callback end
		directory = vim.fn.tempname()
		vim.fn.mkdir(directory, "p")
		path = directory .. "/a.json"
		configure(path)
		for id, title in pairs({ [alpha] = "Alpha", [beta] = "Beta" }) do
			palette.register({ id = id, title = title, category = "actions", run = function() end })
		end
	end)
	after_each(function()
		palette.hide()
		vim.o.columns, vim.o.lines = old_columns, old_lines
		vim.cmd("stopinsert")
		vim.defer_fn = old_defer
		float_context.get_chat_context, float_context.focus_chat_if_visible = old_context, old_focus
		app_state.set_config(old_config)
		registry.unregister(alpha); registry.unregister(beta)
		package.loaded["opencode.ui.palette"] = saved_palette
		vim.fn.delete(directory, "rf")
	end)

	for index, name in ipairs({ "input", "results", "frame" }) do
		it("closes every palette layer when the " .. name .. " window is closed externally", function()
			palette.setup()
			local opener = vim.api.nvim_get_current_win()
			palette.show()
			local wins, buffers = palette.get_winids(), {}
			for _, win in ipairs(wins) do buffers[#buffers + 1] = vim.api.nvim_win_get_buf(win) end
			vim.api.nvim_win_close(wins[index], true)
			assert.is_true(vim.wait(500, function()
				if palette.is_visible() then return false end
				for _, win in ipairs(wins) do if vim.api.nvim_win_is_valid(win) then return false end end
				for _, buffer in ipairs(buffers) do if vim.api.nvim_buf_is_valid(buffer) then return false end end
				return true
			end, 5))
			assert.is_false(palette.is_visible())
			assert.equals(opener, vim.api.nvim_get_current_win())
			for _, win in ipairs(wins) do assert.is_false(vim.api.nvim_win_is_valid(win)) end
			for _, buffer in ipairs(buffers) do assert.is_false(vim.api.nvim_buf_is_valid(buffer)) end
			palette.show()
			assert.equals(3, #palette.get_winids())
		end)
	end

	it("clamps and redraws every layer after a viewport resize", function()
		vim.o.columns, vim.o.lines = 72, 28
		app_state.set_config({ palette = { width = 50, height = 12, frecency = false, show_keybinds = false } })
		palette.setup()
		palette.show()
		vim.o.columns, vim.o.lines = 30, 16
		vim.api.nvim_exec_autocmds("VimResized", {})
		local wins = palette.get_winids()
		local frame = vim.api.nvim_win_get_config(wins[3])
		assert.is_true(frame.col + frame.width <= vim.o.columns)
		assert.is_true(frame.row + frame.height <= vim.o.lines - vim.o.cmdheight)
		for _, win in ipairs(wins) do
			local width = vim.api.nvim_win_get_width(win)
			for _, line in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false)) do
				assert.is_true(vim.fn.strdisplaywidth(line) <= width, line)
			end
		end
		vim.o.columns, vim.o.lines = 72, 28
		vim.api.nvim_exec_autocmds("VimResized", {})
		assert.equals(50, vim.api.nvim_win_get_width(wins[3]))
		assert.equals(48, vim.api.nvim_win_get_width(wins[2]))
		assert.equals(vim.api.nvim_win_get_height(wins[2]) + 7, vim.api.nvim_win_get_height(wins[3]))
	end)

	it("matches Unicode characters and case without assembling a character from unrelated bytes", function()
		palette.register({ id = alpha, title = "Обзор кода 中", category = "actions", run = function() end })
		palette.register({ id = beta, title = "一哭", category = "actions", run = function() end })
		palette.setup()
		palette.show()
		local wins = palette.get_winids()
		local input, results = vim.api.nvim_win_get_buf(wins[1]), vim.api.nvim_win_get_buf(wins[2])
		for _, query in ipairs({ "中", "обзор", "ОК" }) do
			vim.api.nvim_buf_set_lines(input, 0, 1, false, { query })
			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = input })
			local text = table.concat(vim.api.nvim_buf_get_lines(results, 0, -1, false), "\n")
			assert.is_truthy(text:find("Обзор кода 中", 1, true), query)
			assert.is_nil(text:find("一哭", 1, true), query)
		end
	end)

	it("ignores malformed records without blocking display or command execution", function()
		for _, malformed in ipairs({ 42, "invalid", vim.NIL, { count = "invalid", last_used = 1 },
			{ count = -1, last_used = 1 }, { count = 1.25, last_used = 1 },
			{ count = 1, last_used = "invalid" }, { count = 1, last_used = -1 } }) do
			write(path, { [alpha] = malformed, [beta] = { count = 2, last_used = os.time() } })
			palette.setup()
			assert.is_true(pcall(palette.show))
			assert.equals("Beta", first_command())
			assert.is_true(pcall(palette.trigger, alpha))
			flush()
			assert.equals(1, read(path)[alpha].count)
			assert.equals(2, read(path)[beta].count)
			palette.hide()
		end
	end)

	it("keeps usage in its configured file when setup changes before deferred work runs", function()
		write(path, { [alpha] = { count = 4, last_used = os.time() } })
		palette.setup()
		palette.trigger(alpha)
		local other = directory .. "/b.json"
		configure(other)
		palette.setup()
		palette.trigger(beta)
		flush()
		assert.equals(5, read(path)[alpha].count)
		assert.is_nil(read(other)[alpha])
		assert.equals(1, read(other)[beta].count)
	end)

	it("resets statistics when the next configured file has no data", function()
		write(path, { [alpha] = { count = 4, last_used = os.time() } })
		palette.setup()
		palette.trigger(alpha)
		flush()
		local other = directory .. "/b.json"
		configure(other)
		palette.setup()
		palette.trigger(beta)
		flush()
		assert.is_nil(read(other)[alpha])
	end)

	it("reloads statistics when showing a newly configured palette", function()
		write(path, { [alpha] = { count = 20, last_used = os.time() } })
		palette.setup()
		local other = directory .. "/b.json"
		write(other, { [beta] = { count = 20, last_used = os.time() } })
		configure(other)
		palette.show()
		assert.equals("Beta", first_command())
	end)

	it("does not inflate scores for future timestamps", function()
		write(path, { [alpha] = { count = 1, last_used = 1e100 }, [beta] = { count = 2, last_used = os.time() } })
		palette.setup()
		palette.show()
		assert.equals("Beta", first_command())
	end)

	it("passes palette context to availability checks and reports command errors once", function()
		local calls, notices = 0, {}
		palette.register({ id = alpha, title = "Alpha", category = "actions",
			enabled = function(context) return context and context.source == "palette" end,
			run = function() calls = calls + 1; error("command failed") end,
		})
		palette.setup()
		local notify = vim.notify
		vim.notify = function(message) notices[#notices + 1] = message end
		local ok = pcall(palette.trigger, alpha)
		vim.notify = notify
		assert.is_true(ok)
		assert.equals(1, calls)
		assert.equals(1, #notices)
		assert.is_truthy(notices[1]:find("command failed", 1, true))
		palette.show()
		assert.equals("Alpha", first_command())
		vim.notify = function(message) notices[#notices + 1] = message end
		local input_buf = vim.api.nvim_win_get_buf(palette.get_winids()[1])
		local enter = vim.fn.maparg("<CR>", "i", false, true)
		assert.equals(input_buf, vim.api.nvim_get_current_buf())
		local selected = pcall(enter.callback)
		local ran = vim.wait(500, function() return calls == 2 end, 5)
		vim.notify = notify
		assert.is_true(selected)
		assert.is_true(ran)
		assert.equals(2, #notices)
	end)
end)
