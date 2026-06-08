local M = {}

local request = require("opencode.events.handlers.permission_flow.request")
local edit_flow = require("opencode.events.handlers.permission_flow.edit")
local non_edit_flow = require("opencode.events.handlers.permission_flow.non_edit")
local lifecycle = require("opencode.events.handlers.permission_flow.lifecycle")
local artifacts = require("opencode.events.handlers.permission_flow.artifacts")

---@param fn function
---@return function
local function scheduled(fn)
	return function(data)
		vim.schedule(function()
			fn(data)
		end)
	end
end

---@param events table
---@param data table|nil
local function handle_permission(events, data)
	local logger = require("opencode.logger")
	logger.debug("Permission event received", { data = data })

	local permission_request, err = request.decode(data)
	if not permission_request then
		logger.debug("Permission event ignored", {
			reason = err,
			data = data,
		})
		return
	end

	local current_session = require("opencode.state").get_session()
	if permission_request.kind == "edit" then
		edit_flow.handle(events, permission_request, current_session, logger)
	else
		non_edit_flow.handle(events, permission_request, current_session, logger)
	end
end

function M.setup(events)
	events.on("tool_update", scheduled(function(data)
		artifacts.handle_tool_update(data, require("opencode.logger"))
	end))

	events.on("permission", scheduled(function(data)
		handle_permission(events, data)
	end))

	events.on("edit", scheduled(artifacts.handle_edit))
	events.on("session_diff", scheduled(artifacts.handle_session_diff))

	events.on("session_change", function(data)
		lifecycle.handle_session_change(events, data)
	end)

	events.on("permission_replied", scheduled(function(data)
		lifecycle.handle_permission_replied(events, data, require("opencode.logger"))
	end))
end

return M
