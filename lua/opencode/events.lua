-- opencode.nvim - Local event bus and server event setup

local M = {}

local bus = require("opencode.events.bus")
local setup_listener_generation = nil

for _, name in ipairs({
	"on",
	"once",
	"off",
	"emit",
	"get_history",
	"clear_history",
	"clear",
	"listener_count",
	"get_generation",
	"list_event_types",
}) do
	M[name] = bus[name]
end

---@param event_name string
---@param ... any
function M.safe_emit(event_name, ...)
	pcall(M.emit, event_name, ...)
end

local setup_modules = {
	{ name = "state bridge", module = "opencode.events.state_bridge" },
	{ name = "SSE bridge", module = "opencode.events.sse_bridge" },
	{ name = "server event handlers", module = "opencode.events.handlers.server" },
	{ name = "review", module = "opencode.events.handlers.review" },
	{ name = "interactions", module = "opencode.events.handlers.interactions" },
	{ name = "session store handlers", module = "opencode.events.handlers.session_store" },
	{ name = "notification handlers", module = "opencode.events.handlers.notifications" },
	{ name = "sync data handlers", module = "opencode.events.handlers.sync_data" },
	{ name = "chat render coordinator", module = "opencode.ui.chat.render_coordinator" },
}

local function setup_module(spec)
	local ok, mod = pcall(require, spec.module)
	if not ok then
		vim.notify("Failed to load OpenCode " .. spec.name .. ": " .. tostring(mod), vim.log.levels.WARN)
		return
	end
	if type(mod.setup) ~= "function" then
		vim.notify("OpenCode " .. spec.name .. " has no setup()", vim.log.levels.WARN)
		return
	end
	local setup_ok, err = pcall(mod.setup, M)
	if not setup_ok then
		vim.notify("Failed to setup OpenCode " .. spec.name .. ": " .. tostring(err), vim.log.levels.WARN)
	end
end

function M.setup()
	local listener_generation = type(M.get_generation) == "function" and M.get_generation() or nil
	if listener_generation ~= nil and setup_listener_generation == listener_generation then
		return
	end
	setup_listener_generation = listener_generation
	for _, spec in ipairs(setup_modules) do
		setup_module(spec)
	end
end

return M
