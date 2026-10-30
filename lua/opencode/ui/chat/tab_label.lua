local M = {}
local text = require("opencode.util.text")

function M.title(value, width)
	return text.truncate(tostring(value or ""):gsub("[%c]", " "), width or 18, "…", vim.fn.strwidth)
end

local statuses = {
	{ "Waiting", "is_waiting", "waiting", "◈" },
	{ "Running", "is_busy", "running", "●" },
	{ "Error", "is_error", "error", "✕" },
	{ "Unread", "is_unread", "unread", "◆" },
	{ "Idle", "is_idle", "idle", "○" },
}

function M.status(sessions)
	for index = 1, #statuses - 1 do
		local rule = statuses[index]
		for _, session in ipairs(sessions) do
			if session[rule[2]](session) then return rule[1] end
		end
	end
	return "Idle"
end

function M.icon(status, icons)
	icons = icons or {}
	for _, rule in ipairs(statuses) do
		if rule[1] == status then
			return icons[rule[3]] or rule[4], status == "Unread" and "Waiting" or status
		end
	end
end

-- Tab fitting shared by the session tabs and the layout tabline. Callers keep
-- their own labels, overflow markers and output format.

---Most tabs to try: every tab for auto_fit or max_tabs = "auto" (any case),
---otherwise max_tabs (default 3), never more than `count`.
function M.max_tabs(config, count)
	config = type(config) == "table" and config or {}
	local max_tabs = config.max_tabs
	if config.auto_fit == true or (type(max_tabs) == "string" and max_tabs:lower() == "auto") then return count end
	return math.min(count, math.max(1, math.floor(tonumber(max_tabs) or 3)))
end

---First index of a `visible`-wide window centered on `current` (1 when unknown).
function M.window_start(count, visible, current)
	if count <= visible or not current then return 1 end
	return math.max(1, math.min(current - math.floor(visible / 2), count - visible + 1))
end

---Display widths of labels joined by `separator`. `contextual` is set when a
---label's width depends on its neighbours (control or combining characters);
---callers then measure the joined text instead of summing.
---@return { sizes: integer[], prefix: integer[], separator_width: integer, contextual?: boolean }
function M.widths(texts, separator, measure)
	local result = { sizes = {}, prefix = { 0 }, separator_width = measure(separator) }
	for index, label in ipairs(texts) do
		local size = measure(label)
		if label:find("[%c]") or measure(separator .. label) ~= result.separator_width + size
			or measure(label .. separator) ~= size + result.separator_width then
			result.contextual = true
		end
		result.sizes[index], result.prefix[index + 1] = size, result.prefix[index] + size
	end
	return result
end

---Largest tab count from `maximum` down to 1 whose row fits in `width`.
---@param start fun(visible: integer): integer First index for a candidate count
---@param measure fun(first: integer, last: integer, visible: integer): integer Row width
---@return integer visible
---@return integer first
---@return integer last
---@return boolean fits False when even one tab overflows (compact rendering)
function M.fit(count, maximum, width, start, measure)
	for visible = maximum, 1, -1 do
		local first = start(visible)
		local last = math.min(count, first + visible - 1)
		if measure(first, last, visible) <= width then return visible, first, last, true end
	end
	local first = start(1)
	return 1, first, math.min(count, first), false
end

return M
