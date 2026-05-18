local M = {}

local opts = {
	enabled = true,
	show_attention = true,
	attention_icon = "◈",
	show_diff_stats = true,
	diff_stats_cache_ms = 2000,
	diff_stats_include_untracked = true,
	diff_stats_max_untracked_file_size = 1024 * 1024,
}

local git_cache = {
	cwd = nil,
	root = nil,
	root_checked_at = 0,
	stats = nil,
	stats_checked_at = 0,
}

local highlights_ready = false
local highlight_group = nil

---@return number
local function now_ms()
	if vim.uv and type(vim.uv.now) == "function" then
		return vim.uv.now()
	end
	if vim.loop and type(vim.loop.now) == "function" then
		return vim.loop.now()
	end
	return os.time() * 1000
end

---@param name string
---@return table
local function get_hl(name)
	local ok, value = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
	return ok and value or {}
end

---@param sources string[]
---@param fallback integer
---@return integer
local function pick_fg(sources, fallback)
	for _, source in ipairs(sources) do
		local hl = get_hl(source)
		if hl.fg then
			return hl.fg
		end
	end
	return fallback
end

local function ensure_highlights()
	vim.api.nvim_set_hl(0, "OpenCodeLualineAttention", {
		fg = pick_fg({ "DiagnosticWarn", "WarningMsg" }, 0xffaa00),
	})
	vim.api.nvim_set_hl(0, "OpenCodeLualineDiffAdd", {
		fg = pick_fg({ "String", "Added", "DiagnosticOk", "DiffAdd" }, 0x00aa00),
	})
	vim.api.nvim_set_hl(0, "OpenCodeLualineDiffDelete", {
		fg = pick_fg({ "DiagnosticError", "Removed", "ErrorMsg", "DiffDelete" }, 0xdd0000),
	})
	highlights_ready = true
end

local function setup_highlight_autocmd()
	if highlight_group then
		pcall(vim.api.nvim_del_augroup_by_id, highlight_group)
	end

	highlight_group = vim.api.nvim_create_augroup("OpenCodeLualine", { clear = true })
	vim.api.nvim_create_autocmd("ColorScheme", {
		group = highlight_group,
		callback = ensure_highlights,
		desc = "Refresh OpenCode lualine highlights",
	})
end

---@param args string[]
---@return string[]|nil
local function systemlist(args)
	local ok, result = pcall(vim.fn.systemlist, args)
	if not ok or vim.v.shell_error ~= 0 then
		return nil
	end
	return result
end

---@param root string
---@param args string[]
---@return string[]|nil
local function git_diff_numstat(root, args)
	local command = {
		"git",
		"-C",
		root,
		"-c",
		"core.fsmonitor=false",
		"-c",
		"core.quotepath=false",
		"diff",
		"--no-ext-diff",
		"--no-renames",
		"--numstat",
	}

	for _, arg in ipairs(args or {}) do
		table.insert(command, arg)
	end
	table.insert(command, "--")

	return systemlist(command)
end

---@param stats table
---@param lines string[]|nil
local function add_numstat(stats, lines)
	if type(lines) ~= "table" then
		return
	end

	for _, line in ipairs(lines) do
		local added, removed = line:match("^([^\t]+)\t([^\t]+)\t")
		if not added then
			added, removed = line:match("^(%S+)%s+(%S+)%s+")
		end

		local add_count = tonumber(added)
		local delete_count = tonumber(removed)
		if add_count or delete_count then
			stats.files = stats.files + 1
			stats.additions = stats.additions + (add_count or 0)
			stats.deletions = stats.deletions + (delete_count or 0)
		end
	end
end

---@param root string
---@param stats table
local function add_untracked_stats(root, stats)
	if opts.diff_stats_include_untracked == false then
		return
	end

	local files = systemlist({
		"git",
		"-C",
		root,
		"-c",
		"core.quotepath=false",
		"ls-files",
		"--others",
		"--exclude-standard",
	})
	if not files then
		return
	end

	local max_size = tonumber(opts.diff_stats_max_untracked_file_size) or 1024 * 1024
	for _, file in ipairs(files) do
		if type(file) == "string" and file ~= "" then
			local path = root .. "/" .. file
			local stat = (vim.uv or vim.loop).fs_stat(path)
			if stat and stat.type == "file" and stat.size <= max_size then
				local ok, lines = pcall(vim.fn.readfile, path)
				if ok and type(lines) == "table" then
					stats.files = stats.files + 1
					stats.additions = stats.additions + #lines
				end
			end
		end
	end
