local M = {}

function M.setup(events)
	local client = require("opencode.client")
	local logger = require("opencode.logger")

	-- Map SSE events to local events
	local sse_to_local = {
		["message.created"] = "message",
		["message.updated"] = "message_updated",
		["message.removed"] = "message_removed",
		["message.part.updated"] = "message_part_updated",
		["message.part.delta"] = "message_part_delta",
		["message.part.removed"] = "message_part_removed",
		["session.updated"] = "session_updated",
		["session.status"] = "session_status",
		["session.error"] = "session_error",
		["session.diff"] = "session_diff",
		["todo.updated"] = "todo_updated",
		["file.edited"] = "edit",
		["permission.requested"] = "permission",
		["permission.asked"] = "permission", -- Server sends permission.asked
		["permission.replied"] = "permission_replied",
		["question.asked"] = "question_asked",
		["question.replied"] = "question_replied",
		["question.rejected"] = "question_rejected",
			["server.connected"] = "server_connected",
			["error"] = "error",
		}

	for sse_event, local_event in pairs(sse_to_local) do
		client.on_event(sse_event, function(data)
			logger.debug("SSE event mapped", {
				sse_event = sse_event,
				local_event = local_event,
				sessionID = type(data) == "table" and data.sessionID or nil,
				messageID = type(data) == "table" and (data.messageID or (data.info and data.info.id)) or nil,
				role = type(data) == "table" and data.info and data.info.role or nil,
				part_type = type(data) == "table" and data.part and data.part.type or nil,
				status = type(data) == "table" and data.status and data.status.type or nil,
				error = type(data) == "table" and data.error or nil,
			})
			events.emit(local_event, data)
		end)
	end
	end

return M
