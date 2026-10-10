local M = {}

function M.wait(predicate, why, timeout)
	assert(vim.wait(timeout or 15000, predicate, 20), why)
end

function M.await(register)
	local done, value, failure
	register(function(err, data) failure, value, done = err, data, true end)
	M.wait(function() return done end, "HTTP timeout")
	assert(not failure, vim.inspect(failure))
	return value
end

-- Cross the native schedule queue before a screenshot; do not sleep a fixed time.
function M.flush_scheduled()
	local done = false
	vim.schedule(function() done = true end)
	M.wait(function() return done end, "Scheduled surface update did not finish")
end

return M
