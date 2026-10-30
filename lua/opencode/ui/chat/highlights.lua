local M = {}

-- Marks are written without ids. NuiText:highlight reuses the id it stored on
-- the text, and cached NuiLines are shared across frames and views: reapplying
-- one would move the mark an unchanged copy elsewhere still relies on.
local scratch = {}

---Write the text highlights of nui_lines[first..last], the first at row.
---@param bufnr number
---@param ns_id number
---@param nui_lines NuiLine[]
---@param first integer 1-based index
---@param last integer 1-based inclusive index
---@param row integer 0-based row of nui_lines[first]
function M.write_nui_lines(bufnr, ns_id, nui_lines, first, last, row)
	local set_extmark = vim.api.nvim_buf_set_extmark
	for index = first, last do
		local line = nui_lines[index]
		local column = 0
		for _, text in ipairs(line and line._texts or {}) do
			local length = text:length()
			local extmark = text.extmark
			if extmark then
				for key, value in pairs(extmark) do
					if key ~= "id" then scratch[key] = value end
				end
				scratch.end_col = column + length
				local ok, err = pcall(set_extmark, bufnr, ns_id, row + index - first, column, scratch)
				for key in pairs(scratch) do scratch[key] = nil end
				if not ok then error(err, 0) end
			end
			column = column + length
		end
	end
end

---Apply NuiLine highlights to a buffer.
---@param nui_lines NuiLine[]
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed row of the first line
function M.apply_nui_line_highlights(nui_lines, bufnr, ns_id, start_line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	local first = math.max(1, 1 - start_line)
	local last = math.min(#nui_lines, line_count - start_line)
	if last >= first then
		M.write_nui_lines(bufnr, ns_id, nui_lines, first, last, start_line + first - 1)
	end
end

---Apply NuiLine and extmark highlights to a buffer.
---@param nui_lines OpenCodeRenderedLines
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed
function M.apply_highlights(nui_lines, bufnr, ns_id, start_line)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	M.apply_nui_line_highlights(nui_lines, bufnr, ns_id, start_line)
	M.apply_extmark_highlights(bufnr, ns_id, nui_lines._opencode_highlights, start_line)
end

---Apply highlights[first..last], each line relative to start_line.
---@param bufnr number
---@param ns_id number
---@param highlights table[]
---@param first integer
---@param last integer
---@param start_line number
function M.apply_extmark_range(bufnr, ns_id, highlights, first, last, start_line)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for index = first, last do
		local hl = highlights[index]
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			if line >= 0 and line < line_count then
				local col_start = math.max(0, hl.col_start or 0)
				local end_col = hl.end_col or hl.col_end
				if end_col == nil or end_col == -1 then
					local end_text = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1]
					end_col = end_text and #end_text or col_start
				end

				local mark_opts = {
					hl_group = hl.hl_group,
				}
				if hl.hl_eol ~= nil then
					mark_opts.hl_eol = hl.hl_eol
				end
				if hl.priority then
					mark_opts.priority = hl.priority
				end
				if end_line ~= line then
					mark_opts.end_row = end_line
					mark_opts.end_col = math.max(0, end_col)
				else
					mark_opts.end_col = math.max(col_start, end_col)
				end

				pcall(vim.api.nvim_buf_set_extmark, bufnr, ns_id, line, col_start, mark_opts)
			end
		end
	end
end

---@param bufnr number
---@param ns_id number
---@param highlights table[]|nil
---@param start_line number
function M.apply_extmark_highlights(bufnr, ns_id, highlights, start_line)
	if type(highlights) ~= "table" then
		return
	end
	M.apply_extmark_range(bufnr, ns_id, highlights, 1, #highlights, start_line)
end

-- Chat windows hide the cursor; refresh chat highlights after a colorscheme
-- change. Re-running replaces the previous autocmds.
function M.setup_window_autocmds()
	local group = vim.api.nvim_create_augroup("OpenCodeHighlights", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = function()
			local chat = package.loaded["opencode.ui.chat"]
			if chat and type(chat.handle_colorscheme) == "function" then
				chat.handle_colorscheme()
			end
		end,
		desc = "Update OpenCode highlights on colorscheme change",
	})
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		pattern = "opencode",
		callback = function()
			local cursor_hls = require("opencode.ui.highlights").HIDDEN_CURSOR_WINHIGHLIGHT
			vim.wo.winhighlight = (vim.wo.winhighlight ~= "" and vim.wo.winhighlight .. "," or "") .. cursor_hls
			vim.wo.cursorline = false
			vim.wo.cursorcolumn = false
		end,
		desc = "Hide cursor in OpenCode chat buffer",
	})
end

return M
