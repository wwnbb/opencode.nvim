-- Prompt outbox: per-session submission records, admission waiters and
-- serialized selection/admission queues.
local M = {}
local epoch = require("opencode.session.epoch")
local attention = require("opencode.session.attention")
local outbox, queues = {}, {}
-- Terminal records only guard against late admission of recent prompts.
-- Keep a bounded set per session, oldest retired first.
local TERMINAL_LIMIT = 64
local terminal_order = {}
local last_revert_events = {}
local admission_waiters = {}

-- Re-exports: cancellation tokens live in session/epoch, interaction counts in
-- session/attention.
M.token, M.is_current = epoch.token, epoch.is_current
M.zero_counts, M.normalize_counts, M.total = attention.zero_counts, attention.normalize_counts, attention.total
M.has_pending, M.is_pending_question = attention.has_pending, attention.is_pending_question

function M.begin(record)
	local sid, id = record.session_id, record.message_id
	outbox[sid] = outbox[sid] or {}
	outbox[sid][id] = vim.deepcopy(record)
	return M.get(sid, id)
end

function M.expect_revert_commit(session_id)
	last_revert_events[session_id] = nil
end

function M.note_revert_event(session_id, boundary)
	last_revert_events[session_id] = boundary
end

function M.revert_event_seen(session_id, boundary)
	return last_revert_events[session_id] == boundary
end

function M.get(session_id, message_id)
	return outbox[session_id] and vim.deepcopy(outbox[session_id][message_id]) or nil
end

function M.list(session_id)
	return vim.deepcopy(outbox[session_id] or {})
end

local function is_terminal(status) return status == "delivered" or status == "cancelled" end

local function retire(session_id, message_id)
	local order = terminal_order[session_id] or {}
	terminal_order[session_id] = order
	order[#order + 1] = message_id
	if #order <= TERMINAL_LIMIT * 2 then return end
	local records, kept, seen = outbox[session_id] or {}, {}, {}
	for i = #order, 1, -1 do
		local id = order[i]
		local record = records[id]
		if not seen[id] and record and is_terminal(record.status) then
			seen[id] = true
			if #kept < TERMINAL_LIMIT then kept[#kept + 1] = id else records[id] = nil end
		end
	end
	order = {}
	for i = #kept, 1, -1 do order[#order + 1] = kept[i] end
	terminal_order[session_id] = order
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
	if is_terminal(record.status) and not is_terminal(status) then retire(session_id, message_id) end
	if record.status ~= "submitting" and admission_waiters[session_id] then
		local waiters = admission_waiters[session_id][message_id]
		admission_waiters[session_id][message_id] = nil
		for _, callback in ipairs(waiters or {}) do callback(vim.deepcopy(record)) end
	end
	return vim.deepcopy(record)
end

function M.when_admitted(session_id, message_id, callback)
	local record = M.get(session_id, message_id)
	if not record or record.status ~= "submitting" then callback(record); return end
	admission_waiters[session_id] = admission_waiters[session_id] or {}
	local waiters = admission_waiters[session_id][message_id] or {}
	waiters[#waiters + 1] = callback
	admission_waiters[session_id][message_id] = waiters
end

function M.admit(item)
	local record = M.get(item.sessionID, item.id)
	if not record then
		M.begin({ session_id = item.sessionID, message_id = item.id, status = "accepted" })
	end
	return M.update(item.sessionID, item.id, { status = item.delivery == "queue" and "queued" or "accepted", inbox = item, delivery_missing = false })
end

-- Native history contains only delivered messages, unlike local/inbox echoes.
-- Record previously unknown recent IDs so late admission cannot resurrect them;
-- older turns are far behind any inbox read still in flight.
function M.reconcile_history(session_id, messages)
	local ids = {}
	for _, message in ipairs(messages or {}) do
		local info = message.info or message
		if info.role == "user" and not info.provisional then ids[#ids + 1] = info.id end
	end
	-- Native message IDs ascend; a page need not be ordered.
	table.sort(ids)
	local records = outbox[session_id] or {}
	for i, id in ipairs(ids) do
		local record = records[id]
		if (record and record.status ~= "delivered") or (not record and i > #ids - TERMINAL_LIMIT) then
			M.update(session_id, id, { status = "delivered", delivery_missing = false })
		end
	end
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
	epoch.bump(session_id)
	outbox[session_id], queues[session_id], terminal_order[session_id] = nil, nil, nil
	last_revert_events[session_id] = nil
	admission_waiters[session_id] = nil
end

function M.invalidate()
	epoch.invalidate()
	queues = {}
	for _, records in pairs(outbox) do
		for _, record in pairs(records) do
			if record.status == "submitting" then M.update(record.session_id, record.message_id, { status = "uncertain" }) end
		end
	end
end

function M.clear_all()
	M.invalidate()
	outbox, terminal_order = {}, {}
	epoch.clear_epochs()
	last_revert_events = {}
	admission_waiters = {}
end

return M
