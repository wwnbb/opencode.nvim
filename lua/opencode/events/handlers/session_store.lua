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

	-- Server-side session deletion (SSE session.deleted).
	-- Tolerates sessions this client never tracked (foreign project deletes).
	events.on("session_deleted", function(data)
		vim.schedule(function()
			local info = type(data) == "table" and data.info or nil
			local session_id = (type(data) == "table" and (data.sessionID or data.sessionId))
				or (type(info) == "table" and info.id)
				or nil
			if not session_id or session_id == "" then
				return
			end
			session_actions.handle_deleted(session_id, { reason = "session_deleted" })
		end)
	end)
end

return M
