local M = {}

local state = require("opencode.ui.chat.state").state
local chat_edits = require("opencode.ui.chat.edits")

local function clear_float_focus_autocmds()
	if not state.focus_augroup then
		return
	end
	pcall(vim.api.nvim_del_augroup_by_id, state.focus_augroup)
	state.focus_augroup = nil
end

local function is_opencode_related_window(winid)
	if not winid or not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	if state.winid and winid == state.winid then
		return true
	end
	if state.session_tabs_winid and winid == state.session_tabs_winid then
		return true
	end
	if type(chat_edits.is_inline_diff_window) == "function" and chat_edits.is_inline_diff_window(winid) then
		return true
	end

	local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
	if ok_buf and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		local ft = vim.bo[bufnr].filetype
		if type(ft) == "string" and ft:match("^opencode") then
			return true
		end
	end

	local ok_input, input_ui = pcall(require, "opencode.ui.input")
	if ok_input and type(input_ui.get_winids) == "function" then
		for _, candidate in ipairs(input_ui.get_winids()) do
			if winid == candidate then
				return true
			end
		end
	end

	local ok_palette, palette = pcall(require, "opencode.ui.palette")
	if ok_palette and type(palette.get_winids) == "function" then
		for _, candidate in ipairs(palette.get_winids()) do
			if winid == candidate then
				return true
			end
		end
	end

	return false
end

---@param current_win number|nil
---@return boolean
local function mouse_is_inside_float_frame(current_win)
	if not state.float_dims then
		return false
	end
	local mouse = vim.fn.getmousepos()
	if type(mouse) ~= "table" then
		return false
	end
	local mouse_winid = tonumber(mouse.winid or 0) or 0
	if current_win and mouse_winid > 0 and mouse_winid ~= current_win then
		return false
	end

	local row = (tonumber(mouse.screenrow or 0) or 0) - 1
	local col = (tonumber(mouse.screencol or 0) or 0) - 1
	if row < 0 or col < 0 then
		return false
	end

	local frame = state.float_dims
	local frame_row = tonumber(frame.row) or 0
	local frame_col = tonumber(frame.col) or 0
	local frame_height = tonumber(frame.height) or 0
	local frame_width = tonumber(frame.width) or 0

	return row >= frame_row and row < frame_row + frame_height and col >= frame_col and col < frame_col + frame_width
end

---@param opts table|nil
---@field close fun()|nil
---@field focus_chat fun()|nil
function M.setup(opts)
	opts = opts or {}
	clear_float_focus_autocmds()

	state.focus_augroup = vim.api.nvim_create_augroup("OpenCodeFloatFocus_" .. tostring(state.bufnr or 0), { clear = true })

	vim.api.nvim_create_autocmd("WinEnter", {
		group = state.focus_augroup,
		callback = function()
			vim.schedule(function()
				if not state.visible then
					return
				end
				if state.tabpage and state.tabpage ~= vim.api.nvim_get_current_tabpage() then
					return
				end
				if not state.config or state.config.layout ~= "float" then
					return
				end
				if state.config.close_on_focus_lost == false then
					return
				end

				local nd_ok, nd = pcall(require, "opencode.ui.native_diff")
				if nd_ok and nd.is_active and nd.is_active() then
					return
				end

				local current_win = vim.api.nvim_get_current_win()
				if is_opencode_related_window(current_win) then
					return
				end
				if mouse_is_inside_float_frame(current_win) then
					if type(opts.focus_chat) == "function" then
						opts.focus_chat()
					end
					return
				end

				if type(opts.close) == "function" then
					opts.close()
				end
			end)
		end,
	})
end

function M.clear()
	clear_float_focus_autocmds()
end

return M
