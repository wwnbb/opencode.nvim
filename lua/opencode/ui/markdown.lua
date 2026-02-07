-- opencode.nvim - Markdown rendering module
-- Render markdown in chat messages with syntax highlighting

local M = {}

-- Treesitter highlight support
local has_treesitter = vim.treesitter ~= nil and vim.treesitter.language ~= nil
local has_highlighter = pcall(require, "vim.treesitter.highlighter")

-- State
local state = {
	highlight_cache = {},
}

-- Default configuration
local defaults = {
	enable_code_highlight = true,
	code_languages = {
		lua = "lua",
		python = "python",
		javascript = "javascript",
		typescript = "typescript",
		javascriptreact = "javascript",
		typescriptreact = "typescript",
		html = "html",
		css = "css",
		scss = "scss",
		json = "json",
		yaml = "yaml",
		toml = "toml",
		vim = "vim",
		sh = "bash",
		bash = "bash",
		zsh = "bash",
		fish = "fish",
		go = "go",
		rust = "rust",
		cpp = "cpp",
		c = "c",
		java = "java",
		kotlin = "kotlin",
		swift = "swift",
		php = "php",
		ruby = "ruby",
		perl = "perl",
		r = "r",
		julia = "julia",
		matlab = "matlab",
		sql = "sql",
		graphql = "graphql",
		regex = "regex",
		dockerfile = "dockerfile",
		makefile = "make",
		cmake = "cmake",
		["c++"] = "cpp",
		["c#"] = "c_sharp",
		csharp = "c_sharp",
		markdown = "markdown",
		md = "markdown",
	},
	max_code_lines = 50,
	enable_inline_code = true,
}

-- Parse markdown text into segments
-- Each segment has: type, content, language (for code blocks)
function M.parse(text)
	local segments = {}
	local lines = vim.split(text, "\n", { plain = true })
	local i = 1

	while i <= #lines do
		local line = lines[i]

		-- Code block: ```language
		if line:match("^```") then
			local lang = line:match("^```(%w+)$") or ""
			lang = lang:lower()
			i = i + 1

			local code_lines = {}
			while i <= #lines and not lines[i]:match("^```$") do
				table.insert(code_lines, lines[i])
				i = i + 1
			end
			-- Skip closing ```
			i = i + 1

			table.insert(segments, {
				type = "code_block",
				content = table.concat(code_lines, "\n"),
				language = lang,
			})
		-- Inline code: `code`
		elseif defaults.enable_inline_code and line:match("`[^`]+`") then
			local parts = {}
			local last_end = 1

			for before, code, after in line:gmatch("(.-)`([^`]+)`(.*)") do
				if before ~= "" then
					table.insert(parts, { type = "text", content = before })
				end
				table.insert(parts, { type = "inline_code", content = code })
				last_end = #before + #code + #after + 3 -- 3 for backticks
			end

			-- Add remaining text
			if last_end < #line then
				table.insert(parts, { type = "text", content = line:sub(last_end) })
			end

			for _, part in ipairs(parts) do
				table.insert(segments, part)
			end
			i = i + 1
		-- Headers: # Header
		elseif line:match("^#+%s") then
			local level, content = line:match("^(#+)%s+(.+)$")
			table.insert(segments, {
				type = "header",
				level = #level,
				content = content,
			})
			i = i + 1
		-- Lists: - item or * item or 1. item
		elseif line:match("^%s*[-*]%s+") or line:match("^%s*%d+%.%s+") then
			table.insert(segments, {
				type = "list_item",
				content = line,
			})
			i = i + 1
		-- Blockquote: > quote
		elseif line:match("^>%s?") then
			local content = line:match("^>%s?(.*)$") or ""
			table.insert(segments, {
				type = "blockquote",
				content = content,
			})
			i = i + 1
		-- Regular text
		else
			table.insert(segments, {
				type = "text",
				content = line,
			})
			i = i + 1
		end
	end

	return segments
end

-- Get syntax highlighting for code
function M.highlight_code(code, language)
	if not defaults.enable_code_highlight then
		return nil
	end

	-- Map language name
	local lang = defaults.code_languages[language] or language
	if not lang or lang == "" then
		lang = "text"
	end

	-- Check if parser is available
	if has_treesitter then
		-- Check if parser is available using modern API
		local ok = pcall(vim.treesitter.language.add, lang)
		if ok then
			-- Return language for later highlighting
			return { type = "treesitter", language = lang }
		end
	end

	-- Fall back to vim syntax
	return { type = "syntax", language = lang }
end

-- Render segments to display lines with extmarks
function M.render_to_lines(segments, opts)
	opts = opts or {}
	local lines = {}
	local highlights = {}

	for _, segment in ipairs(segments) do
		if segment.type == "text" then
			table.insert(lines, segment.content)
		elseif segment.type == "header" then
			local prefix = string.rep("#", segment.level) .. " "
			table.insert(lines, prefix .. segment.content)
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = #prefix + #segment.content,
				hl_group = "Title",
			})
		elseif segment.type == "code_block" then
			table.insert(lines, "")
			table.insert(lines, "┌" .. string.rep("─", 58) .. "┐")

			-- Language label
			if segment.language and segment.language ~= "" then
				local label = " " .. segment.language .. " "
				table.insert(lines, "│" .. label .. string.rep(" ", 58 - #label) .. "│")
				table.insert(highlights, {
					line = #lines - 1,
					col_start = 1,
					col_end = 1 + #label,
					hl_group = "Comment",
				})
			else
				table.insert(lines, "│" .. string.rep(" ", 58) .. "│")
			end

			-- Code content
			local code_lines = vim.split(segment.content, "\n", { plain = true })
			for _, code_line in ipairs(code_lines) do
				-- Truncate if too long
				if #code_line > 58 then
					code_line = code_line:sub(1, 55) .. "..."
				end
				local padded = code_line .. string.rep(" ", 58 - #code_line)
				table.insert(lines, "│" .. padded .. "│")

				-- Store highlight info for code
				local hl = M.highlight_code(code_line, segment.language)
				if hl then
					table.insert(highlights, {
						line = #lines - 1,
						col_start = 1,
						col_end = 1 + #code_line,
						hl_group = hl.type == "treesitter" and "Normal" or ("@" .. hl.language),
						code = true,
						language = segment.language,
					})
				end
			end

			table.insert(lines, "└" .. string.rep("─", 58) .. "┘")
			table.insert(lines, "")
		elseif segment.type == "inline_code" then
			table.insert(lines, "`" .. segment.content .. "`")
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = 2 + #segment.content,
				hl_group = "String",
			})
		elseif segment.type == "list_item" then
			table.insert(lines, segment.content)
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = 2,
				hl_group = "Special",
			})
		elseif segment.type == "blockquote" then
			table.insert(lines, "▌ " .. segment.content)
			table.insert(highlights, {
				line = #lines - 1,
				col_start = 0,
				col_end = 2,
				hl_group = "Comment",
			})
		end
	end

	return lines, highlights
