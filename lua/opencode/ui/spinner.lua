-- opencode.nvim - Loading spinner module
-- Event-driven spinner: frame advances only when explicitly ticked (on server events)

local M = {}

local animations = require("opencode.ui.animations")

-- Spinner state
local state = {
	active = false,
	frame_index = 1,
	current_animation = nil,
}

-- Get current frame text
---@return string Current animation frame or empty string if not active
function M.get_frame()
	if not state.active or not state.current_animation then
		return ""
	end

	local frames = state.current_animation.frames
	return frames[state.frame_index] or ""
end

-- Get current animation name
---@return string|nil Current animation name or nil if not active
function M.get_animation_name()
	if state.current_animation then
		return state.current_animation.name
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
	if not state.active or not state.current_animation then
		return
	end

	local frames = state.current_animation.frames
	state.frame_index = state.frame_index + 1
	if state.frame_index > #frames then
		state.frame_index = 1
	end
end

-- Start the spinner (picks a new random animation)
---@param opts? table Options: { animation = string|nil }
function M.start(opts)
	opts = opts or {}

	-- Don't restart if already active
	if state.active then
		return
	end

	-- Select animation: by name, or random
	if opts.animation then
		state.current_animation = animations.get_by_name(opts.animation)
	end

	-- If no animation specified or not found, pick a random one
	if not state.current_animation then
		state.current_animation = animations.get_random()
	end

	state.frame_index = 1
	state.active = true

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner started", { animation = state.current_animation.name })
	end
end

-- Stop the spinner animation and clear animation for next fresh pick
function M.stop()
	state.active = false
	state.frame_index = 1
	state.current_animation = nil

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
