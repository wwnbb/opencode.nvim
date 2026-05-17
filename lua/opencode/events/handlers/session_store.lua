local M = {}

function M.setup(events)
	local session_actions = require("opencode.session")

	local function refresh_all()
		session_actions.recount_pending()
	end

	events.on("connected", function()
		vim.schedule(function()
			session_actions.refresh_status()
			refresh_all()
		end)
	end)

	events.on("interaction_changed", function()
		vim.schedule(refresh_all)
	end)

	events.on("permission_pending", function()
		vim.schedule(refresh_all)
	end)

	events.on("question_pending", function()
		vim.schedule(refresh_all)
	end)

	events.on("edit_pending", function()
		vim.schedule(refresh_all)
	end)

	events.on("permission_removed", function()
		vim.schedule(refresh_all)
	end)

	events.on("question_removed", function()
		vim.schedule(refresh_all)
	end)

	events.on("edit_removed", function()
		vim.schedule(refresh_all)
	end)

	events.on("message_part_updated", function(data)
		local part = data and data.part
		if type(part) == "table" and part.type == "tool" and part.tool == "task" then
			vim.schedule(refresh_all)
		end
	end)

	events.on("session_change", function()
		vim.schedule(refresh_all)
	end)
end

return M
