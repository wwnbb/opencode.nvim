-- Link dispatch for external form steps. A successful dispatch prepares the
-- acknowledgement; it never records completion on the user's behalf.
local M = {}

local function key(scope, action)
	scope = scope or "chat"
	local values = scope == "chat" and (require("opencode.ui.chat.state").state.config or {}).keymaps or nil
	return require("opencode.util.keymap").label(scope, action, values)
end

function M.open(url, scope)
	local ok, _, err = pcall(vim.ui.open, url)
	if ok and err == nil then return true end
	vim.notify("Could not open the link. Press " .. key(scope, scope == "form" and "custom" or "custom_input")
		.. " to copy its URL and continue manually.", vim.log.levels.WARN)
	return false
end

function M.copy(url, scope)
	for _, target in ipairs({ { "+", "system clipboard" }, { '"', "Vim register" } }) do
		local register, destination = target[1], target[2]
		local ok = pcall(vim.fn.setreg, register, url)
		local read_ok, copied = pcall(vim.fn.getreg, register)
		if ok and read_ok and copied == url then
			vim.notify("External link copied to " .. destination .. ". Complete the action, then press "
				.. key(scope, "confirm") .. " to confirm.", vim.log.levels.INFO)
			return true
		end
	end
	vim.notify("Could not copy the link. Open the displayed URL manually.", vim.log.levels.WARN)
	return false
end

return M
