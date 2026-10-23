-- opencode.nvim - Proposed/actual diff pair
-- Opens a readonly scratch split with the proposed content LEFT of the actual
-- file window and diffs the two. Shared by the native diff tab and the chat's
-- inline diff split; callers own keymaps, window marks and teardown.

local M = {}

local syntax = require("opencode.ui.syntax")

---Open the proposed split beside `actual_win`, diff it against `actual_buf`,
---and leave focus on the actual window at its first change.
---@param actual_win integer Window showing the actual file (RIGHT side)
---@param actual_buf integer Buffer of the actual file
---@param opts { after: string, filepath: string, relative: string, on_split?: fun(win: integer) }
---@return integer proposed_win
---@return integer proposed_buf
function M.open(actual_win, actual_buf, opts)
	vim.api.nvim_set_current_win(actual_win)
	vim.cmd("leftabove vsplit")
	local proposed_win = vim.api.nvim_get_current_win()
	if opts.on_split then
		opts.on_split(proposed_win)
	end

	local proposed_buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_win_set_buf(proposed_win, proposed_buf)
	local proposed_lines = vim.split(opts.after or "", "\n", { plain = true })
	vim.api.nvim_buf_set_lines(proposed_buf, 0, -1, false, proposed_lines)

	-- Readonly scratch buffer
	vim.bo[proposed_buf].buftype = "nofile"
	vim.bo[proposed_buf].bufhidden = "wipe"
	vim.bo[proposed_buf].swapfile = false
	vim.bo[proposed_buf].modifiable = false

	local ft = vim.filetype.match({ filename = opts.filepath })
	if ft and ft ~= "" then
		vim.bo[proposed_buf].filetype = ft
		syntax.start_buffer(proposed_buf, ft, { scope = "diffs" })
		syntax.start_buffer(actual_buf, ft, { scope = "diffs" })
	end

	pcall(vim.api.nvim_buf_set_name, proposed_buf, "[proposed] " .. opts.relative)

	for _, winid in ipairs({ proposed_win, actual_win }) do
		vim.api.nvim_win_call(winid, function()
			vim.cmd("diffthis")
		end)
	end

	vim.api.nvim_set_current_win(actual_win)
	pcall(vim.cmd, "normal! ]c")
	return proposed_win, proposed_buf
end

return M
