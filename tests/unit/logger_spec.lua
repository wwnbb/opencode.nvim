local state = require("opencode.state")
local logger = require("opencode.logger")
local viewer = require("opencode.ui.log_viewer")

describe("retained log entries", function()
	local config, schedule, refresh, columns, rows, help_win
	before_each(function()
		config = state.get_config()
		columns, rows = vim.o.columns, vim.o.lines
		help_win = nil
		schedule, refresh = vim.schedule, viewer.refresh
		logger.clear()
	end)
	after_each(function()
		vim.schedule, viewer.refresh = schedule, refresh
		if help_win and vim.api.nvim_win_is_valid(help_win) then vim.api.nvim_win_close(help_win, true) end
		vim.o.columns, vim.o.lines = columns, rows
		viewer.close()
		for _, buf in ipairs(vim.api.nvim_list_bufs()) do
			if vim.bo[buf].filetype == "opencode_logs" then vim.api.nvim_buf_delete(buf, { force = true }) end
		end
		viewer.setup(nil)
		logger.clear()
		state.set_config(config)
	end)

	it("retains only the newest entries up to the configured limit", function()
		state.set_config({ logs = { max_entries = 2 } })
		logger.debug("first")
		logger.debug("second")
		logger.debug("third")
		assert.same({ "second", "third" }, vim.tbl_map(function(entry) return entry.message end, logger.get_logs()))
	end)

	it("renders one current snapshot per burst and ignores already consumed or cleared callbacks", function()
		state.set_config({ logs = { max_entries = 10 } })
		viewer.open({ position = "bottom", height = 8 })
		local buffer, queued, rebuilds = vim.api.nvim_get_current_buf(), {}, 0
		vim.schedule = function(callback) queued[#queued + 1] = callback end
		viewer.refresh = function() rebuilds = rebuilds + 1; return refresh() end
		for _, message in ipairs({ "first", "second", "third" }) do
			logger.info(message, { data = { part = { messageID = "same-message" } } })
		end
		assert.equals(3, #queued)
		for _, callback in ipairs(queued) do callback() end
		assert.equals(1, rebuilds)
		local function contents() return table.concat(vim.api.nvim_buf_get_lines(buffer, 0, -1, false), "\n") end
		local rendered = contents()
		assert.equals("opencode_logs", vim.bo[buffer].filetype)
		for _, message in ipairs({ "first", "second", "third" }) do
			assert.is_truthy(rendered:find("[INFO] " .. message, 1, true))
		end
		for _, callback in ipairs(queued) do callback() end
		assert.equals(1, rebuilds)
		assert.equals(rendered, contents())

		logger.info("fourth")
		queued[4]()
		assert.equals(1, rebuilds) -- A single current entry still uses the incremental path.
		assert.is_truthy(contents():find("[INFO] fourth", 1, true))
		logger.info("cleared before rendering")
		viewer.clear_logs()
		local after_clear = rebuilds
		queued[5]()
		assert.equals(after_clear, rebuilds)
		assert.is_nil(contents():find("cleared before rendering", 1, true))
	end)

	for _, kind in ipairs({ "full", "incremental" }) do
		it("renders multiline messages with blank lines through the " .. kind .. " path", function()
			local queued = {}
			vim.schedule = function(callback) queued[#queued + 1] = callback end
			if kind == "incremental" then
				logger.info("Existing entry")
				viewer.open({ position = "bottom", height = 8 })
			end
			local message = "First line\n\n猫\tsecond line\n"
			logger.error(message)
			if kind == "full" then viewer.open({ position = "bottom", height = 8 })
			else queued[#queued]() end
			local buffer = vim.api.nvim_get_current_buf()
			local lines = vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
			local row
			for i, line in ipairs(lines) do if line:find("[ERROR] First line", 1, true) then row = i; break end end
			assert.is_number(row)
			assert.equals("", lines[row + 1])
			assert.equals("猫\tsecond line", lines[row + 2])
			assert.equals("", lines[row + 3])
			assert.is_false(vim.bo[buffer].modifiable)
			assert.equals(message, logger.get_logs()[#logger.get_logs()].message)
		end)
	end

	it("keeps log help readable and navigable in a small viewport", function()
		vim.o.columns, vim.o.lines = 30, 12
		viewer.open({ position = "bottom", height = 4 })
		local log_win = vim.api.nvim_get_current_win()
		viewer.show_help()
		help_win = vim.api.nvim_get_current_win()
		local buffer = vim.api.nvim_win_get_buf(help_win)
		assert.is_true(vim.api.nvim_win_get_height(help_win) < vim.api.nvim_buf_line_count(buffer))
		vim.api.nvim_feedkeys("G", "xt", false)
		assert.is_true(vim.api.nvim_win_is_valid(help_win), "scrolling must not close help")
		assert.equals(vim.api.nvim_buf_line_count(buffer), vim.api.nvim_win_get_cursor(help_win)[1])
		assert.is_true(vim.wo[help_win].wrap, "narrow help must wrap rather than clip descriptions")
		vim.api.nvim_feedkeys("q", "xt", false)
		assert.is_false(vim.api.nvim_win_is_valid(help_win))
		assert.equals(log_win, vim.api.nvim_get_current_win())

		viewer.show_help()
		help_win = vim.api.nvim_get_current_win()
		vim.api.nvim_set_current_win(log_win)
		assert.is_true(vim.wait(50, function() return not vim.api.nvim_win_is_valid(help_win) end))
		assert.equals(log_win, vim.api.nvim_get_current_win())
	end)

	it("shows configured log controls and effective help close keys", function()
		state.set_config({ help = { keymaps = { bottom = "q" } } })
		viewer.setup({ keymaps = { auto_scroll = { "<F8>", "<F9>" }, close = false } })
		viewer.open()
		local buf = vim.api.nvim_get_current_buf()
		assert.equals("", vim.fn.maparg("a", "n")); assert.equals("", vim.fn.maparg("q", "n"))
		vim.fn.maparg("<F8>", "n", false, true).callback()
		assert.is_truthy(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n"):find("<F8> / <F9> to toggle", 1, true))
		viewer.show_help(); help_win = vim.api.nvim_get_current_win()
		assert.equals("G", vim.fn.maparg("q", "n"))
		local lines = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(help_win), 0, -1, false), "\n")
		assert.is_truthy(lines:find("<F8> / <F9> - auto scroll", 1, true))
		assert.is_truthy(lines:find("<Esc> / <CR> / <Space> - Close help", 1, true))
	end)

	it("uses app logs config and keeps open overrides local", function()
		local highlight_ns = vim.api.nvim_create_namespace("opencode_log_viewer")
		local function has_highlight(buf, group)
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, highlight_ns, 0, -1, { details = true })) do
				if (mark[4] or {}).hl_group == group then return true end
			end
			return false
		end
		state.set_config(vim.tbl_deep_extend("force", vim.deepcopy(require("opencode.config").defaults),
			{ logs = { position = "right", width = 23, level_highlights = { INFO = "DiagnosticInfo" } } }))
		logger.info("configured log entry")
		viewer.open({ width = 31 })
		local winid = vim.api.nvim_get_current_win()
		local bufnr = vim.api.nvim_win_get_buf(winid)
		assert.equals("opencode_logs", vim.bo[bufnr].filetype)
		assert.equals(31, vim.api.nvim_win_get_width(winid))
		assert.equals(23, state.get_config().logs.width)
		assert.is_true(has_highlight(bufnr, "DiagnosticInfo"))
		viewer.setup({ level_highlights = { INFO = "String" } })
		viewer.refresh()
		assert.is_true(has_highlight(bufnr, "String"))
	end)
end)
