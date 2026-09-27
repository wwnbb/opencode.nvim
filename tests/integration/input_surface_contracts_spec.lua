describe("input surface contracts", function()
	local popup_obj, info_popup_obj, bufnr
	after_each(function()
		if info_popup_obj then info_popup_obj:unmount() end
		if popup_obj then popup_obj:unmount() end
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then vim.api.nvim_buf_delete(bufnr, { force = true }) end
		popup_obj, info_popup_obj, bufnr = nil, nil, nil
	end)

	it("mounts both real input windows with shared background and agent borders", function()
		require("opencode.ui.input.info_bar").setup_highlights()
		local user_bg = vim.api.nvim_get_hl(0, { name = "OpenCodeUserMessageBg" })
		local input_bg = vim.api.nvim_get_hl(0, { name = "OpenCodeInputBg" })
		assert(user_bg.link == "CursorLine", "user message background should default to CursorLine")
		assert(input_bg.link == "OpenCodeUserMessageBg", "input background should default to user message background")

		local popups = require("opencode.ui.input.popups")
		popup_obj, info_popup_obj = popups.mount({
			popup = {
				relative = "editor",
				position = { row = 1, col = 1 },
				size = { width = 20, height = 1 },
			},
			info = {
				relative = "editor",
				position = { row = 2, col = 1 },
				size = { width = 20, height = 1 },
			},
		})
		local popup_winhighlight = vim.wo[popup_obj.winid].winhighlight
		local info_winhighlight = vim.wo[info_popup_obj.winid].winhighlight
		assert(
			popup_winhighlight:find("Normal:OpenCodeInputBg", 1, true)
				and popup_winhighlight:find("EndOfBuffer:OpenCodeInputBg", 1, true),
			"input popup normal and empty cells should use the shared input background"
		)
		assert(
			info_winhighlight:find("Normal:OpenCodeInputBg", 1, true)
				and info_winhighlight:find("EndOfBuffer:OpenCodeInputBg", 1, true),
			"input info popup normal and empty cells should use the shared input background"
		)
		assert(
			popup_winhighlight:find("FloatBorder:OpenCodeInputBorderAgent", 1, true)
				and info_winhighlight:find("FloatBorder:OpenCodeInputBorderAgent", 1, true),
			"input popup border should keep the agent-specific highlight"
		)
	end)

	it("allows insert Escape while retaining normal Escape cancellation", function()
		local input_keymaps = require("opencode.ui.input.keymaps")
		bufnr = vim.api.nvim_create_buf(false, true)
		local function has_buffer_keymap(mode, lhs)
			for _, keymap in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
				if keymap.lhs == lhs then
					return true
				end
			end
			return false
		end

		input_keymaps.setup(bufnr, {
			keymaps = {
				send = "<C-g>",
				send_alt = "<C-x><C-s>",
				cancel = "<Esc>",
			},
		}, {
			send = function() end,
			cancel = function() end,
		})

		assert(not has_buffer_keymap("i", "<Esc>"), "input should allow <Esc> to leave insert mode")
		assert(has_buffer_keymap("n", "<Esc>"), "input should keep normal-mode <Esc> cancel mapping")
		vim.api.nvim_buf_delete(bufnr, { force = true })
	end)

end)
