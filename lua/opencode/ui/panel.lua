local M = {}

---@param name string
---@return table
function M.get_hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

---@param name string
---@param fg_source string
---@param fallback string|nil
---@param extra_opts? table
function M.set_hl(name, fg_source, fallback, extra_opts)
	local cursor = M.get_hl("CursorLine")
	local fg_hl = M.get_hl(fg_source)
	local fallback_hl = fallback and M.get_hl(fallback) or {}
	local opts = {}
	if fg_hl.fg or fallback_hl.fg then
		opts.fg = fg_hl.fg or fallback_hl.fg
	end
	if cursor.bg then
		opts.bg = cursor.bg
	end
	if extra_opts then
		opts = vim.tbl_extend("force", opts, extra_opts)
	end
	if next(opts) == nil then
		opts.link = fallback or fg_source
	end
	vim.api.nvim_set_hl(0, name, opts)
end

---@param result table
---@param text string
---@param hl_group string
---@param opts table
---@return number line_index
---@return string line
---@return table[] rows
function M.add_line(result, text, hl_group, opts)
	return require("opencode.ui.chat.render").add_panel_line(result, text, hl_group, {
		prefix = opts.prefix,
		prefix_hl_group = opts.prefix_hl_group,
	})
end

---@param result table
---@param text string
---@param hl_group string
---@param opts table
---@return number line_index
---@return string line
---@return table[] rows
function M.add_raw_line(result, text, hl_group, opts)
	return require("opencode.ui.chat.render").add_panel_raw_line(result, text, hl_group, {
		prefix = opts.prefix,
		prefix_hl_group = opts.prefix_hl_group,
		width = opts.width,
		wrap = opts.wrap,
	})
end

---@param result table
---@param hl_group string
---@param opts table
function M.add_blank(result, hl_group, opts)
	require("opencode.ui.chat.render").add_panel_blank(result, hl_group, {
		prefix = opts.prefix,
		prefix_hl_group = opts.prefix_hl_group,
	})
end

return M
