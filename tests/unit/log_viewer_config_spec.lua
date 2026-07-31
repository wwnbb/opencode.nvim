-- Unit checks for log viewer configuration resolution.
-- Run with: ./tests/run.sh unit

describe("opencode log viewer configuration", function()
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