end

-- Apply highlights to buffer
function M.apply_highlights(bufnr, highlights, ns_id)
	ns_id = ns_id or vim.api.nvim_create_namespace("opencode_markdown")

	for _, hl in ipairs(highlights) do
		if hl.code and hl.language and has_highlighter then
			-- Try to apply treesitter highlighting to code block
			pcall(function()
				vim.treesitter.start(bufnr, defaults.code_languages[hl.language] or hl.language)
			end)
		else
			-- Apply regular highlight
			vim.api.nvim_buf_add_highlight(bufnr, ns_id, hl.hl_group, hl.line, hl.col_start, hl.col_end)
		end
	end

	return ns_id
end

-- Full render function: parse and render
function M.render(text, bufnr, opts)
	opts = opts or {}

	local segments = M.parse(text)
	local lines, highlights = M.render_to_lines(segments, opts)

	-- Set lines in buffer
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
		vim.bo[bufnr].modifiable = true
		local line_count = vim.api.nvim_buf_line_count(bufnr)
		vim.api.nvim_buf_set_lines(bufnr, line_count, line_count, false, lines)

		-- Apply highlights
		M.apply_highlights(bufnr, highlights, opts.ns_id)

		vim.bo[bufnr].modifiable = false
	end

	return lines, highlights
end

-- Check if text contains markdown
function M.has_markdown(text)
	if not text or text == "" then
		return false
	end
	return text:match("```") or
		text:match("#%s") or
		text:match("`[^`]+`") or
		text:match("^%s*[-*]%s+") or
		text:match("^>")
end

-- Setup function
function M.setup(opts)
	if opts then
		if opts.code_languages then
			defaults.code_languages = vim.tbl_extend("force", defaults.code_languages, opts.code_languages)
		end
		if opts.enable_code_highlight ~= nil then
			defaults.enable_code_highlight = opts.enable_code_highlight
		end
		if opts.max_code_lines then
			defaults.max_code_lines = opts.max_code_lines
		end
		if opts.enable_inline_code ~= nil then
			defaults.enable_inline_code = opts.enable_inline_code
		end
	end
end

return M
