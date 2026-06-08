local M = {}

local util = require("opencode.events.util")

---@param current_session_id string|nil
---@param interaction_session_id string|nil
---@param logger table|nil
---@param kind string
function M.stop_spinner_if_visible(current_session_id, interaction_session_id, logger, kind)
	if not util.permission_session_is_relevant(current_session_id, interaction_session_id) then
		return
	end

	local spinner_ok, spinner = pcall(require, "opencode.ui.spinner")
	if spinner_ok and spinner.is_active and spinner.is_active() then
		spinner.stop()
		if logger then
			logger.debug("Stopped spinner for " .. kind .. " interaction", {
				session_id = interaction_session_id,
				current_session_id = current_session_id,
			})
		end
	end
end

return M
