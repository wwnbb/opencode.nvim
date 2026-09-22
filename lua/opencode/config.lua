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
			use_prompt_async = true,
		},
	},

	-- Danger mode auto-approves permission requests while enabled.
	danger_mode = false,

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
		message_display = {
			user_prefix = "> ",
			multiline_prefix = true,
		},
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
		},
		todo = {
			enabled = true,
			show_dock = true,
			hide_when_done = true,
			default_collapsed = false,
			keymaps = {
				toggle = "T",
			},
			icons = {
				pending = "[ ]",
				in_progress = "[•]",
				completed = "[✓]",
				cancelled = "[ ]",
			},
			highlights = {
				pending = "Comment",
				in_progress = "WarningMsg",
				completed = "DiagnosticOk",
				cancelled = "Comment",
				header = "Title",
				border = "Comment",
			},
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

	-- Markdown rendering
	markdown = {
		enable_code_highlight = true,
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
		max_height = 15,
		truncate = true,
		icon = "💭",
		highlight = "Comment",
		header_highlight = "Title",
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

	-- Command Palette
	palette = {
		width = 70,
		height = 20,
		border = "rounded",
		frecency = true,
		show_keybinds = true,
		show_icons = true,
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
		abort = "<leader>ox",
		active_sessions = "<leader>oS",
	},
}

--- Merge user config with defaults
---@param opts table|nil User configuration
---@return table Merged configuration
function M.merge(opts)
	-- Deep merge user configuration with defaults
	return vim.tbl_deep_extend("force", M.defaults, opts or {})
end

return M
