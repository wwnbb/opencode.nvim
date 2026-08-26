-- opencode.nvim - Loading spinner module

local M = {}

local SPINNER_FRAMES = { "|", "/", "-", "\\" }
local FRAME_INTERVAL_MS = 120

-- Get current frame text
---@param now? number Monotonic milliseconds; injectable for deterministic tests.
---@return string Current animation frame
function M.get_frame(now)
	now = tonumber(now) or vim.uv.now()
	local frame_index = (math.floor(math.max(0, now) / FRAME_INTERVAL_MS) % #SPINNER_FRAMES) + 1
	return SPINNER_FRAMES[frame_index] or ""
end

---@return number
function M.get_interval_ms()
	return FRAME_INTERVAL_MS
end

-- Get formatted loading text with the current frame
---@param prefix? string Text to show before the animation (default: "Processing")
---@return string Formatted loading text
function M.get_loading_text(prefix)
	prefix = prefix or "Processing"
	local frame = M.get_frame()
	return prefix .. " " .. frame
end

return M
