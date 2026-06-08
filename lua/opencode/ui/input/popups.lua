-- opencode.nvim - Input popup construction

local M = {}

local Popup = require("nui.popup")

local BORDER = { "┃", "", "", "", "", "", "┃", "┃" }
local PADDING = { top = 1, bottom = 1, left = 1, right = 0 }

function M.mount(frame)
	local popup = Popup({
		enter = true,
		focusable = true,
		relative = frame.popup.relative,
		border = {
			style = BORDER,
			padding = PADDING,
		},
		position = frame.popup.position,
		size = frame.popup.size,
		zindex = frame.popup.zindex,
		buf_options = {
			buftype = "nofile",
			bufhidden = "wipe",
			swapfile = false,
			filetype = "opencode_input",
		},
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputBg,FloatBorder:OpenCodeInputBorderAgent",
			cursorline = false,
			wrap = true,
			linebreak = true,
			signcolumn = "no",
			number = false,
			relativenumber = false,
			scrolloff = 0,
		},
	})

	local info_popup = Popup({
		enter = false,
		focusable = false,
		relative = frame.info.relative,
		border = {
			style = BORDER,
			padding = PADDING,
		},
		position = frame.info.position,
		size = frame.info.size,
		zindex = frame.info.zindex,
		buf_options = {
			buftype = "nofile",
			bufhidden = "wipe",
		},
		win_options = {
			winhighlight = "Normal:OpenCodeInputBg,EndOfBuffer:OpenCodeInputInfo,FloatBorder:OpenCodeInputBorderAgent",
			signcolumn = "no",
			number = false,
			relativenumber = false,
		},
	})

	popup:mount()
	info_popup:mount()

	return popup, info_popup
end

function M.unmount(state)
	if state.info_popup then
		state.info_popup:unmount()
	end

	if state.popup then
		state.popup:unmount()
	end
end

return M
