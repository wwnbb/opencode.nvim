-- Best-effort Treesitter syntax helpers for chat-rendered code snippets.

local M = {}

local DEFAULT_CONFIG = {
	enabled = true,
	max_lines = 500,
	max_bytes = 200 * 1024,
	assistant_markdown = true,
	tools = true,
	diffs = true,
	languages = {},
}

local DEFAULT_EXTMARK_PRIORITY = 4100
local syntax_hl_cache = {}

local LANGUAGE_ALIASES = {
	csharp = "c_sharp",
	["c#"] = "c_sharp",
	["c++"] = "cpp",
	dockerfile = "dockerfile",
	js = "javascript",
	jsx = "javascriptreact",
	md = "markdown",
	py = "python",
	sh = "bash",
	ts = "typescript",
	tsx = "typescriptreact",
	vim = "vim",
	yml = "yaml",
	zsh = "bash",
}

---@param value table
---@return boolean
local function has_any_key(value)
	return type(value) == "table" and next(value) ~= nil
end

---@param name string
---@return string
local function encode_hl_name(name)
	return (name:gsub("[^%w_]", function(ch)
		return string.format("_%02X", ch:byte())
	end))
end

local function clear_syntax_hl_cache()
	for key in pairs(syntax_hl_cache) do
		syntax_hl_cache[key] = nil
	end
end

vim.api.nvim_create_autocmd("ColorScheme", {
	group = vim.api.nvim_create_augroup("OpenCodeSyntaxHighlights", { clear = true }),
	callback = clear_syntax_hl_cache,
	desc = "Refresh OpenCode syntax highlight wrappers",
})

---@param opts table
---@return boolean
local function has_background_attrs(opts)
	return opts.bg ~= nil
		or opts.ctermbg ~= nil
		or opts.blend ~= nil
		or opts.reverse == true
		or opts.standout == true
		or opts.nocombine == true
end

---@param opts table
---@return table
local function strip_background_attrs(opts)
	local clean = {}
	for key, value in pairs(opts) do
		if
			key ~= "bg"
			and key ~= "ctermbg"
			and key ~= "blend"
			and key ~= "reverse"
			and key ~= "standout"
			and key ~= "nocombine"
			and key ~= "link"
		then
			if key == "cterm" and type(value) == "table" then
				local cterm = vim.tbl_extend("force", {}, value)
				cterm.bg = nil
				cterm.reverse = nil
				cterm.standout = nil
				if has_any_key(cterm) then
					clean.cterm = cterm
				end
			else
				clean[key] = value
			end
		end
	end
	return clean
end

---@param hl_group string
---@return string|nil
local function syntax_hl_group(hl_group)
	if type(hl_group) ~= "string" or hl_group == "" then
		return nil
	end

	if syntax_hl_cache[hl_group] ~= nil then
		return syntax_hl_cache[hl_group] or nil
	end

	local ok, opts = pcall(vim.api.nvim_get_hl, 0, { name = hl_group, link = false })
	if not ok or type(opts) ~= "table" or not has_background_attrs(opts) then
		syntax_hl_cache[hl_group] = hl_group
		return hl_group
	end

	local clean = strip_background_attrs(opts)
	if not has_any_key(clean) then
		syntax_hl_cache[hl_group] = false
		return nil
	end

	local wrapped = "OpenCodeSyntax_" .. encode_hl_name(hl_group)
	vim.api.nvim_set_hl(0, wrapped, clean)
	syntax_hl_cache[hl_group] = wrapped
	return wrapped
end

---@return table
local function get_full_config()
	local ok, app_state = pcall(require, "opencode.state")
	if not ok or type(app_state.get_config) ~= "function" then
		return {}
	end
	return app_state.get_config() or {}
end

---@return table
function M.get_config()
	local full_config = get_full_config()
	return vim.tbl_deep_extend("force", DEFAULT_CONFIG, full_config.syntax or {})
end

---@param scope "assistant_markdown"|"tools"|"diffs"|nil
---@return boolean
function M.is_enabled(scope)
	local cfg = M.get_config()
	if cfg.enabled == false then
		return false
	end
	if scope and cfg[scope] == false then
		return false
	end
	return true
