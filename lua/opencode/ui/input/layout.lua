-- opencode.nvim - Input popup geometry and resizing

local M = {}

local function winbar_height(winid)
	return vim.wo[winid].winbar ~= "" and 1 or 0
end

function M.can_fit(winid)
	return vim.api.nvim_win_get_width(winid) >= 5 and vim.api.nvim_win_get_height(winid) >= 5 + winbar_height(winid)
end

local function parent_geometry(winid)
	local position = vim.api.nvim_win_get_position(winid)
	return {
		row = position[1],
		col = position[2],
		width = vim.api.nvim_win_get_width(winid),
		height = vim.api.nvim_win_get_height(winid),
	}
end

function M.build(chat_winid, float_dims, cfg, constrain_to_parent)
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
	local max_height = constrain_to_parent
		and math.max(1, math.min(cfg.max_height, chat_win_height - padding_rows * 3 - info_height - winbar_height(chat_winid)))
		or cfg.max_height
	height = math.min(height, max_height)
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
			min_height = height,
			max_height = max_height,
			constrain_to_parent = constrain_to_parent,
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

	if current_layout.current_height >= (current_layout.max_height or cfg.max_height) then
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

function M.measure_height(state, win_width)
	local cfg = state.config
	local max_height = state.layout.max_height or cfg.max_height
	win_width = math.max(1, win_width)
	local display_lines = 0
	local function count(line)
		local line_width = vim.fn.strdisplaywidth(line)
		display_lines = display_lines + (line_width == 0 and 1 or math.ceil((line_width + 1) / win_width))
	end
	if state.paste_folds then
		vim.api.nvim_win_call(state.winid, function()
			local row, total = 1, vim.api.nvim_buf_line_count(state.bufnr)
			while row <= total and display_lines < max_height do
				local last = vim.fn.foldclosedend(row)
				if last >= row then display_lines, row = display_lines + 1, last + 1
				else count(vim.api.nvim_buf_get_lines(state.bufnr, row - 1, row, false)[1]); row = row + 1 end
			end
		end)
	else
		-- Later physical lines cannot change height once the maximum is reached.
		for _, line in ipairs(vim.api.nvim_buf_get_lines(state.bufnr, 0, max_height, false)) do
			if display_lines >= max_height then break end
			count(line)
		end
	end

	local min_height = state.history_search and state.history_search.draft.height or cfg.min_height
	return math.min(max_height, math.max(min_height, display_lines))
end

function M.restore_view(state, previous_height)
	local height = state.layout.current_height
	if height ~= previous_height and height == (state.layout.max_height or state.config.max_height) then
		-- Growing from one row otherwise leaves the paste's last line at the top.
		vim.api.nvim_win_call(state.winid, function()
			local cursor = vim.api.nvim_win_get_cursor(state.winid)
			vim.cmd("normal! zb")
			vim.api.nvim_win_set_cursor(state.winid, cursor)
		end)
	end
	M.lock_scroll(state)
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

	local new_height = M.measure_height(state, vim.api.nvim_win_get_width(state.winid))
	if new_height == current_layout.current_height then
		M.lock_scroll(state)
		return
	end

	local previous_height = current_layout.current_height
	current_layout.current_height = new_height
	local vertical_shift = math.max(0, new_height - (current_layout.min_height or cfg.min_height))

	state.popup:update_layout({
		position = { row = current_layout.row - vertical_shift, col = current_layout.col },
		size = { width = current_layout.content_width, height = new_height },
	})
	M.restore_view(state, previous_height)
end

function M.schedule_resize(state, on_resize)
	if state.resize_scheduled then
		return
	end

	state.resize_scheduled = true
	vim.schedule(function()
		state.resize_scheduled = false
		M.resize(state)
		if on_resize then on_resize() end
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
	local frame = M.build(state.parent_winid, float_dims, state.config, current_layout.constrain_to_parent)
	state.layout = frame.layout
	state.popup:update_layout(frame.popup)
	state.info_popup:update_layout(frame.info)
	M.resize(state)
end

return M
