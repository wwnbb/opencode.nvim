-- Web requests share the exploration list's compact rows and framed output.
local M = { animation_line = 0 }

local render = require("opencode.ui.chat.render")
local tool_panel = require("opencode.ui.chat.tool_panel")
local text_util = require("opencode.util.text")
local locale = require("opencode.util.locale")
local tool_group = require("opencode.ui.chat.tool_group")
local style = require("opencode.ui.chat.tool_style")
local panel = style.panel

local definitions = {
	webfetch = { name = "WebFetch", active = "Fetching", completed = "Fetched", target = "url", waiting = "Waiting for URL" },
	websearch = { name = "WebSearch", active = "Searching", completed = "Searched", target = "query", waiting = "Waiting for query" },
}

local function stringify(value)
	if text_util.is_nil(value) then return "" end
	if type(value) == "string" then return value end
	if type(value) == "table" then
		return text_util.first_string(value.message, value.output, value.content, value.text) or vim.inspect(value)
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
	if width <= 0 then return "" end
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

local function status_label(ctx, definition, failed, error_body)
	if failed then
		-- Both Effect's native StatusCode error and older webfetch errors.
		local code = error_body:match("non 2xx status code %((%d%d%d)%s")
			or error_body:match("[Ss]tatus code:?%s*(%d%d%d)")
			or error_body:match("HTTP%s+(%d%d%d)")
		if code then return "HTTP " .. code end
		if ctx.status == "cancelled" or ctx.status == "canceled" or ctx.status == "interrupted" or ctx.status == "aborted" then
			return "Cancelled"
		end
		return "Failed"
	end
	if ctx.working then return ctx.status == "pending" and "Pending" or definition.active end
	return definition.completed
end

local function duration(state)
	local time = type(state.time) == "table" and state.time or {}
	local start = tonumber(time.created or time.start)
	local finish = tonumber(time.completed or time["end"])
	if start and finish and finish >= start then return locale.duration(finish - start) end
end

local function add_header(result, definition, target, label, ctx, expanded, grouped, failed)
	local prefix = (expanded and "↘ " or "→ ") .. definition.name .. " "
	local suffix = " · " .. label
	local elapsed = not ctx.working and duration(ctx.state) or nil
	if elapsed then suffix = suffix .. " · " .. elapsed end
	local spinner = ctx.working and not grouped and (" " .. tool_panel.anim_frame()) or ""
	local width = math.max(1, render.get_chat_text_width() - 1)
	local compact = definition.target == "url" and target:gsub("^https?://", "") or ('"' .. target .. '"')
	if vim.fn.strdisplaywidth(prefix .. compact .. suffix .. spinner) > width then
		suffix = " · " .. label
	end
	if vim.fn.strdisplaywidth(prefix .. suffix .. spinner) >= width then suffix = "" end
	local available = width - vim.fn.strdisplaywidth(prefix .. suffix .. spinner)
	local header = available > 0 and (prefix .. shorten(compact, available) .. suffix)
		or shorten(prefix .. compact, width - vim.fn.strdisplaywidth(spinner))
	render.add_panel_line(result, header .. spinner, failed and style.error_hl or style.header_hl, { prefix = " " })
end

local function add_request(result, part, target, input, format)
	-- The full query or URL remains accessible even when the summary is clipped.
	panel.add_line(result, target)
	local details = {}
	if part.tool == "webfetch" then
		details[#details + 1] = "Format: " .. format
		local timeout = tonumber(input.timeout)
		if timeout then details[#details + 1] = "Timeout: " .. tostring(timeout) .. "s" end
	else
		for _, field in ipairs({
			{ "type", "Search" }, { "numResults", "Results" }, { "livecrawl", "Live crawl" },
			{ "contextMaxCharacters", "Context characters" },
		}) do
			local value = single_line(input[field[1]])
			if value ~= "" then details[#details + 1] = field[2] .. ": " .. value end
		end
	end
	if #details > 0 then panel.add_line(result, table.concat(details, " · "), style.border_hl) end
	panel.add_blank(result)
end

function M.render(part, expanded, opts)
	local definition = type(part) == "table" and definitions[part.tool] or nil
	if not definition then return nil end
	local ctx = tool_panel.context(part)
	ctx.working = tool_group.is_working(part)
	local input = type(ctx.input) == "table" and ctx.input or {}
	local target = single_line(input[definition.target])
	if target == "" then target = definition.waiting end
	local format = part.tool == "webfetch" and type(input.format) == "string" and input.format or "markdown"
	local error_body = ctx.error ~= false and text_util.trim_edge_newlines(text(ctx.error)) or ""
	local failed = tool_group.failed(part)
	local label = status_label(ctx, definition, failed, error_body)
	local result = panel.result()
	add_header(result, definition, target, label, ctx, expanded, (opts or {}).grouped, failed)
	if not expanded then return result end

	style.add_border(result)
	add_request(result, part, target, input, format)
	local body = text_util.trim_edge_newlines(text(ctx.output))
	if body ~= "" then
		if format == "markdown" then
			tool_panel.add_markdown_body(result, body, { panel = panel, prefix = style.prefix })
		else
			tool_panel.add_raw_body(result, body, { panel = panel, prefix = style.prefix,
				hl_group = style.output_hl, language = format == "html" and "html" or nil })
		end
	end
	if error_body ~= "" then
		if body ~= "" then panel.add_blank(result) end
		tool_panel.add_raw_body(result, error_body, { panel = panel, prefix = style.prefix, hl_group = style.body_error_hl })
	elseif body == "" then
		panel.add_line(result, not ctx.working and not failed and "Empty response" or label,
			failed and style.body_error_hl or style.border_hl)
	end
	style.add_border(result, true)
	style.contain_background(result)
	return result
end

return M
