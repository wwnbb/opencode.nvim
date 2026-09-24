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

	events.on("session_change", function(data)
		if not (data and data.preserve_cache) then
			require("opencode.permission.danger").clear()
			for _, id in ipairs(require("opencode.permission.state").clear_all() or {}) do
				events.emit("permission_removed", { permission_id = id })
			end
			for _, id in ipairs(require("opencode.question.state").clear_all() or {}) do
				events.emit("question_removed", { request_id = id })
			end
			for _, id in ipairs(require("opencode.edit.state").clear_all() or {}) do
				events.emit("edit_removed", { permission_id = id })
			end
			local reason = data and data.reason
			if data and data.previous_id and (reason == "clear" or reason == "disconnect") then
				require("opencode.sync").clear_session(data.previous_id)
			end
		end
		vim.schedule(refresh_all)
	end)
end

return M
