-- opencode.nvim - Loading spinner module

local M = {}

local SPINNER_NAME = "Spinning Bar"
local SPINNER_FRAMES = { "|", "/", "-", "\\" }
local FRAME_INTERVAL_MS = 120

-- Spinner state
local state = {
	active = false,
	started_at = nil,
}

-- Get current frame text
---@return string Current animation frame or empty string if not active
function M.get_frame()
	if not state.active then
		return ""
	end

	local now = vim.uv.now()
	local started_at = state.started_at or now
	local elapsed = now - started_at
	if elapsed < 0 then
		elapsed = 0
	end

	local frame_index = (math.floor(elapsed / FRAME_INTERVAL_MS) % #SPINNER_FRAMES) + 1
	return SPINNER_FRAMES[frame_index] or ""
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

function M.tick()
	return
end

-- Start the spinner
function M.start()
	-- Don't restart if already active
	if state.active then
		return
	end

	state.started_at = vim.uv.now()
	state.active = true

	local logger_ok, logger = pcall(require, "opencode.logger")
	if logger_ok then
		logger.debug("Spinner started", { animation = SPINNER_NAME })
	end
end

-- Stop the spinner animation
function M.stop()
	state.active = false
	state.started_at = nil

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