end

---@param text string
---@return string
local function trim(text)
	return vim.trim(text or "")
end

---@param lines string[]
---@param first number
---@param last number
---@return string
local function join_range(lines, first, last)
	local out = {}
	for i = first, last do
		table.insert(out, lines[i] or "")
	end
	return table.concat(out, "\n")
end

---@param text string
---@return string[]
local function split_lines(text)
	return vim.split(text or "", "\n", { plain = true })
end

---@param value any
---@return string|nil
local function first_string(value)
	if type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

---@param language string|nil
---@return string|nil
function M.normalize_language(language)
	if type(language) ~= "string" or language == "" then
		return nil
	end

	local cfg = M.get_config()
	local raw = trim(language):lower()
	raw = raw:gsub("^language%-", "")
	raw = raw:gsub("[^%w_#+%-%.]", "")
	if raw == "" or raw == "text" or raw == "txt" or raw == "plain" or raw == "plaintext" then
		return nil
	end

	local configured = type(cfg.languages) == "table" and cfg.languages[raw] or nil
	if type(configured) == "string" and configured ~= "" then
		raw = configured
	end

	local aliased = LANGUAGE_ALIASES[raw] or raw
	if vim.treesitter and vim.treesitter.language and type(vim.treesitter.language.get_lang) == "function" then
		local ok, mapped = pcall(vim.treesitter.language.get_lang, aliased)
		if ok and type(mapped) == "string" and mapped ~= "" then
			aliased = mapped
		end
	end

	return aliased
end

---@param filetype string|nil
---@return string|nil
function M.language_for_filetype(filetype)
	if type(filetype) ~= "string" or filetype == "" then
		return nil
	end
	return M.normalize_language(filetype)
end

---@param path string|nil
---@return string|nil
function M.language_for_path(path)
	if type(path) ~= "string" or path == "" then
		return nil
	end

	local filetype
	if vim.filetype and type(vim.filetype.match) == "function" then
		local ok, matched = pcall(vim.filetype.match, { filename = path })
		if ok then
			filetype = matched
		end
	end
	filetype = filetype or vim.fn.fnamemodify(path, ":e")
	return M.language_for_filetype(filetype)
end

---@param lang string
---@return boolean
local function has_parser(lang)
	if not vim.treesitter or not vim.treesitter.language or not vim.treesitter.language.add then
		return false
	end
	local ok = pcall(vim.treesitter.language.add, lang)
	return ok
end

---@param lang string
---@return table|nil
local function get_query(lang)
	if not vim.treesitter or not vim.treesitter.query or not vim.treesitter.query.get then
		return nil
	end
	local ok, query = pcall(function()
		return vim.treesitter.query.get(lang, "highlights")
	end)
	if not ok then
		return nil
	end
	return query
end

---@param text string
---@param opts table|nil
---@return boolean
local function within_limits(text, opts)
	opts = opts or {}
	local cfg = M.get_config()
	local max_bytes = opts.max_bytes or cfg.max_bytes or DEFAULT_CONFIG.max_bytes
	local max_lines = opts.max_lines or cfg.max_lines or DEFAULT_CONFIG.max_lines
	if max_bytes and max_bytes > 0 and #text > max_bytes then
		return false
	end
	if max_lines and max_lines > 0 and #split_lines(text) > max_lines then
		return false
	end
	return true
end

---@param metadata table|nil
---@param capture number
---@return number
local function capture_priority(metadata, capture)
	local meta = metadata or {}
	local raw_priority = tonumber(meta.priority or (meta[capture] and meta[capture].priority))
	if not raw_priority then
		return DEFAULT_EXTMARK_PRIORITY
	end

	local ts_priority = vim.hl and vim.hl.priorities and vim.hl.priorities.treesitter or 100
	return DEFAULT_EXTMARK_PRIORITY + (raw_priority - ts_priority)
end

