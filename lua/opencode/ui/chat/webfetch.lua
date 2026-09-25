-- Compact request summaries with readable, opt-in response bodies.
local M = {}

local render = require("opencode.ui.chat.render")
local tool_panel = require("opencode.ui.chat.tool_panel")
local text_util = require("opencode.util.text")
local syntax = require("opencode.ui.syntax")
local locale = require("opencode.util.locale")

local panel = tool_panel.create_panel({
	border_hl = "OpenCodeWebFetchMuted",
	default_hl = "OpenCodeWebFetchOutput",
})

require("opencode.ui.highlights").register("opencode.ui.chat.webfetch", function()
	for name, source in pairs({
		OpenCodeWebFetchHeader = "Comment",
		OpenCodeWebFetchUrl = "Directory",
		OpenCodeWebFetchStatus = "DiagnosticInfo",
		OpenCodeWebFetchError = "DiagnosticError",
	}) do
		local hl = panel.get_hl(source)
		vim.api.nvim_set_hl(0, name, { fg = hl.fg, bold = false, italic = false })
	end
	panel.set_hl("OpenCodeWebFetchMuted", "Comment", "Normal", { italic = false })
	panel.set_hl("OpenCodeWebFetchOutput", "Normal", nil, { italic = false })
	panel.set_hl("OpenCodeWebFetchBodyError", "DiagnosticError", "Normal", { italic = false })
end)

local function stringify(value)
	if text_util.is_nil(value) then return "" end
	if type(value) == "string" then return value end
	if type(value) == "table" then
		return text_util.first_string(value.message, value.output, value.content) or vim.inspect(value)
	end
	return tostring(value)
end

local function text(value)
	return text_util.normalize_text(value, stringify)
end

local function single_line(value)
	return vim.trim(text(value):gsub("%s+", " "))
end

-- Use display cells, retaining complete UTF-8 characters in narrow windows.
local function shorten(value, width)
	if vim.fn.strdisplaywidth(value) <= width then return value end
	local low, high = 0, vim.fn.strchars(value)
	while low < high do
		local middle = math.ceil((low + high) / 2)
		if vim.fn.strdisplaywidth(vim.fn.strcharpart(value, 0, middle)) <= width - 1 then
			low = middle
		else
			high = middle - 1
		end
	end
	return vim.fn.strcharpart(value, 0, low) .. "…"
end

local function status_label(ctx, error_body)
	if ctx.status == "error" or error_body ~= "" then
		-- Both Effect's native StatusCode error and older webfetch errors.
		local code = error_body:match("non 2xx status code %((%d%d%d)%s")
			or error_body:match("[Ss]tatus code:?%s*(%d%d%d)")
			or error_body:match("HTTP%s+(%d%d%d)")
		return code and ("HTTP " .. code) or "Failed", "OpenCodeWebFetchError"
	end
	if ctx.status == "running" then return "Fetching", "OpenCodeWebFetchStatus" end
	if ctx.status == "pending" or ctx.status == "streaming" then return "Pending", "OpenCodeWebFetchStatus" end
	if ctx.status == "completed" then return "Fetched", "OpenCodeWebFetchHeader" end
	return "Cancelled", "OpenCodeWebFetchHeader"
end

local function duration(state)
	local time = type(state.time) == "table" and state.time or {}
	local start = tonumber(time.created or time.start)
	local finish = tonumber(time.completed or time["end"])
	if start and finish and finish >= start then return locale.duration(finish - start) end
end

local function add_raw_body(result, body, hl, language)
	local lines, rows = {}, {}
	for _, line in ipairs(vim.split(body, "\n", { plain = true })) do
		line = render.expand_tabs(line, vim.fn.strdisplaywidth(tool_panel.PANEL_PREFIX))
		lines[#lines + 1] = line
		local _, _, mapped = panel.add_raw_line(result, line, hl)
		rows[#rows + 1] = mapped
	end
	if language then
		vim.list_extend(result.highlights, syntax.project_highlights(
			syntax.highlight_text(table.concat(lines, "\n"), language, { scope = "tools" }), lines, rows
		))
	end
end

local function add_markdown_body(result, body)
	local rendered = render.render_content(body, {
		width = math.max(1, render.get_chat_text_width() - vim.fn.strdisplaywidth(tool_panel.PANEL_PREFIX)),
		scope = "tools",
	})
	local lines, rows = {}, {}
	for _, line in ipairs(rendered) do
		local content = line:content()
		lines[#lines + 1] = content
		local _, _, mapped = panel.add_raw_line(result, content)
		rows[#rows + 1] = mapped
	end
	vim.list_extend(result.highlights, syntax.project_highlights(rendered._opencode_highlights, lines, rows))
end

function M.render_tool(part, expanded)
	if type(part) ~= "table" or part.tool ~= "webfetch" then return nil end
	local ctx = tool_panel.context(part)
	ctx.working = ctx.working or ctx.status == "streaming"
	local input = type(ctx.input) == "table" and ctx.input or {}
	local url = single_line(input.url)
	if url == "" then url = "Waiting for URL" end
	local format = type(input.format) == "string" and input.format or "markdown"
	local error_body = text_util.trim_edge_newlines(text(ctx.error))
	local label, status_hl = status_label(ctx, error_body)
	local prefix = tool_panel.fold_prefix(expanded) .. "WebFetch "
	local suffix = " · " .. label
	local elapsed = not ctx.working and duration(ctx.state) or nil
	if elapsed then suffix = suffix .. " · " .. elapsed end
	if ctx.working then suffix = suffix .. " " .. tool_panel.anim_frame() end
	local available = render.get_chat_text_width() - 1
	local compact_url = url:gsub("^https?://", "")
	if vim.fn.strdisplaywidth(prefix .. compact_url .. suffix) > available and elapsed then
		suffix = " · " .. label
	end
	local display_url = shorten(compact_url, math.max(8, available - vim.fn.strdisplaywidth(prefix .. suffix)))
	local result = panel.result()
	local _, _, header_rows = render.add_panel_line(result, prefix .. display_url .. suffix,
		"OpenCodeWebFetchHeader", { prefix = " " })
	panel.highlight_text(result, header_rows, display_url, "OpenCodeWebFetchUrl")
	panel.highlight_text(result, header_rows, label, status_hl)
	if not expanded then return result end

	-- Keep the full request address available even when the summary is shortened.
	panel.add_line(result, url, "OpenCodeWebFetchOutput")
	local details = "Format: " .. format
	local timeout = tonumber(input.timeout)
	if timeout then details = details .. " · Timeout: " .. tostring(timeout) .. "s" end
	panel.add_line(result, details, "OpenCodeWebFetchMuted")
	panel.add_blank(result)

	local body = text_util.trim_edge_newlines(text(ctx.output))
	if body ~= "" then
		if format == "markdown" then
			add_markdown_body(result, body)
		else
			add_raw_body(result, body, "OpenCodeWebFetchOutput", format == "html" and "html" or nil)
		end
	end
	if error_body ~= "" then
		if body ~= "" then panel.add_blank(result) end
		add_raw_body(result, error_body, "OpenCodeWebFetchBodyError")
	elseif body == "" then
		local body_hl = status_hl == "OpenCodeWebFetchError" and "OpenCodeWebFetchBodyError" or "OpenCodeWebFetchMuted"
		panel.add_line(result, ctx.status == "completed" and "Empty response" or label, body_hl)
	end
	panel.add_separator(result)
	return result
end

return M
