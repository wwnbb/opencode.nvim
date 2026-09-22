-- opencode.nvim - Input popup geometry and resizing

local M = {}

local function parent_geometry(winid)
	local position = vim.api.nvim_win_get_position(winid)
	return {
		row = position[1],
		col = position[2],
		width = vim.api.nvim_win_get_width(winid),
		height = vim.api.nvim_win_get_height(winid),
	}
end

function M.build(chat_winid, float_dims, cfg)
	local height = cfg.min_height
	local info_height = 1
	local parent = parent_geometry(chat_winid)

	if float_dims then
		local info_top_pad = 1
		local padding_rows = 1
		local float_col = float_dims.col + 1
		local content_width = math.max(1, float_dims.width - 3)
		local row = float_dims.row + float_dims.height - height - padding_rows - info_height - info_top_pad

		return {
			layout = {
				is_float = true,
				float_dims = vim.deepcopy(float_dims),
				parent_geometry = parent,
				col = float_col,
				row = row,
				info_height = info_height + info_top_pad,
				padding_rows = padding_rows,
				current_height = height,
				content_width = content_width,
			},
			popup = {
				relative = "editor",
				position = { row = row, col = float_col },
				size = { width = content_width, height = height },
				zindex = 51,
			},
			info = {
				relative = "editor",
				position = {
					row = float_dims.row + float_dims.height - info_height - info_top_pad,
					col = float_col,
				},
				size = { width = content_width, height = info_height },
				zindex = 51,
			},
		}
	end

	local chat_win_width = parent.width
	local chat_win_height = parent.height
	local padding_rows = 1
	local padding_cols = 1
	local total_height = height + padding_rows * 3 + info_height
	local width = math.max(1, chat_win_width - 2)
	local row = chat_win_height - total_height
	local col = 1
	local content_width = math.max(1, width - padding_cols * 2)

	return {
		layout = {
			is_float = false,
			parent_geometry = parent,
			chat_row = 0,
			chat_height = chat_win_height,
			col = col,
			row = row,
			content_width = content_width,
			padding_rows = padding_rows,
			info_height = info_height,
			current_height = height,
		},
		popup = {
			relative = { type = "win", winid = chat_winid },
			position = { row = row, col = col },
			size = { width = content_width, height = height },
		},
		info = {
			relative = { type = "win", winid = chat_winid },
			position = { row = row + height + padding_rows, col = col },
			size = { width = math.max(1, width - 2), height = info_height },
		},
	}
end

function M.lock_scroll(state)
	if not state.visible or not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local cfg = state.config
	local current_layout = state.layout
	if not cfg or not current_layout then
		return
	end

	if current_layout.current_height >= cfg.max_height then
		return
	end

	local view = vim.api.nvim_win_call(state.winid, function()
		return vim.fn.winsaveview()
	end)
	if view.topline == 1 and view.leftcol == 0 then
		return
	end

	vim.api.nvim_win_call(state.winid, function()
		vim.fn.winrestview({ topline = 1, leftcol = 0 })
	end)
end

function M.resize(state)
	if not state.visible or not state.bufnr or not state.winid or not state.popup then
		return
	end
	if not vim.api.nvim_win_is_valid(state.winid) then
		return
	end

	local cfg = state.config
	local current_layout = state.layout
	if not cfg or not current_layout then
		return
	end

	local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
	local win_width = math.max(1, vim.api.nvim_win_get_width(state.winid))
	local display_lines = 0

	for _, line in ipairs(lines) do
		if display_lines >= cfg.max_height then
			break
		end

		local line_width = vim.fn.strdisplaywidth(line)
		display_lines = display_lines + (line_width == 0 and 1 or math.ceil((line_width + 1) / win_width))
	end

	local new_height = math.max(cfg.min_height, math.min(display_lines, cfg.max_height))
	if new_height == current_layout.current_height then
		M.lock_scroll(state)
		return
	end

	current_layout.current_height = new_height
	local vertical_shift = math.max(0, new_height - cfg.min_height)

	state.popup:update_layout({
		position = { row = current_layout.row - vertical_shift, col = current_layout.col },
		size = { width = current_layout.content_width, height = new_height },
	})
	M.lock_scroll(state)
end

function M.schedule_resize(state)
	if state.resize_scheduled then
		return
	end

	state.resize_scheduled = true
	vim.schedule(function()
		state.resize_scheduled = false
		M.resize(state)
	end)
end

-- Parent/window dimensions can change without the draft changing its height.
-- Anchor both input surfaces to the current parent so the info bar stays visible.
function M.reflow(state)
	if not state.visible or not state.parent_winid or not vim.api.nvim_win_is_valid(state.parent_winid)
		or not state.popup or not state.info_popup then return end
	local current_layout = state.layout
	local parent = parent_geometry(state.parent_winid)
	local previous_parent = current_layout.parent_geometry
	-- Growing the draft also emits WinResized. Only reflow when the parent changed.
	if vim.deep_equal(parent, previous_parent) then return end

	local float_dims
	if current_layout.is_float then
		-- Preserve the float's original padding and editor-relative anchor while
		-- following actual parent movement/resizing (including Neovim clamping).
		float_dims = vim.deepcopy(current_layout.float_dims)
		for key, value in pairs(parent) do
			float_dims[key] = float_dims[key] + value - previous_parent[key]
		end
	end
	local frame = M.build(state.parent_winid, float_dims, state.config)
	state.layout = frame.layout
	state.popup:update_layout(frame.popup)
	state.info_popup:update_layout(frame.info)
	M.resize(state)
end

return M
