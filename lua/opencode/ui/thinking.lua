-- Shared configuration for the v2 Thought activity widget.
local M = {}

local app_state = require("opencode.state")
local config_module = require("opencode.config")

function M.get_config()
	local defaults = config_module.defaults.thinking or {}
	local active = app_state.get_config() or {}
	return vim.tbl_deep_extend("force", vim.deepcopy(defaults),
		type(active.thinking) == "table" and active.thinking or {})
end

function M.is_enabled()
	return M.get_config().enabled ~= false
end

return M
