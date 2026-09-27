-- Unit checks for command palette configuration and display-width layout.
-- Run with: ./tests/run.sh tests/unit/palette_config_layout_spec.lua

local function with_chat_stub(callback)
	local module_name = "opencode.ui.chat"
	local previous_preload = package.preload[module_name]
	local previous_loaded = package.loaded[module_name]

	package.preload[module_name] = function()
		return {
			is_visible = function()
				return false
			end,
		}
	end
	package.loaded[module_name] = nil

	local ok, err = xpcall(callback, debug.traceback)
	package.preload[module_name] = previous_preload
	package.loaded[module_name] = previous_loaded

	if not ok then
		error(err)
	end
end

describe("opencode command palette layout", function()
	it("uses state config, clears rerender highlights, and aligns Unicode text", function()
		with_chat_stub(function()
			local config = require("opencode.config")
			local state = require("opencode.state")
			local palette = require("opencode.ui.palette")
			local hl_ns = vim.api.nvim_create_namespace("opencode_palette")
			local previous_config = state.get_config()

			state.set_config(vim.tbl_deep_extend("force", {}, config.defaults, {
				popup = { border = "double" },
				palette = {
					width = 36,
					height = 8,
					border = "single",
					frecency = false,
					show_icons = false,
					show_keybinds = true,
					categories = { "system", "session" },
					frecency_file = vim.fn.tempname(),
				},
			}))

			palette.register({
				id = "palette.test.system",
				title = "System command",
				description = "palette test",
				category = "system",
				keybind = "⌘K",
				action = function() end,
			})
			palette.register({
				id = "palette.test.session",
				title = "界界界界界界界界界界界界界界界界界界界界",
				description = "palette test",
				category = "session",
				keybind = "<CR>",
				action = function() end,
			})

			palette.show()
			local wins = palette.get_winids()
			assert(#wins == 3, "palette should compose a frame, input, and results")

			local results_win = wins[2]
			local results_buf = vim.api.nvim_win_get_buf(results_win)
			local input_buf = vim.api.nvim_win_get_buf(wins[1])
			local win_config = vim.api.nvim_win_get_config(results_win)
			assert(win_config.width == 34, "palette should use configured width")
			assert(win_config.height == 5, "palette should shrink to the visible rows within configured height")
			local frame_config = vim.api.nvim_win_get_config(wins[3])
			assert(frame_config.width == 36, "configured width includes the dialog gutters")
			assert(frame_config.height == 12, "frame includes title, search, and bottom spacing")
			assert(frame_config.border[1][1] == "┌", "palette.border should be independent of popup.border")
			assert(vim.api.nvim_win_get_config(wins[1]).border == "none", "palette search should stay borderless")
			assert(win_config.border == "none", "palette result list should stay borderless")
			assert(win_config.win == wins[3], "results should be anchored inside the frame")
			assert(win_config.row == 5 and win_config.col == 1, "list should use TUI spacing")
			assert(vim.fn.prompt_getprompt(input_buf) == "", "search should have no prompt chevron")

			local lines = vim.api.nvim_buf_get_lines(results_buf, 0, -1, false)
			assert(lines[1] == "   System", "configured category order and icon visibility should apply")

			local function palette_marks()
				return vim.api.nvim_buf_get_extmarks(results_buf, hl_ns, 0, -1, { details = true })
			end

			local marks_before = palette_marks()
			assert(#marks_before == 5, "initial render should apply one mark per header, selection, and keybind")

			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = input_buf })
			vim.api.nvim_exec_autocmds("TextChangedI", { buffer = input_buf })
			local marks_after = palette_marks()
			assert(#marks_after == #marks_before, "rerender should not retain old palette extmarks")

			local session_line
			for line_number, line in ipairs(lines) do
				if line:find("...", 1, true) then
					session_line = line_number
					break
				end
			end
			assert(session_line, "Unicode title should be truncated with an ellipsis")
			local rendered_line = vim.api.nvim_buf_get_lines(results_buf, session_line - 1, session_line, false)[1]
			assert(
				vim.fn.strdisplaywidth(rendered_line) <= win_config.width,
				"rendered line should fit by display width"
			)

			local keybind_mark
			for _, mark in ipairs(marks_after) do
				local details = mark[4] or {}
				if details.hl_group == "OpenCodePaletteKeybind" and mark[2] == session_line - 1 then
					keybind_mark = mark
					break
				end
			end
			assert(keybind_mark, "Unicode command should have a keybind highlight")
			local keybind = "↵"
			local byte_col = rendered_line:find(keybind, 1, true) - 1
			assert(keybind_mark[3] == byte_col, "keybind extmark should use its byte offset")

			palette.hide()
			state.set_config(previous_config)
		end)
	end)
end)
