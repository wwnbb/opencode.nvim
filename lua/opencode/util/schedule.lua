local M = {}

local unpack_fn = table.unpack or unpack

---@param label string
---@param fn function|nil
function M.schedule_pcall(label, fn, ...)
	if type(fn) ~= "function" then
		return
	end

	local argc = select("#", ...)
	local args = { ... }
	vim.schedule(function()
		local ok, err = pcall(fn, unpack_fn(args, 1, argc))
		if not ok then
			local name = (type(label) == "string" and label ~= "") and label or "scheduled callback"
			vim.notify("OpenCode " .. name .. " failed: " .. tostring(err), vim.log.levels.ERROR)
		end
	end)
end

---@param callback function|nil
function M.schedule_callback(callback, ...)
	M.schedule_pcall("scheduled callback", callback, ...)
end

return M
