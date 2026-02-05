-- opencode.nvim - Loading spinner module
-- Animated spinner for processing states in the chat window

local M = {}

local animations = require("opencode.ui.animations")

-- Spinner state
local state = {
	active = false,
	timer = nil,
	frame_index = 1,
	current_animation = nil,
	callback = nil, -- Called on each frame update
	interval_ms = 100, -- Animation speed (ms per frame)
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

-- Advance to the next frame
local function next_frame()
	if not state.active or not state.current_animation then
		return
	end

	local frames = state.current_animation.frames
	state.frame_index = state.frame_index + 1
	if state.frame_index > #frames then
		state.frame_index = 1
	end

	-- Call the update callback if provided
	if state.callback then
		local ok, err = pcall(state.callback, M.get_frame())
		if not ok then
			local logger_ok, logger = pcall(require, "opencode.logger")
			if logger_ok then
				logger.warn("Spinner callback error", { error = tostring(err) })
			end
		end
	end
end

-- Start the spinner animation
---@param opts? table Options: { animation = string|nil, interval_ms = number|nil, on_frame = function|nil }
function M.start(opts)
	opts = opts or {}

	-- Don't restart if already active with the same animation
	if state.active and state.timer then
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
	state.callback = opts.on_frame
	state.interval_ms = opts.interval_ms or 100
	state.active = true

	-- Start timer using vim.uv (libuv timer)
	state.timer = vim.uv.new_timer()
	if state.timer then
		state.timer:start(
			0, -- Initial delay
			state.interval_ms, -- Repeat interval
			vim.schedule_wrap(function()
				if state.active then
					next_frame()
				end
			end)
		)
	end

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner started", { animation = state.current_animation.name })
	end
end

-- Stop the spinner animation
function M.stop()
	state.active = false

	if state.timer then
		state.timer:stop()
		state.timer:close()
		state.timer = nil
	end

	state.frame_index = 1
	state.callback = nil
	-- Keep current_animation so we use the same one if restarted quickly
	-- It will be re-randomized on next fresh start

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner stopped")
	end
end

-- Reset animation (pick a new random animation)
function M.reset()
	local was_active = state.active
	local old_callback = state.callback
	local old_interval = state.interval_ms

	M.stop()

	state.current_animation = nil -- Force new random selection

	if was_active then
		M.start({
			on_frame = old_callback,
			interval_ms = old_interval,
		})
	end
end

-- Set interval (can be called while running)
---@param ms number Interval in milliseconds
function M.set_interval(ms)
	state.interval_ms = ms

	-- Restart timer if active
	if state.active and state.timer then
		state.timer:stop()
		state.timer:start(0, ms, vim.schedule_wrap(function()
			if state.active then
				next_frame()
			end
		end))
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
