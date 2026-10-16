local M = {}

M.defaults = {
	-- Server connection
	server = {
		command = "opencode",
		host = "localhost",
		url = nil, -- Explicit HTTP(S) endpoint, including any reverse-proxy base path.
		managed = false, -- Discover the native CLI background service.
		service_file = nil, -- Native service registration override (read-only discovery).
		tls = {}, -- Optional ca_file for an installed OpenSSL TLS channel.
		auth = {
			username = "opencode",
			password = nil,
		},
		auto_start = true,
		-- External servers apply review decisions on the server. Set true only
		-- when their paths refer to the same files accessible by this Neovim.
		shared_filesystem = nil,
		path_mappings = {}, -- { remote = "/server/project", local_root = "/local/project" }
		startup_timeout = 10000,
		health_check_interval = 1000,
		shutdown_on_exit = true,
		use_shell_env = true,
		env = {},
		config_dir = vim.fn.stdpath("config") .. "/opencode",
	},

	session = {
		thinking = "hide", -- Collapsed Thought widgets remain expandable.
		grouping = "auto", -- "none" or "auto"
		verbosity = "medium", -- "low", "medium", or "high"
		markdown = "rendered", -- "rendered" or "source"
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

	-- Total byte budget for context placeholders expanded in a prompt.
	context = { max_bytes = 24576 },

	-- Manually requested inline code completion, independent of chat sessions.
	completion = {
		enabled = false,
		model = nil,
		variant = nil,
		options = nil,
		timeout_ms = 0, -- No deadline; positive values limit the request in milliseconds.
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
		timeout_ms = 0, -- No deadline; positive values limit the request in milliseconds.
		context = {
			max_bytes = 24576,
			before_lines = 150,
			after_lines = 50,
			header_lines = 60,
			max_related_buffers = 2,
			related_lines = 60,
		},
	},

	chat = {
		diff_view = "auto", -- "auto", "split", or "unified"
		layout = "vertical",
		position = "right",
		width = 80,
		height = 20,
		max_rendered_messages = 60,
		max_user_message_lines = 120,
		close_on_focus_lost = true,
		float = {
			width = 0.8,
			height = 0.8,
			border = "rounded",
			title = " OpenCode ",
			title_pos = "center",
		},
		tps = true, -- Show average output + reasoning tokens per second per turn
		session_tabs = {
			enabled = true,
			persist = true,
			scope = "global", -- "global" or "cwd", always isolated by server
			file = vim.fn.stdpath("data") .. "/opencode_tabs.json",
			auto_fit = false,
			max_tabs = 3,
			separator = " │ ",
			colors = {},
			icons = {
				running = "●",
				waiting = "◈",
				idle = "○",
				unread = "◆",
				error = "✕",
			},
		},
	},

	input = {
		editor_context = true,
		collapse_paste_lines = 20, -- false disables native folding of large clipboard pastes
		min_height = 1,
		max_height = 20,
		history_file = vim.fn.stdpath("data") .. "/opencode_input_history.json",
		max_history = 100,
		history_search_provider = "grep", -- "grep" or "ripgrep" (rg)
		stash_file = vim.fn.stdpath("data") .. "/opencode_stash.json",
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
			"package%.json",
			"Cargo%.toml",
			"go%.mod",
		},
	},

	-- Log viewer
	logs = {
		position = "bottom", -- "bottom" | "top" | "left" | "right"
		width = 80, -- for left/right splits
		height = 15, -- for top/bottom splits
		max_entries = 1000,
		level_highlights = {
			DEBUG = "Comment",
			INFO = "Normal",
			WARN = "WarningMsg",
			ERROR = "ErrorMsg",
		},
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

	-- Command Palette (one framed surface, using the current theme colors)
	palette = {
		width = 60, -- Total panel width, including the horizontal padding
		height = 20, -- Maximum visible list rows; title/search use 7 additional rows
		border = "rounded",
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
		border = "rounded", -- "none" | "single" | "double" | "rounded" | "solid" | Nui style table
	},

	notifications = {
		enabled = true,
		when = "always", -- "always" | "blurred" | "focused"
		permissions = true,
		questions = true,
		edits = true,
		done = true,
		errors = true,
		current_session = true,
	},
}

local keymap_defaults = require("opencode.keymap_defaults")
for scope, keys in pairs(keymap_defaults) do
	if scope == "global" then
		M.defaults.keymaps = keys
	elseif scope ~= "parents" then
		M.defaults[scope] = M.defaults[scope] or {}
		M.defaults[scope].keymaps = keys
	end
end

local function validate_keymaps(merged, opts)
	merged._keymap_overrides = {}
	for scope in pairs(keymap_defaults) do
		if scope ~= "parents" then
			local path = scope == "global" and "keymaps" or (scope .. ".keymaps")
			local values = scope == "global" and merged.keymaps or (merged[scope] or {}).keymaps
			if type(values) ~= "table" then error("opencode.nvim: " .. path .. " must be a table", 3) end
			local raw = scope == "global" and opts.keymaps or (type(opts[scope]) == "table" and opts[scope].keymaps)
			local explicit = {}
			for action, value in pairs(values) do
				local valid = value == false or type(value) == "string"
				if (scope == "completion" or scope == "explanation") and value == "" then valid = false end
				if type(value) == "table" and vim.islist(value) then
					valid = true
					for _, lhs in ipairs(value) do
						if type(lhs) ~= "string" or lhs == "" then valid = false; break end
					end
				end
				if not valid then
					error("opencode.nvim: " .. path .. "." .. action .. " must be a key sequence, a list of key sequences, or false", 3)
				end
				if type(raw) == "table" and raw[action] ~= nil then explicit[action] = true end
			end
			merged._keymap_overrides[scope] = explicit
		end
	end
end

local function validate_editor_feature(kind, feature)
	local prefix = "opencode.nvim: " .. kind
	if type(feature) ~= "table" or type(feature.enabled) ~= "boolean" then
		error(prefix .. ".enabled must be a boolean", 3)
	end
	local limits = kind == "completion" and { "timeout_ms", "max_lines" } or { "timeout_ms" }
	for _, key in ipairs(limits) do
		local value = feature[key]
		local minimum = key == "timeout_ms" and 0 or 1
		if type(value) ~= "number" or value < minimum or value % 1 ~= 0 then
			error(prefix .. "." .. key .. " must be an integer >= " .. minimum, 3)
		end
	end
	if type(feature.context) ~= "table" then error(prefix .. ".context must be a table", 3) end
	for key in pairs(M.defaults[kind].context) do
		local value = feature.context[key]
		local minimum = key == "max_bytes" and 1024 or 0
		if type(value) ~= "number" or value < minimum or value % 1 ~= 0 then
			error(prefix .. ".context." .. key .. " must be an integer >= " .. minimum, 3)
		end
	end
	if type(feature.keymaps) ~= "table" then error(prefix .. ".keymaps must be a table", 3) end
end

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
	local merged = vim.deepcopy(vim.tbl_deep_extend("force", M.defaults, opts or {}))
	validate_keymaps(merged, opts or {})
	if merged.input.history_search_provider ~= "grep" and merged.input.history_search_provider ~= "ripgrep" then
		error("opencode.nvim: input.history_search_provider must be grep or ripgrep", 2)
	end
	if type(merged.context) ~= "table" then error("opencode.nvim: context must be a table", 2) end
	local context_bytes = merged.context.max_bytes
	if type(context_bytes) ~= "number" or context_bytes < 1024 or context_bytes % 1 ~= 0 then
		error("opencode.nvim: context.max_bytes must be an integer >= 1024", 2)
	end
	local completion = merged.completion
	validate_editor_feature("completion", completion)
	local keymaps = require("opencode.util.keymap")
	for _, pair in ipairs({ { "trigger", "prompt" }, { "trigger", "accept" }, { "prompt", "accept" } }) do
		for _, key in ipairs(keymaps.keys(completion.keymaps[pair[1]])) do
			if keymaps.matches(completion.keymaps[pair[2]], key) then
				error("opencode.nvim: completion " .. pair[1] .. " and " .. pair[2] .. " keys must differ", 2)
			end
		end
	end
	local explanation = merged.explanation
	validate_editor_feature("explanation", explanation)
	if explanation.prompt ~= nil and (type(explanation.prompt) ~= "string" or not explanation.prompt:match("%S")) then
		error("opencode.nvim: explanation.prompt must be a non-empty string", 2)
	end
	if type(explanation.language) ~= "string" or not explanation.language:match("%S") then
		error("opencode.nvim: explanation.language must be a non-empty string", 2)
	end
	return merged
end

return M