end

---@param cwd string
---@param timestamp number
---@return string|nil
local function git_root(cwd, timestamp)
	local ttl = math.max(0, tonumber(opts.diff_stats_cache_ms) or 2000)
	if git_cache.cwd == cwd and timestamp - git_cache.root_checked_at < ttl then
		return git_cache.root
	end

	git_cache.cwd = cwd
	git_cache.root_checked_at = timestamp
	git_cache.root = nil
	git_cache.stats = nil
	git_cache.stats_checked_at = 0

	if vim.fn.executable("git") ~= 1 then
		return nil
	end

	local lines = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
	if not lines or not lines[1] then
		return nil
	end

	local root = vim.trim(lines[1])
	if root == "" then
		return nil
	end

	git_cache.root = root
	return root
end

---@param root string
---@return table
local function collect_git_diff_stats(root)
	local stats = {
		files = 0,
		additions = 0,
		deletions = 0,
	}

	local lines = git_diff_numstat(root, { "HEAD" })
	if lines then
		add_numstat(stats, lines)
	else
		add_numstat(stats, git_diff_numstat(root, { "--cached" }))
		add_numstat(stats, git_diff_numstat(root, {}))
	end
	add_untracked_stats(root, stats)

	return stats
end

---@return table|nil
local function current_git_diff_stats()
	if opts.show_diff_stats == false then
		return nil
	end

	local timestamp = now_ms()
	local cwd = vim.fn.getcwd()
	local root = git_root(cwd, timestamp)
	if not root then
		return nil
	end

	local ttl = math.max(0, tonumber(opts.diff_stats_cache_ms) or 2000)
	if git_cache.root == root and git_cache.stats and timestamp - git_cache.stats_checked_at < ttl then
		return git_cache.stats
	end

	git_cache.stats = collect_git_diff_stats(root)
	git_cache.stats_checked_at = timestamp
	return git_cache.stats
end

---@param stats table|nil
---@return string|nil
local function diff_stats_component(stats)
	if type(stats) ~= "table" then
		return nil
	end

	local additions = tonumber(stats.additions or stats.total_additions or 0) or 0
	local deletions = tonumber(stats.deletions or stats.total_deletions or 0) or 0
	if additions == 0 and deletions == 0 then
		return nil
	end

	if not highlights_ready then
		ensure_highlights()
	end

	return string.format(
		"%%#OpenCodeLualineDiffAdd#+%d%%#OpenCodeLualineDiffDelete# -%d%%*",
		additions,
		deletions
	)
end

---@param pending table|nil
---@return number
local function pending_total(pending)
	pending = pending or {}
	return (tonumber(pending.permissions or 0) or 0)
		+ (tonumber(pending.questions or 0) or 0)
		+ (tonumber(pending.edits or 0) or 0)
end

---@param summary table
---@return number
local function attention_count(summary)
	local count = 0
	if type(summary.active_sessions) == "table" then
		for _, session in ipairs(summary.active_sessions) do
			if pending_total(session.pending) > 0 then
				count = count + 1
			end
		end
	end
	if count > 0 then
		return count
	end
	return pending_total(summary.session_pending) > 0 and 1 or 0
end

---@param summary table
---@return string|nil
local function attention_component(summary)
	if opts.show_attention == false then
		return nil
	end

	local count = attention_count(summary)
	if count == 0 then
		return nil
	end

	if not highlights_ready then
		ensure_highlights()
	end

	return string.format("%%#OpenCodeLualineAttention#%s%d%%*", opts.attention_icon or "◈", count)
end

---@param config table|nil
function M.setup(config)
	opts = vim.tbl_deep_extend("force", opts, config or {})
	git_cache = {
		cwd = nil,
		root = nil,
		root_checked_at = 0,
		stats = nil,
		stats_checked_at = 0,
	}
	ensure_highlights()
	setup_highlight_autocmd()
end

---@return string
function M.component()
	if opts.enabled == false then
		return ""
	end

	local ok, state = pcall(require, "opencode.state")
	if not ok then
		return ""
	end

	local summary = state.get_status_summary()
	local parts = {}
	local attention = attention_component(summary)
	if attention then
		table.insert(parts, attention)
	end
	local diff_stats = diff_stats_component(current_git_diff_stats())
	if diff_stats then
		table.insert(parts, diff_stats)
	end

	return table.concat(parts, " ")
end

return M
