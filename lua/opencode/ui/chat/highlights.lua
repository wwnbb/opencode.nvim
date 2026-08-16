local M = {}

---Apply NuiLine highlights to a buffer.
---@param nui_lines NuiLine[]
---@param bufnr number
---@param ns_id number
---@param start_line number 0-indexed
---@param opts? table
function M.apply_nui_line_highlights(nui_lines, bufnr, ns_id, start_line, opts)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end

	opts = opts or {}
	local min_line = opts.min_line
	local max_line = opts.max_line
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for i, nui_line in ipairs(nui_lines) do
		local line = start_line + i
		local in_bounds = line >= 1 and line <= line_count
		local after_min = not min_line or line > min_line
		local before_max = not max_line or line <= max_line
		if in_bounds and after_min and before_max then
			nui_line:highlight(bufnr, ns_id, line)
		end
	end
end

---Apply NuiLine and extmark highlights to a buffer.
---@param nui_lines NuiLine[]
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

---@param bufnr number
---@param ns_id number
---@param highlights table[]|nil
---@param start_line number
---@param opts? table
function M.apply_extmark_highlights(bufnr, ns_id, highlights, start_line, opts)
	if type(highlights) ~= "table" then
		return
	end

	opts = opts or {}
	local min_line = opts.min_line
	local max_line = opts.max_line
	local line_count = vim.api.nvim_buf_line_count(bufnr)

	for _, hl in ipairs(highlights) do
		if type(hl) == "table" and hl.hl_group then
			local line = start_line + (hl.line or 0)
			local end_line = hl.end_line and (start_line + hl.end_line) or line
			local in_bounds = line >= 0 and line < line_count
			local after_min = not min_line or end_line >= min_line
			local before_max = not max_line or line < max_line
			if in_bounds and after_min and before_max then
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

return M
