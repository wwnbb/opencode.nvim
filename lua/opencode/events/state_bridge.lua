local M = {}

function M.setup(events)
	local state = require("opencode.state")

	-- Subscribe to state changes and emit corresponding events
	state.on("connection", function(new_val, old_val)
		events.emit("connection_change", { new = new_val, old = old_val })

		if new_val == "connected" then
			events.emit("connected", {})
		elseif new_val == "idle" and old_val == "connected" then
			events.emit("disconnected", { reason = "state_change" })
		end
	end)

	state.on("model.id", function(new_val, old_val)
		events.emit("model_change", { model = new_val, previous = old_val })
	end)

	state.on("agent.id", function(new_val, old_val)
		events.emit("agent_change", { agent = new_val, previous = old_val })
	end)

	-- Bridge pending changes events
	state.on("pending_changes.files", function(new_val, old_val)
		events.emit("changes_update", {
			files = new_val,
			stats = state.get_pending_changes_stats(),
		})
	end)
end

return M
