local M = {}

local event_bus_ref
local listeners_registered = false

---@param event_bus OpencodeEventBus Event bus instance with emit/on methods
function M.setup(event_bus)
	event_bus_ref = event_bus
	if listeners_registered then
		return
	end
	listeners_registered = true

	local state = require("opencode.state")

	-- Subscribe to state changes and emit corresponding events
	state.on("connection", function(new_val, old_val)
		event_bus_ref.emit("connection_change", { new = new_val, old = old_val })

		if new_val == "connected" then
			event_bus_ref.emit("connected", {})
		elseif new_val == "idle" and old_val == "connected" then
			event_bus_ref.emit("disconnected", { reason = "state_change" })
		end
	end)

	state.on("config", function(new_val, old_val)
		event_bus_ref.emit("config_change", { new = new_val, old = old_val })
	end)

end

return M
