-- Cancellation tokens for async callbacks. A token is current until the global
-- generation advances (invalidate) or its session's epoch is bumped.
local M = {}
local epochs = {}
local generation = 0

function M.token(session_id)
	return { generation = generation, session_id = session_id, epoch = epochs[session_id or ""] or 0 }
end

function M.is_current(token)
	return token.generation == generation and token.epoch == (epochs[token.session_id or ""] or 0)
end

-- Invalidate every token issued for this session.
function M.bump(session_id)
	epochs[session_id] = (epochs[session_id] or 0) + 1
end

-- Invalidate every token.
function M.invalidate()
	generation = generation + 1
end

-- Forget per-session epochs; callers invalidate first so no older token revives.
function M.clear_epochs()
	epochs = {}
end

return M
