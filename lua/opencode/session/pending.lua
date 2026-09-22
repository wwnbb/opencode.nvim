local M = {}
local outbox, queues, epochs = {}, {}, {}
local generation = 0

function M.token(session_id)
	return { generation = generation, session_id = session_id, epoch = epochs[session_id or ""] or 0 }
end

function M.is_current(token)
	return token.generation == generation and token.epoch == (epochs[token.session_id or ""] or 0)
end

function M.begin(record)
	local sid, id = record.session_id, record.message_id
	outbox[sid] = outbox[sid] or {}
	outbox[sid][id] = vim.deepcopy(record)
	return M.get(sid, id)
end

function M.get(session_id, message_id)
	return outbox[session_id] and vim.deepcopy(outbox[session_id][message_id]) or nil
end

function M.list(session_id)
	return vim.deepcopy(outbox[session_id] or {})
end

function M.update(session_id, message_id, patch)
	local record = outbox[session_id] and outbox[session_id][message_id]
	if not record then
		-- A terminal SSE event can beat the first inbox snapshot in a fresh client.
		-- Remember it so that late HTTP admission cannot resurrect that item.
		if patch.status ~= "delivered" and patch.status ~= "cancelled" then return end
		M.begin({ session_id = session_id, message_id = message_id })
		record = outbox[session_id][message_id]
	end
	local status = record.status
	for key, value in pairs(patch) do record[key] = vim.deepcopy(value) end
	-- HTTP admission may arrive after delivery, or a transport error after SSE
	-- already confirmed acceptance. Neither callback may regress that evidence.
	if status == "delivered" or status == "cancelled" then record.status = status
	elseif (status == "accepted" or status == "queued") and patch.status == "uncertain" then record.status = status end
	return vim.deepcopy(record)
end

function M.admit(item)
	local record = M.get(item.sessionID, item.id)
	if not record then
		M.begin({ session_id = item.sessionID, message_id = item.id, status = "accepted" })
	end
	return M.update(item.sessionID, item.id, { status = item.delivery == "queue" and "queued" or "accepted", inbox = item, delivery_missing = false })
end

-- Serialize selection changes and admission per session, not across sessions.
function M.serialize(session_id, task)
	local queue = queues[session_id]
	if not queue then queue = {}; queues[session_id] = queue end
	queue[#queue + 1] = task
	if #queue > 1 then return end
	local function run()
		local current = queue[1]
		if not current then queues[session_id] = nil; return end
		local completed = false
		current(function()
			if completed or queues[session_id] ~= queue then return end
			completed = true
			table.remove(queue, 1)
			run()
		end)
	end
	run()
end

function M.clear_session(session_id)
	epochs[session_id] = (epochs[session_id] or 0) + 1
	outbox[session_id], queues[session_id] = nil, nil
end

function M.invalidate()
	generation = generation + 1
	queues = {}
	for _, records in pairs(outbox) do
		for _, record in pairs(records) do
			if record.status == "submitting" then record.status = "uncertain" end
		end
	end
end

function M.clear_all()
	M.invalidate()
	outbox, epochs = {}, {}
end

---@return table
function M.zero_counts()
	return {
		permissions = 0,
		questions = 0,
		edits = 0,
	}
end

---@param counts table|nil
---@return table
function M.normalize_counts(counts)
	counts = type(counts) == "table" and counts or {}
	return {
		permissions = tonumber(counts.permissions or counts.permission or 0) or 0,
		questions = tonumber(counts.questions or counts.question or 0) or 0,
		edits = tonumber(counts.edits or counts.edit or 0) or 0,
	}
end

---@param counts table|nil
---@return number
function M.total(counts)
	local normalized = M.normalize_counts(counts)
	return normalized.permissions + normalized.questions + normalized.edits
end

---@param counts table|nil
---@return boolean
function M.has_pending(counts)
	return M.total(counts) > 0
end

---@param items table[]|nil
---@param root_session_id string
---@param owns_session fun(root_session_id: string, session_id: string|nil): boolean
---@return table[]
function M.collect_owned(items, root_session_id, owns_session)
	local owned = {}
	if not root_session_id or root_session_id == "" or type(owns_session) ~= "function" then
		return owned
	end

	for _, item in ipairs(items or {}) do
		if type(item) == "table" and owns_session(root_session_id, item.session_id or item.sessionID) then
			table.insert(owned, item)
		end
	end
	return owned
end

---@param item table|nil
---@return boolean
function M.is_pending_question(item)
	local status = type(item) == "table" and item.status or nil
	return status == "pending" or status == "confirming"
end

---@param item table|nil
---@return boolean
function M.is_pending_permission(item)
	return type(item) == "table" and item.status == "pending"
end

---@param item table|nil
---@return boolean
function M.is_pending_edit(item)
	return type(item) == "table" and item.status == "pending"
end

return M
