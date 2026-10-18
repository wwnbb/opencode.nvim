local M = {}
local text = require("opencode.util.text")

function M.title(value, width)
	return text.truncate(tostring(value or ""):gsub("[%c]", " "), width or 18, "...", vim.fn.strwidth)
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

return M
