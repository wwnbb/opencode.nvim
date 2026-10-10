local M = {}
function M.show()
	local input = require("opencode.ui.input")
	local part = input.get_editor_context()
	local id = require("opencode.state").get_session().id
	local status, path = require("opencode.editor_context").status(id, part)
	require("opencode.ui.menu").open({ title = " Editor Context ", width = 80,
		message = (status or "No pending context") .. (path and (" · " .. path) or ""), sort = false,
		items = { "Preview pending snapshot", "Dismiss pending snapshot", "Refresh from editor", "Settings / opt out" },
		on_select = function(choice)
			if require("opencode.state").get_session().id ~= id then return end
			if choice == "Dismiss pending snapshot" then input.dismiss_editor_context()
			elseif choice == "Refresh from editor" then input.refresh_editor_context()
			elseif choice == "Settings / opt out" then require("opencode.ui.palette.settings").show()
			elseif part then
				local popup, buf = require("opencode.ui.float").create_centered_popup({ title = " Pending Editor Context ", width = 90, height = 20 })
				popup:mount(); vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(part.text, "\n", { plain = true }))
				vim.bo[buf].modifiable = false; require("opencode.ui.float").setup_close_keymaps(buf, function() popup:unmount() end)
			end
		end })
end
function M.register(palette)
	palette.register({ id = "prompt.editor_context", title = "Editor Context", category = "prompt", slash = { name = "context" },
		run = M.show, on_select = function(ctx) return ctx.run() end })
end
return M
