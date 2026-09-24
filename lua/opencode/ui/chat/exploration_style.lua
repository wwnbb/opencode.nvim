-- Stable list headers with compact panels for expanded exploration output.
local tool_panel = require("opencode.ui.chat.tool_panel")
local M = {
	prefix = "   │ ",
	header_hl = "OpenCodeExploreHeader",
	output_hl = "OpenCodeExploreOutput",
	error_hl = "OpenCodeExploreError",
	body_error_hl = "OpenCodeExploreOutputError",
	border_hl = "OpenCodeExploreBorder",
}

require("opencode.ui.highlights").register("opencode.ui.chat.exploration_style", function()
	for name, source in pairs({
		[M.header_hl] = "Comment",
		[M.output_hl] = "Normal",
		[M.error_hl] = "DiagnosticError",
		[M.body_error_hl] = "DiagnosticError",
		[M.border_hl] = "Comment",
	}) do
		local hl = vim.api.nvim_get_hl(0, { name = source, link = false })
		local body = name == M.output_hl or name == M.body_error_hl or name == M.border_hl
		local bg = body and vim.api.nvim_get_hl(0, { name = "CursorLine", link = false }).bg or nil
		vim.api.nvim_set_hl(0, name, { fg = hl.fg, bg = bg, italic = false, bold = false })
	end
end)

M.panel = tool_panel.create_panel({
	prefix = M.prefix, blank_prefix = "   │", default_hl = M.output_hl, border_hl = M.border_hl,
})

function M.add_border(result, bottom)
	local render = require("opencode.ui.chat.render")
	local width = render.get_chat_text_width()
	render.add_panel_line(result, (bottom and "└" or "┌") .. string.rep("─", math.max(0, width - 4)),
		M.border_hl, { prefix = "   " })
end

function M.contain_background(result)
	for _, hl in ipairs(result.highlights) do
		if hl.col_start == 0 and (hl.hl_group == M.output_hl or hl.hl_group == M.body_error_hl
			or hl.hl_group == M.border_hl) then
			hl.col_start = 3
		end
	end
end
return M
