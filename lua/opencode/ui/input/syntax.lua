-- Fenced-code highlights for the editable input buffer.
local M = {}
local syntax = require("opencode.ui.syntax")
local namespace = vim.api.nvim_create_namespace("opencode_input_syntax")
local group = vim.api.nvim_create_augroup("OpenCodeInputSyntax", { clear = true })

function M.attach(bufnr)
	local active, scheduled = true, false
	local colorscheme_autocmd

	local function update()
		scheduled = false
		if not active or not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
			return
		end
		local text = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
		local highlights = syntax.highlight_markdown_fenced_blocks(text, {
			scope = "input_markdown",
			priority = vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter or 100,
		})
		vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
		for _, hl in ipairs(highlights) do
			vim.api.nvim_buf_set_extmark(bufnr, namespace, hl.line, hl.col_start, {
				end_col = hl.col_end,
				hl_group = hl.hl_group,
				priority = hl.priority,
			})
		end
	end

	local function schedule()
		if not active then return true end
		if scheduled then return end
		scheduled = true
		-- Buffer callbacks run under textlock. Coalesce edits and read the latest
		-- contents after typing, paste, completion or a programmatic draft update.
		vim.schedule(update)
	end

	local function detach()
		active = false
		if colorscheme_autocmd then
			vim.api.nvim_del_autocmd(colorscheme_autocmd)
			colorscheme_autocmd = nil
		end
	end

	if not vim.api.nvim_buf_attach(bufnr, false, {
		on_lines = schedule,
		on_reload = schedule,
		on_detach = detach,
	}) then
		return
	end
	colorscheme_autocmd = vim.api.nvim_create_autocmd("ColorScheme", {
		group = group,
		callback = schedule,
		desc = "Refresh code colors in the OpenCode input",
	})
	schedule()
end

return M
