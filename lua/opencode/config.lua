-- opencode.nvim - Neovim frontend for OpenCode AI coding agent
-- Configuration module

local M = {}

-- Default configuration
M.defaults = {
	-- Server connection
	server = {
		command = "opencode",
		host = "localhost",
		auth = {
			username = "opencode",
			password = nil,
		},
		auto_start = true,
		-- External servers apply review decisions on the server. Set true only
		-- when their paths refer to the same files accessible by this Neovim.
		shared_filesystem = nil,
		startup_timeout = 10000,
		health_check_interval = 1000,
		shutdown_on_exit = true,
		use_shell_env = true,
		env = {},
		config_dir = vim.fn.stdpath("config") .. "/opencode",
	},

	-- Session
	session = {
		default_agent = "build",
		default_model = {
			providerID = "github-copilot",
			modelID = "gpt-5-mini",
		},
		parallel = {
			enabled = true,
			recent_limit = 30,
		},
	},

	-- Danger mode auto-approves permission requests while enabled.
	danger_mode = false,

	-- Manually requested inline code completion, independent of chat sessions.
	completion = {
		enabled = false,
		model = nil,
		variant = nil,
		options = nil,
		keymaps = { trigger = "<C-l>", accept = "<Tab>" },
		timeout_ms = 15000,
		max_lines = 12,
		context = {
			max_bytes = 24576,
			before_lines = 150,
			after_lines = 50,
			header_lines = 60,
			max_related_buffers = 2,
			related_lines = 60,
		},
	},

	-- One-shot explanation of a Visual selection, independent of chat and completion.
	explanation = {
		enabled = false,
		model = nil,
		variant = nil,
		options = nil,
		prompt = nil,
		language = "en",
		keymaps = { trigger = "K" },
		timeout_ms = 60000,
		context = {
			max_bytes = 24576,
			before_lines = 150,
			after_lines = 50,
			header_lines = 60,
			max_related_buffers = 2,
			related_lines = 60,
		},
	},

	-- Chat
	chat = {
		layout = "vertical",
		position = "right",
		width = 80,
		height = 20,
		max_rendered_messages = 60,
		max_user_message_lines = 120,
		close_on_focus_lost = true,
		tps = true, -- Show average output + reasoning tokens per second per turn
		session_tabs = {
			enabled = true,
			auto_fit = false,
			max_tabs = 3,
			separator = " │ ",
			colors = {},
			icons = {
				running = "●",
				waiting = "◈",
				idle = "○",
				error = "✕",
			},
		},
		keymaps = {
			close_session = "x",
			cancel_pending = "C",
			edit_pending = "E",
			steer_pending = "S",
		},
	},

	-- Input
	input = {
		min_height = 1,
		max_height = 20,
		history_file = vim.fn.stdpath("data") .. "/opencode_input_history.json",
		max_history = 100,
		keymaps = {
			send = "<C-g>",
			send_alt = "<C-x><C-s>",
			cancel = "<Esc>",
			history_prev = "<Up>",
			history_next = "<Down>",
			variant_cycle = "<C-t>",
			agent_cycle = "<C-a>",
			model_cycle = "<C-e>",
		},
	},

	-- Best-effort syntax highlighting for code-like chat surfaces
	syntax = {
		enabled = true,
		min_bytes = 24,
		max_lines = 500,
		max_bytes = 200 * 1024,
		assistant_markdown = true,
		user_markdown = true,
		input_markdown = true,
		tools = true,
		diffs = true,
		languages = {},
	},

	-- Thinking/reasoning display
	thinking = {
		enabled = true,
		highlight = "Comment",
		header_highlight = "WarningMsg",
	},

	-- Artifact changes
	changes = {
		auto_backup = true,
		max_changes = 100,
		confirm_destructive = true,
		file_patterns_to_confirm = {
			"%.env",
			"%.env%.",
			"config",
			"%.conf",
			"%.toml$",
			"%.yaml$",
			"%.yml$",
			"%.json$",
		},
	},

	-- Log viewer
	logs = {
		position = "bottom", -- "bottom" | "top" | "left" | "right"
		width = 80, -- for left/right splits
		height = 15, -- for top/bottom splits
		max_entries = 1000,
	},

	-- Lualine statusline component
	lualine = {
		enabled = true,
		show_attention = true,
		attention_icon = "◈",
		show_diff_stats = true,
		diff_stats_cache_ms = 2000,
		diff_stats_include_untracked = true,
		diff_stats_max_untracked_file_size = 1024 * 1024,
	},

	-- Command Palette (one borderless surface, using the current theme colors)
	palette = {
		width = 60, -- Total panel width, including the horizontal padding
		height = 20, -- Maximum visible list rows; title/search use 7 additional rows
		border = "none",
		frecency = true,
		show_keybinds = true,
		show_icons = false,
		categories = {
			"session",
			"model",
			"agent",
			"actions",
			"mcp",
			"navigation",
			"system",
		},
		frecency_file = vim.fn.stdpath("data") .. "/opencode_palette_frecency.json",
		max_frecency_entries = 100,
	},

	-- Outer border of popup dialogs (separate from chat.float and palette).
	popup = {
		border = "solid", -- "none" | "single" | "double" | "rounded" | "solid" | Nui style table
	},

	notifications = {
		enabled = true,
		permissions = true,
		questions = true,
		edits = true,
		done = true,
		errors = true,
		current_session = true,
	},

	-- Keymaps
	keymaps = {
		toggle = "<leader>oo",
		command_palette = "<leader>op",
		toggle_logs = "<leader>ol",
		close_session = "<leader>oq",
		abort = "<leader>ox",
		active_sessions = "<leader>oS",
	},
}

