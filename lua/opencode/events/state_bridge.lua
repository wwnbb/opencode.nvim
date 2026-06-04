local M = {}

---@param event_bus OpencodeEventBus Event bus instance with emit/on methods
function M.setup(event_bus)
	local state = require("opencode.state")

	-- Subscribe to state changes and emit corresponding events
	state.on("connection", function(new_val, old_val)
		event_bus.emit("connection_change", { new = new_val, old = old_val })

		if new_val == "connected" then
			event_bus.emit("connected", {})
		elseif new_val == "idle" and old_val == "connected" then
			event_bus.emit("disconnected", { reason = "state_change" })
		end
	end)

	-- Bridge pending changes events. State listeners are exact-key, while
	-- file-level changes include the file path in the emitted key.
	state.on("*", function(changed_key)
		if type(changed_key) ~= "string" then
			return
		end
		if changed_key ~= "pending_changes" and not changed_key:match("^pending_changes%.files%.") then
			return
		end

		event_bus.emit("sync_changed", {
			kind = "changes",
			action = "updated",
		})
	end)
end

return M
