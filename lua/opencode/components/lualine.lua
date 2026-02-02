-- opencode.nvim - Lualine Component
-- Status line integration for OpenCode

local M = {}

-- Default configuration
local defaults = {
	mode = "normal", -- "minimal" | "normal" | "expanded"
	show_model = true,
	show_provider = false,
	show_agent = true,
	show_status = true,
	show_session = false,
	show_message_count = true,
	show_diff_stats = false,
	icons = {
		opencode = "󰚩",
		streaming = "●",
		thinking = "◐",
		idle = "○",
		paused = "⏸",
		error = "✗",
		disconnected = "⊘",
		separator = "│",
	},
	colors = {
		streaming = "DiagnosticInfo",
		thinking = "DiagnosticWarn",
		idle = "Comment",
		paused = "DiagnosticWarn",
		error = "DiagnosticError",
		disconnected = "Comment",
	},
	on_click = nil,
}

local config = vim.deepcopy(defaults)

-- Cache for status updates
local status_cache = {
	connected = false,
	state = "disconnected",
	model = nil,
	provider = nil,
	agent = nil,
	session_id = nil,
	session_name = nil,
	message_count = 0,
	diff_stats = { additions = 0, deletions = 0 },
}

-- Status to icon mapping
local function get_status_icon(state)
	return config.icons[state] or config.icons.idle
end

-- Status to highlight group mapping
local function get_status_hl(state)
	return config.colors[state] or config.colors.idle
end

-- Get model display name (shortened for minimal mode)
local function get_model_name(full_model, mode)
	if not full_model then
		return ""
	end

	if mode == "minimal" then
		-- Extract short name (e.g., "claude-sonnet-4-20250514" -> "claude")
		return full_model:match("^[^%-]+") or full_model:sub(1, 10)
	end

	return full_model:match("[^/]+$") or full_model
end

-- Get provider display name
local function get_provider_name(provider)
	if not provider then
		return ""
	end
	-- Capitalize first letter
	return provider:sub(1, 1):upper() .. provider:sub(2)
end

-- Format the component content
function M.format_status()
	local parts = {}

	-- Always show OpenCode icon in minimal/normal modes
	if config.mode ~= "expanded" then
		table.insert(parts, config.icons.opencode)
	end

	-- Status indicator
	if config.show_status then
		local icon = get_status_icon(status_cache.state)
		table.insert(parts, icon)
	end

	-- Separator after icon/status
	if #parts > 0 and (config.show_model or config.show_agent or config.show_session) then
		table.insert(parts, config.icons.separator)
	end

	-- Model
	if config.show_model and status_cache.model then
		local model_name = get_model_name(status_cache.model, config.mode)
		table.insert(parts, model_name)
	end

	-- Provider (only in expanded mode)
	if config.mode == "expanded" and config.show_provider and status_cache.provider then
		table.insert(parts, get_provider_name(status_cache.provider))
	end

	-- Agent/Mode
	if config.show_agent and status_cache.agent then
		table.insert(parts, status_cache.agent)
	end

	-- Session name (only in expanded mode)
	if config.mode == "expanded" and config.show_session and status_cache.session_name then
		table.insert(parts, status_cache.session_name)
	end

	-- Message count
	if config.show_message_count and status_cache.message_count > 0 then
		table.insert(parts, status_cache.message_count .. " msgs")
	end

	-- Diff stats (only in expanded mode)
	if config.mode == "expanded" and config.show_diff_stats then
		local stats = status_cache.diff_stats
		if stats.additions > 0 or stats.deletions > 0 then
			table.insert(parts, "+" .. stats.additions .. " -" .. stats.deletions)
		end
	end

	return table.concat(parts, " ")
end

-- Get highlight group for current state
function M.get_highlight()
	return get_status_hl(status_cache.state)
end

-- Update status from opencode state
function M.update_status(new_status)
	status_cache = vim.tbl_extend("force", status_cache, new_status or {})
end

-- Lualine component function
function M.component()
	local content = M.format_status()
	local hl = M.get_highlight()

	return content, hl
end

-- Setup configuration
function M.setup(opts)
	if opts then
		config = vim.tbl_deep_extend("force", defaults, opts)
	end

	-- Subscribe to status changes from the main plugin
	local ok, opencode = pcall(require, "opencode")
	if ok and opencode.on then
		opencode.on("status_change", function(status)
			M.update_status(status)
		end)

		opencode.on("connected", function()
			status_cache.connected = true
			status_cache.state = "idle"
		end)

		opencode.on("disconnected", function()
			status_cache.connected = false
			status_cache.state = "disconnected"
		end)
	end
end

-- Get current status (for external use)
function M.get_status()
	return vim.deepcopy(status_cache)
end

-- Toggle between display modes
function M.cycle_mode()
	local modes = { "minimal", "normal", "expanded" }
	local current_idx = 1

	for i, mode in ipairs(modes) do
		if mode == config.mode then
			current_idx = i
			break
		end
	end

	local next_idx = current_idx % #modes + 1
	config.mode = modes[next_idx]

	vim.notify("OpenCode lualine mode: " .. config.mode, vim.log.levels.INFO)
end

return M
