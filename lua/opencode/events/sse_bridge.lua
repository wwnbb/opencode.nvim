local M = {}
local registered_events = nil
local registered_client = nil

function M.setup(events)
	local client = require("opencode.client")
	if registered_events == events and registered_client == client then
		return
	end
	registered_events = events
	registered_client = client

	client.on_event("*", function(_, data)
		if type(data) ~= "table" or not data._envelope then return end
		if client.is_explanation_session and client.is_explanation_session(data.sessionID) then return end
		events.emit("server_event", data._envelope)
	end)
	client.on_event("error", function(message)
		events.emit("error", message)
	end)
end

return M
