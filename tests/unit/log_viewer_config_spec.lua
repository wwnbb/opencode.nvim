describe("opencode log viewer configuration", function()
	it("shows configured log controls and effective help close keys", function()
		local app, viewer = require("opencode.state"), require("opencode.ui.log_viewer")
		local previous_config, helpbuf, logbuf = app.get_config(), nil, nil
		local ok, err = xpcall(function()
			app.set_config({ help = { keymaps = { bottom = "q" } } })
			viewer.setup({ keymaps = { auto_scroll = { "<F8>", "<F9>" }, close = false } })
			viewer.open()
			local buf = vim.api.nvim_get_current_buf()
			logbuf = buf
			assert.equals("", vim.fn.maparg("a", "n")); assert.equals("", vim.fn.maparg("q", "n"))
			vim.fn.maparg("<F8>", "n", false, true).callback()
			local header = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
			assert.is_truthy(header:find("<F8> / <F9> to toggle", 1, true))
			viewer.show_help(); helpbuf = vim.api.nvim_get_current_buf()
			assert.equals("G", vim.fn.maparg("q", "n"))
			local lines = table.concat(vim.api.nvim_buf_get_lines(helpbuf, 0, -1, false), "\n")
			assert.is_truthy(lines:find("<F8> / <F9> - auto scroll", 1, true))
			assert.is_truthy(lines:find("<Esc> / <CR> / <Space> - Close help", 1, true))
			vim.fn.maparg("<Esc>", "n", false, true).callback()
		end, debug.traceback)
		if helpbuf and vim.api.nvim_buf_is_valid(helpbuf) then vim.api.nvim_buf_delete(helpbuf, { force = true }) end
		viewer.close()
		if logbuf and vim.api.nvim_buf_is_valid(logbuf) then vim.api.nvim_buf_delete(logbuf, { force = true }) end
		viewer.setup(nil); app.set_config(previous_config)
		assert.is_true(ok, err)
	end)
	it("uses app logs config and keeps open overrides local", function()
		vim.opt.runtimepath:append(vim.fn.getcwd())

		local app_state = require("opencode.state")
		local config = require("opencode.config")
		local logger = require("opencode.logger")
		local viewer = require("opencode.ui.log_viewer")
		local previous_config = app_state.get_config()
		local logs_config = {
			position = "right",
			width = 23,
			height = 9,
			level_highlights = { INFO = "DiagnosticInfo" },
		}
		local merged_config = vim.tbl_deep_extend("force", vim.deepcopy(config.defaults), { logs = logs_config })
		local highlight_ns = vim.api.nvim_create_namespace("opencode_log_viewer")
		local function has_highlight(buf, group)
			for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, highlight_ns, 0, -1, { details = true })) do
				if (mark[4] or {}).hl_group == group then
					return true
				end
			end
			return false
		end

		local function cleanup()
			local ok, err = pcall(function()
				viewer.close()
				viewer.setup(nil)
				logger.clear()
			end)
			app_state.set_config(previous_config)
			if not ok then
				error(err, 0)
			end
		end

		local ok, err = xpcall(function()
			viewer.setup(nil)
			app_state.set_config(merged_config)
			logger.clear()
			logger.info("configured log entry")
			viewer.open({ width = 31 })

			local winid = vim.api.nvim_get_current_win()
			local bufnr = vim.api.nvim_win_get_buf(winid)
			assert(vim.bo[bufnr].filetype == "opencode_logs", "log viewer should focus its configured split")
			assert(vim.api.nvim_win_get_width(winid) == 31, "open width should override app config for this open")
			assert(app_state.get_config().logs.width == 23, "open width should not mutate app config")

			assert(has_highlight(bufnr, "DiagnosticInfo"), "app level_highlights should affect rendered log entries")

			viewer.setup({ level_highlights = { INFO = "String" } })
			viewer.refresh()
			assert(has_highlight(bufnr, "String"), "direct viewer setup should override app level_highlights")
		end, debug.traceback)

		cleanup()
		if not ok then
			error(err, 0)
		end
	end)
end)