---@param text string
---@param language string|nil
---@param opts? table
---@return table[] highlights
function M.highlight_text(text, language, opts)
	opts = opts or {}
	text = type(text) == "string" and text or tostring(text or "")
	if text == "" or not M.is_enabled(opts.scope or "tools") or not within_limits(text, opts) then
		return {}
	end

	local lang = M.normalize_language(language)
	if not lang or not has_parser(lang) then
		return {}
	end

	local query = get_query(lang)
	if not query then
		return {}
	end

	local ok_parser, parser = pcall(vim.treesitter.get_string_parser, text, lang)
	if not ok_parser or not parser then
		return {}
	end

	local ok_parse, trees = pcall(function()
		return parser:parse()
	end)
	if not ok_parse or type(trees) ~= "table" then
		return {}
	end

	local highlights = {}
	local line_count = #split_lines(text)
	for _, tree in pairs(trees) do
		local root = tree and tree:root()
		if root then
			local ok_loop = pcall(function()
				for capture, node, metadata in query:iter_captures(root, text, 0, line_count) do
					local capture_name = query.captures[capture]
					if type(capture_name) == "string" and capture_name:sub(1, 1) ~= "_" then
						local hl_group = syntax_hl_group("@" .. capture_name .. "." .. lang)
						local range_ok, range = pcall(vim.treesitter.get_range, node, text, metadata and metadata[capture])
						local row_start, col_start, row_end, col_end
						if range_ok and type(range) == "table" then
							if #range >= 6 then
								row_start, col_start, row_end, col_end = range[1], range[2], range[4], range[5]
							else
								row_start, col_start, row_end, col_end = range[1], range[2], range[3], range[4]
							end
						else
							row_start, col_start, row_end, col_end = node:range()
						end
						if
							type(row_start) == "number"
							and type(col_start) == "number"
							and type(row_end) == "number"
							and type(col_end) == "number"
							and (row_start ~= row_end or col_start ~= col_end)
							and hl_group
						then
							table.insert(highlights, {
								line = row_start,
								col_start = col_start,
								end_line = row_end,
								end_col = col_end,
								hl_group = hl_group,
								priority = capture_priority(metadata, capture),
							})
						end
					end
				end
			end)
			if not ok_loop then
				return {}
			end
		end
	end

	return highlights
end

---@param result table
---@param text string
---@param language string|nil
---@param opts? table
---@return table[] highlights
function M.add_highlights(result, text, language, opts)
	opts = opts or {}
	result.highlights = result.highlights or {}

	local highlights = M.highlight_text(text, language, opts)
	local line_start = opts.line_start or 0
	local col_offset = opts.col_offset or 0
	for _, hl in ipairs(highlights) do
		table.insert(result.highlights, {
			line = line_start + hl.line,
			col_start = col_offset + hl.col_start,
			end_line = line_start + (hl.end_line or hl.line),
			end_col = col_offset + (hl.end_col or hl.col_end or hl.col_start),
			hl_group = hl.hl_group,
			priority = hl.priority,
		})
	end
	return highlights
end

---@param fence string
---@return string
local function close_pattern(fence)
	local marker = fence:sub(1, 1)
	local escaped = marker == "`" and "`" or "~"
	return "^%s*" .. escaped .. escaped .. escaped .. "+%s*$"
end

---@param info string|nil
---@return string|nil
local function language_from_fence_info(info)
	info = trim(info or "")
	local lang = info:match("^([^%s{]+)")
	return M.normalize_language(lang)
end

