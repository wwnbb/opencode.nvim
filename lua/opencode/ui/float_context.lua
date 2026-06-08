-- opencode.nvim - Shared floating window placement and focus helpers

local M = {}

local OVERLAY_ZINDEX = 80

local function chat_module()
	local ok, chat = pcall(require, "opencode.ui.chat")
	if ok then
		return chat
	end
	return nil
end

function M.focus_chat_if_visible()
	local chat = chat_module()
	if not chat or type(chat.is_visible) ~= "function" or not chat.is_visible() then
		return false
	end
	if type(chat.focus) ~= "function" then
		return false
	end
	return pcall(chat.focus)
end

local function is_valid_float_dims(float_dims)
	return type(float_dims) == "table"
		and type(float_dims.row) == "number"
		and type(float_dims.col) == "number"
		and type(float_dims.width) == "number"
		and type(float_dims.height) == "number"
		and float_dims.width >= 20
		and float_dims.height >= 8
end

local function get_chat_context()
	local target_win = nil
	local float_dims = nil
	local chat = chat_module()

	if chat then
		if type(chat.get_winid) == "function" then
			local chat_winid = chat.get_winid()
			if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
				target_win = chat_winid
			end
		end
		if type(chat.get_float_dims) == "function" then
			float_dims = chat.get_float_dims()
		end
	end

	if not target_win then
		local current = vim.api.nvim_get_current_win()
		if current and vim.api.nvim_win_is_valid(current) then
			target_win = current
		end
	end

	return target_win, float_dims
end

function M.resolve_centered_placement(total_width, total_height)
	local target_win, float_dims = get_chat_context()
	local ui_list = vim.api.nvim_list_uis()
	local ui = ui_list and ui_list[1] or { width = 80, height = 24 }

	if is_valid_float_dims(float_dims) then
		local anchor_row = float_dims.row + 1
		local anchor_col = float_dims.col + 1
		local anchor_width = math.max(20, float_dims.width - 2)
		local anchor_height = math.max(8, float_dims.height - 2)
		local row = anchor_row + math.floor((anchor_height - total_height) / 2)
		local col = anchor_col + math.floor((anchor_width - total_width) / 2)

		row = math.max(0, math.min(row, math.max(0, ui.height - total_height)))
		col = math.max(0, math.min(col, math.max(0, ui.width - total_width)))

		return "editor", row, col, OVERLAY_ZINDEX
	end

	local win_width = ui.width
	local win_height = ui.height
	local relative = "editor"
	if target_win and vim.api.nvim_win_is_valid(target_win) then
		win_width = vim.api.nvim_win_get_width(target_win)
		win_height = vim.api.nvim_win_get_height(target_win)
		relative = { type = "win", winid = target_win }
	end

	local row = math.max(0, math.floor((win_height - total_height) / 2))
	local col = math.max(0, math.floor((win_width - total_width) / 2))
	return relative, row, col, nil
end

return M
