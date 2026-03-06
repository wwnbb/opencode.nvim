-- opencode.nvim - Loading spinner module
-- Event-driven spinner: frame advances only when explicitly ticked (on server events)

local M = {}

local SPINNER_NAME = "Spinning Bar"
local SPINNER_FRAMES = { "|", "/", "-", "\\" }

-- Spinner state
local state = {
	active = false,
	frame_index = 1,
}

-- Get current frame text
---@return string Current animation frame or empty string if not active
function M.get_frame()
	if not state.active then
		return ""
	end

	return SPINNER_FRAMES[state.frame_index] or ""
end

-- Get current animation name
---@return string|nil Current animation name or nil if not active
function M.get_animation_name()
	if state.active then
		return SPINNER_NAME
	end
	return nil
end

-- Check if spinner is active
---@return boolean True if spinner is running
function M.is_active()
	return state.active
end

-- Advance to the next frame (call this on each server event)
function M.tick()
	if not state.active then
		return
	end

	state.frame_index = state.frame_index + 1
	if state.frame_index > #SPINNER_FRAMES then
		state.frame_index = 1
	end
end

-- Start the spinner
function M.start()
	-- Don't restart if already active
	if state.active then
		return
	end

	state.frame_index = 1
	state.active = true

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner started", { animation = SPINNER_NAME })
	end
end

-- Stop the spinner animation
function M.stop()
	state.active = false
	state.frame_index = 1

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner stopped")
	end
end

-- Get formatted loading text with the current frame
---@param prefix? string Text to show before the animation (default: "Processing")
---@return string Formatted loading text
function M.get_loading_text(prefix)
	prefix = prefix or "Processing"
	local frame = M.get_frame()
	if frame == "" then
		return prefix .. "..."
	end
	return prefix .. " " .. frame
end

return M