---@param text string
---@param opts? table
---@return table[] highlights
function M.highlight_markdown_fenced_blocks(text, opts)
	opts = opts or {}
	text = type(text) == "string" and text or tostring(text or "")
	if text == "" or not M.is_enabled(opts.scope or "assistant_markdown") then
		return {}
	end
	if opts.compat_markdown ~= false then
		local full_config = get_full_config()
		if full_config.markdown and full_config.markdown.enable_code_highlight == false then
			return {}
		end
	end

	local lines = split_lines(text)
	local highlights = {}
	local i = 1
	while i <= #lines do
		local fence, info = lines[i]:match("^%s*(```+)%s*(.-)%s*$")
		if not fence then
			fence, info = lines[i]:match("^%s*(~~~+)%s*(.-)%s*$")
		end
		if not fence then
			i = i + 1
		else
			local lang = language_from_fence_info(info)
			local code_start = i + 1
			i = i + 1
			while i <= #lines and not lines[i]:match(close_pattern(fence)) do
				i = i + 1
			end
				local code_end = i - 1
				if lang and code_end >= code_start then
					local code = join_range(lines, code_start, code_end)
					local highlight_opts = vim.tbl_extend("force", opts, {
						scope = opts.scope or "assistant_markdown",
					})
					for _, hl in ipairs(M.highlight_text(code, lang, highlight_opts)) do
					table.insert(highlights, {
						line = code_start - 1 + hl.line,
						col_start = hl.col_start,
						end_line = code_start - 1 + (hl.end_line or hl.line),
						end_col = hl.end_col or hl.col_end or hl.col_start,
						hl_group = hl.hl_group,
						priority = hl.priority,
					})
				end
			end
			i = i + 1
		end
	end

	return highlights
end

---@param result table
---@param text string
---@param opts? table
---@return table[] highlights
function M.add_markdown_highlights(result, text, opts)
	opts = opts or {}
	result.highlights = result.highlights or {}

	local highlights = M.highlight_markdown_fenced_blocks(text, opts)
	local line_start = opts.line_start or 0
	local col_offset = opts.col_offset or 0
	for _, hl in ipairs(highlights) do
		table.insert(result.highlights, {
			line = line_start + hl.line,
			col_start = col_offset + hl.col_start,
			end_line = line_start + (hl.end_line or hl.line),
			end_col = col_offset + (hl.end_col or hl.col_end or hl.col_start),
			hl_group = hl.hl_group,
			priority = hl.priority,
		})
	end
	return highlights
end

---@param text string
---@return boolean
local function is_json(text)
	local value = trim(text)
	if value == "" or not (value:sub(1, 1) == "{" or value:sub(1, 1) == "[") then
		return false
	end
	local ok = pcall(vim.json.decode, value)
	return ok
end

---@param text string
---@return boolean
local function is_diff(text)
	local value = text or ""
	return value:match("^diff %-%-git") ~= nil
		or value:match("^@@") ~= nil
		or (value:find("\n--- ", 1, true) and value:find("\n+++ ", 1, true)) ~= nil
end

---@param metadata table|nil
---@return string|nil
local function explicit_language(metadata)
	if type(metadata) ~= "table" then
		return nil
	end
	for _, key in ipairs({ "language", "lang", "filetype", "file_type", "outputLanguage", "output_language" }) do
		local lang = first_string(metadata[key])
		if lang then
			return M.normalize_language(lang)
		end
	end
	for _, key in ipairs({ "filePath", "file_path", "filepath", "path" }) do
		local path = first_string(metadata[key])
		local lang = path and M.language_for_path(path) or nil
		if lang then
			return lang
		end
	end
	return nil
end

---@param text string
---@param metadata table|nil
---@return string|nil language
function M.detect_output_language(text, metadata)
	local explicit = explicit_language(metadata)
	if explicit then
		return explicit
	end

	text = type(text) == "string" and text or tostring(text or "")
	if text:match("```") or text:match("~~~") then
		return "markdown"
	end
	if is_json(text) then
		return "json"
	end
	if is_diff(text) then
		return "diff"
	end
	return nil
end

---@param bufnr number
---@param lang_or_path string|nil
---@param opts? table
---@return boolean ok
function M.start_buffer(bufnr, lang_or_path, opts)
	opts = opts or {}
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) or not M.is_enabled(opts.scope or "diffs") then
		return false
	end

	local lang = M.language_for_path(lang_or_path) or M.normalize_language(lang_or_path)
	if not lang then
		local ft = vim.bo[bufnr].filetype
		lang = M.language_for_filetype(ft)
	end
	if not lang or not has_parser(lang) then
		return false
	end

	local ok = pcall(vim.treesitter.start, bufnr, lang)
	return ok
end

return M
