-- opencode.nvim - Chat window lifecycle per layout
-- Creates, configures and closes the native window (float, split or tab) that
-- shows a view's transcript buffer. The chat instance owns state transitions,
-- rendering and teardown; this module only manages windows.

local cs = require("opencode.ui.chat.state")
return cs.factory("window", function(view)
local M = {}

local Popup = require("nui.popup")
local chat_float_focus = cs.module(view, require("opencode.ui.chat.float_focus"))
local chat_session_tabs = cs.module(view, require("opencode.ui.chat.session_tabs"))

local state = view
local FLOAT_CHAT_TOP_PADDING = 2

function M.dimensions(cfg)
	local ui = vim.api.nvim_list_uis()[1] or { width = vim.o.columns, height = vim.o.lines }
	local editor_width = (vim.o.columns and vim.o.columns > 0) and vim.o.columns or ui.width
	local width, height, row, col

	if cfg.layout == "float" then
		width = math.floor(editor_width * cfg.float.width)
		height = math.floor(ui.height * cfg.float.height)
		row = math.floor((ui.height - height) / 2)
		col = math.floor((editor_width - width) / 2)
	elseif cfg.layout == "vertical" then
		width = cfg.width
		height = ui.height
		row = 0
		col = cfg.position == "right" and (editor_width - width) or 0
	else
		width = editor_width
		height = cfg.height
		row = cfg.position == "bottom" and (ui.height - height) or 0
		col = 0
	end

	return { width = width, height = height, row = row, col = col }
end

---@param winid number|nil
function M.setup_options(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return
	end

	local wo = vim.wo[winid]
	wo.fillchars = "eob: "
	wo.wrap = true
	wo.linebreak = true
	wo.breakindent = true
	wo.number = false
	wo.relativenumber = false
	wo.signcolumn = "yes:1"
	wo.foldcolumn = "0"
	wo.cursorline = false
	wo.cursorcolumn = false
	-- Statuscolumn uses LineNr as its base even when line numbers are disabled.
	vim.api.nvim_win_call(winid, function()
		vim.opt_local.winhighlight:append({ LineNr = "OpenCodeChatPadding" })
	end)
	pcall(function()
		wo.statuscolumn = "  "
	end)
end

-- Register one-shot WinClosed teardown for the chat window in the given layout.
-- Split layouts need this too: without it state.visible stays true and the
-- animation timers keep mutating a buffer with no window.
local watched_windows = {}
function M.watch_closed(winid, on_closed)
	if not winid or not vim.api.nvim_win_is_valid(winid) or watched_windows[winid] then
		return
	end
	watched_windows[winid] = true
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(winid),
		once = true,
		callback = function()
			watched_windows[winid] = nil
			on_closed(winid)
		end,
	})
end

---Create the window for cfg.layout and show the transcript buffer in it.
---@param hooks { on_closed: fun(winid: integer), attach: fun(winid: integer), update_winbar: fun(), close: fun() }
function M.show(cfg, hooks)
	local dims = M.dimensions(cfg)

	if cfg.layout == "float" then
		-- Keep the outer frame stable while reserving top space for the fixed tabbar.
		local popup_row = dims.row + math.floor(FLOAT_CHAT_TOP_PADDING / 2)
		local popup_height = math.max(1, dims.height - FLOAT_CHAT_TOP_PADDING)
		local popup = Popup({
			relative = "editor",
			enter = true,
			focusable = true,
			border = {
				style = cfg.float.border,
				text = {
					top = cfg.float.title,
					top_align = cfg.float.title_pos,
				},
				padding = { FLOAT_CHAT_TOP_PADDING, 1, 0, 1 },
			},
			position = {
				relative = "editor",
				row = popup_row,
				col = dims.col,
			},
			size = { width = dims.width, height = popup_height },
			bufnr = state.bufnr,
			win_options = {
				fillchars = "eob: ",
				wrap = true,
				number = false,
				relativenumber = false,
				signcolumn = "no",
				foldcolumn = "0",
			},
		})

		popup:mount()
		state.layout = popup
		state.winid = popup.winid
		state.tabpage = vim.api.nvim_get_current_tabpage()
		M.setup_options(state.winid)
		hooks.update_winbar()
		if cfg.close_on_focus_lost ~= false then
			chat_float_focus.setup({
				close = hooks.close,
				focus_chat = chat_session_tabs.focus_chat_window,
			})
		end
		state.float_dims = dims

		M.watch_closed(popup.winid, hooks.on_closed)
	elseif cfg.layout == "tab" then
		require("opencode.context").preserve_source(function()
			vim.cmd("tabnew")
			state.winid = vim.api.nvim_get_current_win()
			state.tabpage = vim.api.nvim_get_current_tabpage()
			vim.api.nvim_win_set_buf(state.winid, state.bufnr)
		end)
		cs.workspace.tabpage = state.tabpage
		hooks.attach(state.winid)
	else
		local split_cmd

		if cfg.layout == "vertical" then
			split_cmd = cfg.position == "right" and "botright vsplit" or "topleft vsplit"
		else
			split_cmd = cfg.position == "bottom" and "botright split" or "topleft split"
		end

		vim.cmd(split_cmd)
		state.winid = vim.api.nvim_get_current_win()
		state.tabpage = vim.api.nvim_get_current_tabpage()
		vim.api.nvim_win_set_buf(state.winid, state.bufnr)

		if cfg.layout == "vertical" then
			vim.api.nvim_win_set_width(state.winid, cfg.width)
		else
			vim.api.nvim_win_set_height(state.winid, cfg.height)
		end

		vim.wo[state.winid].winfixwidth = cfg.layout == "vertical"
		vim.wo[state.winid].winfixheight = cfg.layout == "horizontal"
		M.setup_options(state.winid)
		M.watch_closed(state.winid, hooks.on_closed)
		hooks.update_winbar()
	end
end

---Close the native chat window. A tab-layout view that is the last window of
---its layout hands the close to another layout instead.
---@return boolean delegated, any result close_view's result when delegated
function M.close_native()
	local closed_winid = state.winid
	if state.config.layout == "float" and state.layout then
		state.layout:unmount()
	else
		if state.winid and vim.api.nvim_win_is_valid(state.winid) then
			local normal_windows = 0
			for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(vim.api.nvim_win_get_tabpage(state.winid))) do
				if vim.api.nvim_win_get_config(winid).relative == "" then normal_windows = normal_windows + 1 end
			end
			if normal_windows == 1 then
				if state.config.layout == "tab" and view.workspace_id and not cs.workspace.switching
					and #cs.windows(view) == 1 then
					local workspace = require("opencode.ui.chat.workspace")
					local current_layout = workspace.current()
					if current_layout and current_layout.id == view.workspace_id then
						for _, layout in ipairs(workspace.list()) do
							if layout ~= current_layout then
								workspace.select(layout.id)
								return true, require("opencode.ui.chat").close_view(view)
							end
						end
					end
				end
				if state.config.layout == "tab" and #vim.api.nvim_list_tabpages() == 1 then
					vim.cmd("tabnew")
				elseif state.config.layout ~= "tab" then
					-- Closing a diff can leave chat as the tab's only normal window.
					vim.api.nvim_win_call(state.winid, function() vim.cmd("leftabove new") end)
				end
			end
			vim.api.nvim_win_close(closed_winid, true)
		end
	end
	return false
end

return M

end)
