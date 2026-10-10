local M = {}

-- Run a small race scenario with a FIFO. Flush only after changing its owner.
function M.with(callback)
	local original, queue = vim.schedule, {}
	vim.schedule = function(fn) queue[#queue + 1] = fn end
	local function flush()
		local count, index = 0, 1
		while index <= #queue do
			local fn = queue[index]
			index, count = index + 1, count + 1
			fn()
		end
		queue = {}
		return count
	end
	local ok, err = xpcall(function() callback(flush); flush() end, debug.traceback)
	vim.schedule = original
	if not ok then error(err) end
end

return M
