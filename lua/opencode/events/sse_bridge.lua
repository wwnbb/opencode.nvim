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
		if type(data) == "table" and data._v2_envelope then events.emit("v2_event", data._v2_envelope) end
	end)
	client.on_event("error", function(message)
		events.emit("error", message)
	end)
end

return M
