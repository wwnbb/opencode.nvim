-- opencode.nvim - Searchable surface shared by menu.lua and palette.lua: one
-- borderless frame holding the title, a search input at row 3 and the result
-- list below it. Callers keep their own placement, rendering and keymaps.

local M = {}

local INPUT_ROW, INPUT_COL = 3, 4

---Window options shared by every layer; only the highlight mapping differs.
---@param winhighlight string
---@return table
function M.window_options(winhighlight)
	return {
		winhighlight = winhighlight,
		winblend = 0,
		wrap = false,
		cursorline = false,
		scrolloff = 0,
	}
end

---Sizes and inner positions of the three layers for a frame `width` columns wide.
---The result is a Popup:resize layout; the input is one row, inset to column 4.
---@param width number Frame width
---@param frame_height number
---@param list_row number Row of the result list inside the frame
---@param list_height number
---@return { frame: table, content: table, input: table }
function M.geometry(width, frame_height, list_row, list_height)
	return {
		frame = { size = { width = width, height = frame_height } },
		content = { position = { row = list_row, col = 1 }, size = { width = width - 2, height = list_height } },
		input = { position = { row = INPUT_ROW, col = INPUT_COL }, size = { width = math.max(1, width - 8), height = 1 } },
	}
end

---Popup.new layer specs: the shared geometry, frame placement and stacking
---(list above the frame, input above the list) plus each caller's own options.
---@param opts { relative: any, row: number, col: number, width: number, frame_height: number, list_row: number, list_height: number, zindex: number, frame?: table, content?: table, input?: table|false }
---@return { frame: table, content: table, input: table|nil }
function M.layers(opts)
	local layout = M.geometry(opts.width, opts.frame_height, opts.list_row, opts.list_height)
	layout.frame.relative = opts.relative
	layout.frame.position = { row = opts.row, col = opts.col }
	layout.frame.zindex = opts.zindex
	layout.content.zindex = opts.zindex + 1
	layout.input.zindex = opts.zindex + 2
	local layers = {}
	for _, name in ipairs({ "frame", "content", "input" }) do
		if opts[name] ~= false then
			layers[name] = vim.tbl_extend("force", layout[name], opts[name] or {})
		end
	end
	return layers
end

---Current search query: the input buffer's first line.
---@param bufnr number
---@return string
function M.query(bufnr)
	return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] or ""
end

---Show the placeholder over an empty search input.
---@param bufnr number Input buffer
---@param namespace number Namespace owned by the caller for this mark
---@param query string
---@param text string
---@param hl_group string
function M.render_placeholder(bufnr, namespace, query, text, hl_group)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
	vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
	if query == "" then
		vim.api.nvim_buf_set_extmark(bufnr, namespace, 0, 0, {
			virt_text = { { text, hl_group } },
			virt_text_pos = "overlay",
		})
	end
end

return M