--- Merge user config with defaults
---@param opts table|nil User configuration
---@return table Merged configuration
function M.merge(opts)
	-- Unsupported options must fail visibly instead of silently surviving the
	-- deep merge and giving the impression that they still affect the plugin.
	local removed = {
		{ "session", "parallel", "use_prompt_async" },
		{ "chat", "message_display" },
		{ "thinking", "max_height" },
		{ "thinking", "truncate" },
		{ "thinking", "icon" },
		{ "markdown", "enable_code_highlight" },
		{ "server", "lazy" },
		{ "diff" },
	}
	for _, path in ipairs(removed) do
		local value = opts
		for _, key in ipairs(path) do
			if type(value) == "table" then value = rawget(value, key) else value = nil end
		end
		if value ~= nil then
			error("opencode.nvim: unsupported setup option " .. table.concat(path, ".") .. "; update your configuration", 2)
		end
	end
	local merged = vim.tbl_deep_extend("force", M.defaults, opts or {})
	local completion = merged.completion
	if type(completion) ~= "table" or type(completion.enabled) ~= "boolean" then
		error("opencode.nvim: completion.enabled must be a boolean", 2)
	end
	for _, key in ipairs({ "timeout_ms", "max_lines" }) do
		local value = completion[key]
		if type(value) ~= "number" or value < 1 or value % 1 ~= 0 then
			error("opencode.nvim: completion." .. key .. " must be a positive integer", 2)
		end
	end
	if type(completion.context) ~= "table" then error("opencode.nvim: completion.context must be a table", 2) end
	for key in pairs(M.defaults.completion.context) do
		local value = completion.context[key]
		local minimum = key == "max_bytes" and 1024 or 0
		if type(value) ~= "number" or value < minimum or value % 1 ~= 0 then
			error("opencode.nvim: completion.context." .. key .. " must be an integer >= " .. minimum, 2)
		end
	end
	if type(completion.keymaps) ~= "table" then error("opencode.nvim: completion.keymaps must be a table", 2) end
	for _, key in ipairs({ "trigger", "accept" }) do
		local value = completion.keymaps[key]
		if value ~= false and (type(value) ~= "string" or value == "") then
			error("opencode.nvim: completion.keymaps." .. key .. " must be a key sequence or false", 2)
		end
	end
	if completion.keymaps.trigger and completion.keymaps.accept
		and vim.api.nvim_replace_termcodes(completion.keymaps.trigger, true, false, true)
			== vim.api.nvim_replace_termcodes(completion.keymaps.accept, true, false, true) then
		error("opencode.nvim: completion trigger and accept keys must differ", 2)
	end
	local explanation = merged.explanation
	if type(explanation) ~= "table" or type(explanation.enabled) ~= "boolean" then
		error("opencode.nvim: explanation.enabled must be a boolean", 2)
	end
	if explanation.prompt ~= nil and (type(explanation.prompt) ~= "string" or not explanation.prompt:match("%S")) then
		error("opencode.nvim: explanation.prompt must be a non-empty string", 2)
	end
	if type(explanation.language) ~= "string" or not explanation.language:match("%S") then
		error("opencode.nvim: explanation.language must be a non-empty string", 2)
	end
	if type(explanation.timeout_ms) ~= "number" or explanation.timeout_ms < 1 or explanation.timeout_ms % 1 ~= 0 then
		error("opencode.nvim: explanation.timeout_ms must be a positive integer", 2)
	end
	if type(explanation.context) ~= "table" then error("opencode.nvim: explanation.context must be a table", 2) end
	for key in pairs(M.defaults.explanation.context) do
		local value = explanation.context[key]
		local minimum = key == "max_bytes" and 1024 or 0
		if type(value) ~= "number" or value < minimum or value % 1 ~= 0 then
			error("opencode.nvim: explanation.context." .. key .. " must be an integer >= " .. minimum, 2)
		end
	end
	if type(explanation.keymaps) ~= "table" then error("opencode.nvim: explanation.keymaps must be a table", 2) end
	local trigger = explanation.keymaps.trigger
	if trigger ~= false and (type(trigger) ~= "string" or trigger == "") then
		error("opencode.nvim: explanation.keymaps.trigger must be a key sequence or false", 2)
	end
	return merged
end

return M
