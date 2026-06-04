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

---@class OpenCodePanelHelpers
---@field add_line fun(result: table, text: string, hl_group?: string, opts?: table): number, string, table[]
---@field add_raw_line fun(result: table, text: string, hl_group?: string, opts?: table): number, string, table[]
---@field add_blank fun(result: table, hl_group?: string, opts?: table): number, string, table[]
---@field add_separator fun(result: table)
---@field highlight_text fun(result: table, rows: table[]|nil, text: string, hl_group: string)
---@field get_hl fun(name: string): table
---@field set_hl fun(name: string, fg_source: string, fallback?: string, extra_opts?: table)

---@param opts table { prefix?: string, blank_prefix?: string, border_hl?: string, default_hl?: string }
---@return OpenCodePanelHelpers
function M.create_helpers(opts)
	opts = opts or {}
	local prefix = opts.prefix or "▏  "
	local blank_prefix = opts.blank_prefix or "▏"
	local border_hl = opts.border_hl
	local default_hl = opts.default_hl
	local render = require("opencode.ui.chat.render")

	local helpers = {}

	---@param result table
	---@param text string
	---@param hl_group string|nil
	---@param line_opts? table
	---@return number line_index
	---@return string line
	---@return table[] rows
	function helpers.add_line(result, text, hl_group, line_opts)
		local panel_opts = vim.tbl_extend("force", {
			prefix = prefix,
			prefix_hl_group = border_hl,
		}, line_opts or {})
		return render.add_panel_line(result, text, hl_group or default_hl, panel_opts)
	end

	---@param result table
	---@param text string
	---@param hl_group string|nil
	---@param line_opts? table
	---@return number line_index
	---@return string line
	---@return table[] rows
	function helpers.add_raw_line(result, text, hl_group, line_opts)
		local panel_opts = vim.tbl_extend("force", {
			prefix = prefix,
			prefix_hl_group = border_hl,
		}, line_opts or {})
		return render.add_panel_raw_line(result, text, hl_group or default_hl, panel_opts)
	end

	---@param result table
	---@param hl_group string|nil
	---@param blank_opts? table
	---@return number line_index
	---@return string line
	---@return table[] rows
	function helpers.add_blank(result, hl_group, blank_opts)
		local panel_opts = vim.tbl_extend("force", {
			prefix = blank_prefix,
			prefix_hl_group = border_hl,
		}, blank_opts or {})
		return render.add_panel_blank(result, hl_group or default_hl, panel_opts)
	end

	---@param result table
	function helpers.add_separator(result)
		result.lines = result.lines or {}
		table.insert(result.lines, "")
	end

	---@param result table
	---@param rows table[]|nil
	---@param text string
	---@param hl_group string
	function helpers.highlight_text(result, rows, text, hl_group)
		render.highlight_panel_text(result, rows, text, hl_group)
	end

	helpers.get_hl = M.get_hl
	helpers.set_hl = M.set_hl

	return helpers
end

return M
