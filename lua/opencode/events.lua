-- opencode.nvim - Event system compatibility facade

local M = {}

local bus = require("opencode.events.bus")

for _, name in ipairs({
	"on",
	"once",
	"off",
	"emit",
	"get_history",
	"clear_history",
	"clear",
	"listener_count",
	"list_event_types",
}) do
	M[name] = bus[name]
end

local setup_modules = {
	{ name = "state bridge", load = function() return require("opencode.events.state_bridge") end },
	{ name = "SSE bridge", load = function() return require("opencode.events.sse_bridge") end },
	{ name = "message handlers", load = function() return require("opencode.events.handlers.message") end },
	{ name = "permission handlers", load = function() return require("opencode.events.handlers.permission") end },
	{ name = "question handlers", load = function() return require("opencode.events.handlers.question") end },
	{ name = "sync data handlers", load = function() return require("opencode.events.handlers.sync_data") end },
	{ name = "chat render coordinator", load = function() return require("opencode.ui.chat.render_coordinator") end },
}

local function setup_module(spec)
	local ok, mod = pcall(spec.load)
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
	for _, spec in ipairs(setup_modules) do
		setup_module(spec)
	end
end

return M
