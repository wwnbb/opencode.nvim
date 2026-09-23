-- V2 reducer owned by sync.lua. All persistent state remains in sync's store.
local M = {}
local projection = require("opencode.protocol.v2.messages")

local function event_message_id(event)
	return (event.id:gsub("^evt", "msg"))
end

local function find_content(message, kind, ordinal, call_id)
	local index = 0
	for _, content in ipairs(message.content) do
		if content.type == kind then
			if (kind == "tool" and content.id == call_id) or (kind ~= "tool" and index == ordinal) then return content end
			index = index + 1
		end
	end
end

function M.apply(sync, event)
	local data, kind = event.data, event.type
	local sid = data.sessionID
	if not sid then return {} end
	local result = { session_id = sid }
	local function commit(message, provisional)
		local projected = projection.project(sid, message)
		projected.info.provisional = provisional
		local _, _, changed = sync.handle_session_messages(sid, { projected })
		result.changed = result.changed or changed > 0
	end
	local function assistant()
		local existing = sync.get_message(sid, data.assistantMessageID)
		if existing and existing._v2 then return vim.deepcopy(existing._v2) end
		result.reconcile = true
		return { id = data.assistantMessageID, type = "assistant", content = {}, time = { created = event.created } }
	end
	if kind == "session.revert.committed" then
		local removed = {}
		for _, message in ipairs(sync.get_messages(sid)) do
			if message.id >= data.to then removed[#removed + 1] = message.id end
		end
		for _, id in ipairs(removed) do sync.handle_message_removed(sid, id) end
		result.changed, result.reconcile, result.revert_to = #removed > 0, true, data.to
	elseif kind == "session.inbox.enqueued" then
		local item = data.item
		result.inbox = { id = data.inboxID, sessionID = sid, type = item.type, payload = item.payload,
			delivery = item.delivery, time = { created = event.created } }
		if item.type == "user" then
			local existing = sync.get_message(sid, data.inboxID)
			if existing and existing.protocol == "v2" and not existing.provisional then
				result.inbox, result.delivered = nil, data.inboxID
			else
				local message = vim.deepcopy(item.payload)
				message.id, message.type, message.time = data.inboxID, "user", { created = event.created }
				commit(message, true)
			end
		end
	elseif kind == "session.inbox.delivered" then
		result.delivered = data.inboxID
		local existing = sync.get_message(sid, data.inboxID)
		if existing and existing._v2 then
			local message = vim.deepcopy(existing._v2)
			message.time.created = event.created
			commit(message)
		else result.reconcile = true end
	elseif kind == "session.inbox.cancelled" then
		result.cancelled = data.inboxID
		result.changed = sync.handle_message_removed(sid, data.inboxID)
	elseif kind == "session.execution.started" then
		result.status = { type = "busy" }
	elseif kind == "session.execution.succeeded" or kind == "session.execution.failed" or kind == "session.execution.interrupted" then
		local outcome = kind:match("([^.]+)$")
		result.status = { type = "idle", outcome = outcome }
		if outcome == "failed" then result.error = data.error end
		if data.reason ~= "shutdown" then
			commit({ id = event_message_id(event), type = "idle", time = { created = event.created }, outcome = outcome })
		end
		result.reconcile = true
	elseif kind == "session.status" then
		result.status = vim.deepcopy(data.status)
	elseif kind == "session.idle" then
		result.status = { type = "idle" }; result.reconcile = true
	elseif kind == "session.step.started" then
		local message = assistant()
		message.agent, message.model = data.agent, vim.deepcopy(data.model)
		message.retry, message.error, message.finish, message.rawFinish, message.providerState = nil, nil, nil, nil, nil
		message.time = { created = data.started }
		if data.snapshot then message.snapshot = vim.tbl_extend("force", message.snapshot or {}, { start = data.snapshot }) end
		result.reconcile = nil -- The start provides a complete initial identity.
		commit(message)
	elseif kind:match("^session%.step%.") or kind == "session.retry.scheduled" then
		local message = assistant()
		if kind == "session.step.streamed" then message.time.streamed = event.created
		elseif kind == "session.retry.scheduled" then
			message.retry = { attempt = data.attempt, at = data.at, error = data.error }
			result.status = { type = "retry", attempt = data.attempt, next = data.at, message = projection.error_text(data.error) }
		elseif kind == "session.step.ended" or kind == "session.step.failed" then
			message.time.completed = event.created
			message.finish, message.rawFinish, message.providerState = data.finish, data.rawFinish, data.providerState
			message.cost, message.tokens = data.cost, vim.deepcopy(data.tokens)
			if data.snapshot then message.snapshot = vim.tbl_extend("force", message.snapshot or {}, { ["end"] = data.snapshot }) end
			if kind == "session.step.failed" then message.error = data.error; message.retry = nil; message.finish = data.finish or "error" end
		end
		commit(message)
	elseif kind:match("^session%.text%.") or kind:match("^session%.reasoning%.") then
		local message = assistant()
		local content_kind, action = kind:match("^session%.([^.]+)%.([^.]+)$")
		local content = find_content(message, content_kind, data.ordinal or 0)
		if not content then
			if action ~= "started" then result.reconcile = true end
			content = { type = content_kind, text = "" }
			if content_kind == "reasoning" then content.time = { created = event.created }; content.state = data.state end
			message.content[#message.content + 1] = content
		end
		if action == "delta" then content.text = content.text .. data.delta
		elseif action == "ended" then
			content.text = data.text -- Full value replaces all deltas.
			if content_kind == "reasoning" then
				content.time = { created = (content.time or {}).created or event.created, completed = event.created }
				if data.state ~= nil then content.state = vim.deepcopy(data.state) end
			end
		end
		commit(message)
	elseif kind:match("^session%.tool%.") then
		local message = assistant()
		local tool = find_content(message, "tool", nil, data.id)
		if not tool then
			if kind ~= "session.tool.input.started" then result.reconcile = true end
			tool = { type = "tool", id = data.id, name = data.name or "tool", time = { created = event.created }, state = { status = "streaming", input = "" } }
			message.content[#message.content + 1] = tool
		end
		local state = tool.state
		if kind == "session.tool.input.delta" and state.status == "streaming" then state.input = state.input .. data.delta
		elseif kind == "session.tool.input.ended" and state.status == "streaming" then state.input = data.text
		elseif kind == "session.tool.called" then
			tool.time.ran, tool.executed, tool.providerState = event.created, data.executed, data.state
			tool.state = { status = "running", input = data.input, metadata = {} }
		elseif kind == "session.tool.progress" then
			if state.status == "running" then state.metadata = vim.deepcopy(data.metadata) end
		elseif kind == "session.tool.success" or kind == "session.tool.failed" then
			tool.state = { status = kind == "session.tool.success" and "completed" or "error",
				input = type(state.input) == "table" and state.input or {}, metadata = data.metadata,
				content = vim.deepcopy(data.content), error = data.error }
			tool.executed = data.executed or tool.executed == true
			tool.providerResultState = data.resultState
			tool.time.completed = event.created
		end
		commit(message)
	elseif kind == "session.message.content.updated" then
		local message = assistant(); message.content = vim.deepcopy(data.content); commit(message)
	elseif kind == "session.synthetic" or kind == "session.instructions.updated" then
		if data.text then commit({ id = event_message_id(event), type = kind == "session.synthetic" and "synthetic" or "system",
			text = data.text, description = data.description, metadata = data.metadata or event.metadata, time = { created = event.created } }) end
	end
	if result.status then result.changed = sync.handle_session_status(sid, result.status) or result.changed end
	return result
end

return M
