-- opencode.nvim - Neovim frontend for OpenCode AI coding agent
-- Configuration module

local M = {}

-- Default configuration
M.defaults = {
  -- Server connection
  server = {
    host = "localhost",
    port = 9099,
    auth = {
      username = "opencode",
      password = nil,
    },
    lazy = true,
    auto_start = true,
    startup_timeout = 10000,
    health_check_interval = 1000,
    shutdown_on_exit = false,
    reuse_running = true,
  },
  
  -- Session
  session = {
    auto_create = true,
    auto_restore = true,
    default_agent = "build",
    default_model = {
      providerID = "github-copilot",
      modelID = "gpt-5-mini",
    },
  },
  
  -- Chat
  chat = {
    layout = "vertical",
    position = "right",
    width = 80,
    height = 20,
  },

  -- Input
  input = {
    height = 5,
    border = "single",
    prompt = "> ",
    max_history = 100,
    persist_history = true,
    keymaps = {
      send = "<C-g>",
      send_alt = "<C-x><C-s>",
      cancel = "<Esc>",
      history_prev = "<Up>",
      history_next = "<Down>",
      stash = "<C-s>",
      restore = "<C-r>",
    },
  },

  -- Markdown rendering
  markdown = {
    enable_code_highlight = true,
    max_code_lines = 50,
    enable_inline_code = true,
    code_languages = {},
  },

  -- Tool calls
  tools = {
    enable_display = true,
    icons = {},
    status_icons = {},
    auto_expand_errors = true,
  },

  -- Thinking/reasoning display
  thinking = {
    enabled = true,
    max_height = 15,
    truncate = true,
    icon = "💭",
    highlight = "Comment",
    header_highlight = "Title",
    throttle_ms = 100,
  },

  -- Context attachment
  context = {
    max_attachments = 10,
    max_file_size = 1024 * 1024,
    excluded_patterns = {
      "%.git/",
      "node_modules/",
      "%.lock$",
      "%-lock%.",
    },
    preview = {
      enabled = true,
      height = 10,
      width = 60,
    },
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
  },

  -- Question tool
  question = {
    enabled = true,
    icon_pending = "💭",
    icon_answered = "✓",
    icon_rejected = "✗",
    highlight_header = "Title",
    highlight_selected = "CursorLine",
    highlight_option = "Normal",
    max_height = 10,
    show_keymap_hint = true,
    auto_focus = true,
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

  -- Keymaps
  keymaps = {
    toggle = "<leader>oo",
    command_palette = "<leader>op",
    show_diff = "<leader>od",
    abort = "<leader>ox",
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
